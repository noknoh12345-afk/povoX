//! ルールの計画を実行する。
//!
//! ルール(JavaScript の `decide(ctx)`)は「何をするか」を返すだけで、povo へは一切送れない。
//! 返された計画はここで1つずつ安全装置にかけ、設定に従って
//! 実行 / 通知で確認待ち / 試運転の記録 / シミュレーション結果 / 見送り のどれかにする。
//!
//! 計画の形(JSON、`type` で区別):
//!   {"type":"skip","reason":"…"}                  何もしない
//!   {"type":"notify","title":"…","body":"…"}      通知を出す
//!   {"type":"applyCode","tag":"1gb"} / {"id":"…"} 手持ちのコードを1件使う
//!   {"type":"buy","sku":"…"}                      トッピングを買う
//!   (buy / applyCode には "confirm" を付けられる:
//!     true  = 設定が「自動」でも必ず通知で確認する(オートメーションの「実行前に確認」)
//!     false = 利用者がその場で押した実行(きっかけが "flow:" で始まる実行)だけ、「通知で確認」を飛ばす。
//!             設定が「しない」なら買わない・上限などの安全装置はそのまま。ルールの実行では無視する)
//!   {"type":"firstOf","items":[…]}                上から順に、最初にできたものだけ
//!   {"type":"all","items":[…]}                    全部(ただし購入・コードは1回の実行で1つまで)

use serde::Deserialize;

use crate::backend::Failure;
use crate::engine::{local, new_id, unlimited_reason, yen, Engine};
use crate::model::*;

const MAX_NODES: usize = 64;
const MAX_DEPTH: usize = 8;

#[derive(Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "type")]
pub enum PlanNode {
    #[serde(rename = "skip")]
    Skip {
        #[serde(default)]
        reason: String,
    },
    #[serde(rename = "notify")]
    Notify {
        #[serde(default)]
        title: String,
        #[serde(default)]
        body: String,
    },
    #[serde(rename = "applyCode")]
    ApplyCode {
        #[serde(default)]
        tag: Option<String>,
        #[serde(default)]
        id: Option<String>,
        #[serde(default)]
        confirm: Option<bool>,
    },
    #[serde(rename = "buy")]
    Buy {
        #[serde(default)]
        sku: Option<String>,
        #[serde(default)]
        confirm: Option<bool>,
    },
    #[serde(rename = "firstOf")]
    FirstOf {
        #[serde(default)]
        items: Vec<PlanNode>,
    },
    #[serde(rename = "all")]
    All {
        #[serde(default)]
        items: Vec<PlanNode>,
    },
}

pub fn parse_plan(json: &str) -> Result<PlanNode, String> {
    let node: PlanNode = serde_json::from_str(json).map_err(|e| format!("ルールの返した内容を読めません: {e}"))?;
    let (n, d) = measure(&node, 1);
    if n > MAX_NODES || d > MAX_DEPTH {
        return Err(format!("ルールの返した内容が大きすぎます({n}個・深さ{d})。"));
    }
    Ok(node)
}

fn measure(node: &PlanNode, depth: usize) -> (usize, usize) {
    match node {
        PlanNode::FirstOf { items } | PlanNode::All { items } => items.iter().fold((1, depth), |(n, d), it| {
            let (n2, d2) = measure(it, depth + 1);
            (n + n2, d.max(d2))
        }),
        _ => (1, depth),
    }
}

fn clip(s: &str, max: usize) -> String {
    let t: String = s.chars().take(max).collect();
    if s.chars().count() > max {
        format!("{t}…")
    } else {
        t
    }
}

/// 実行の流れの制御。
#[derive(Debug, Clone, Copy, PartialEq)]
enum Flow {
    /// 何もしなかった(firstOf は次を試す)。
    Passed,
    /// 何かした(firstOf はここで終わる)。
    Acted,
    /// 送ったが結果が分からない・通信が止まった。計画全体をここで止める。
    Halt,
}

struct Exec {
    mode: RunMode,
    /// 利用者がその場で押した実行(オートメーションのボタン・通知の「実行する」・予約)。
    user_initiated: bool,
    run_id: String,
    sim: Option<SimInput>,
    /// 購入・コードをこの実行で使ったか(1回の実行で1つまで)。
    spent: bool,
    outcomes: Vec<ActionOutcome>,
}

impl Exec {
    fn push(&mut self, kind: ActionKind, status: OutcomeStatus, label: impl Into<String>, message: impl Into<String>) -> &mut ActionOutcome {
        self.outcomes.push(ActionOutcome {
            kind,
            status,
            label: label.into(),
            message: message.into(),
            title: None,
            body: None,
            pending_id: None,
            challenge_url: None,
            price_yen: None,
        });
        self.outcomes.last_mut().unwrap()
    }
}

impl Engine {
    /// ルール1回分を実行し、記録を返す(シミュレーション以外は保存もする)。
    pub fn execute_run(&mut self, input: RunInput) -> RunRecord {
        self.prune_pending();
        let started = self.now();
        let id = new_id();
        let (left_kb, unlimited) = match (&input.sim, input.mode) {
            (Some(s), RunMode::Simulate) => (Some(s.left_kb), Some(s.unlimited)),
            _ => self.st.snapshot.as_ref().map(|s| (s.left_kb, s.unlimited.active)).unwrap_or((None, None)),
        };
        let mut rec = RunRecord {
            id: id.clone(),
            trigger: clip(&input.trigger, 40),
            mode: input.mode,
            started_ms: started,
            finished_ms: started,
            left_kb,
            unlimited,
            battery_level: input.battery_level,
            charging: input.charging,
            network: input.network.clone(),
            summary: String::new(),
            outcomes: vec![],
            error: None,
            logs: input.script_logs.iter().take(50).map(|l| clip(l, 300)).collect(),
        };
        let plan = match (&input.error, &input.plan_json) {
            (Some(e), _) => Err(clip(e, 500)),
            (None, Some(json)) => parse_plan(json),
            (None, None) => Err("ルールが何も返しませんでした。".into()),
        };
        match plan {
            Err(e) => {
                rec.summary = format!("実行できませんでした: {e}");
                rec.error = Some(e);
            }
            Ok(plan) => {
                let user_initiated = input.trigger.starts_with("flow:");
                let mut ex = Exec { mode: input.mode, user_initiated, run_id: id, sim: input.sim.clone(), spent: false, outcomes: vec![] };
                self.exec_node(&mut ex, &plan);
                rec.outcomes = ex.outcomes;
                rec.summary = summarize(&rec.outcomes);
            }
        }
        rec.finished_ms = self.now();
        if input.mode != RunMode::Simulate {
            let level = if rec.error.is_some() {
                LogLevel::Error
            } else if rec.outcomes.iter().any(|o| matches!(o.status, OutcomeStatus::Done | OutcomeStatus::Queued | OutcomeStatus::Failed)) {
                LogLevel::Action
            } else {
                LogLevel::Info
            };
            let mode = match input.mode {
                RunMode::Dry => "(試運転)",
                _ => "",
            };
            self.log(level, format!("自動チェック{mode}[{}]: {}", rec.trigger, rec.summary));
            self.st.runs.push(rec.clone());
        }
        self.save();
        rec
    }

    fn exec_node(&mut self, ex: &mut Exec, node: &PlanNode) -> Flow {
        match node {
            PlanNode::Skip { reason } => {
                let r = if reason.trim().is_empty() { "何もしない".to_string() } else { clip(reason, 200) };
                ex.push(ActionKind::Skip, OutcomeStatus::Skipped, r.clone(), r);
                Flow::Passed
            }
            PlanNode::Notify { title, body } => {
                let title = if title.trim().is_empty() { "povoX".to_string() } else { clip(title, 100) };
                let body = clip(body, 300);
                let o = ex.push(ActionKind::Notify, OutcomeStatus::Notified, format!("通知: {title}"), body.clone());
                o.title = Some(title);
                o.body = Some(body);
                Flow::Acted
            }
            PlanNode::Buy { sku, confirm } => self.exec_buy(ex, sku.as_deref(), *confirm),
            PlanNode::ApplyCode { tag, id, confirm } => self.exec_code(ex, tag.as_deref(), id.as_deref(), *confirm),
            PlanNode::FirstOf { items } => {
                for it in items {
                    match self.exec_node(ex, it) {
                        Flow::Passed => continue,
                        other => return other,
                    }
                }
                Flow::Passed
            }
            PlanNode::All { items } => {
                let mut acted = false;
                for it in items {
                    match self.exec_node(ex, it) {
                        Flow::Halt => return Flow::Halt,
                        Flow::Acted => acted = true,
                        Flow::Passed => {}
                    }
                }
                if acted {
                    Flow::Acted
                } else {
                    Flow::Passed
                }
            }
        }
    }

    /// 設定と、計画の "confirm" から、この1件の実行のしかたを決める。
    /// 「しない」は何があっても「しない」。確認を飛ばせるのは利用者がその場で押した実行だけ。
    fn effective_mode(base: ActionMode, confirm: Option<bool>, ex: &Exec) -> ActionMode {
        match (base, confirm) {
            (ActionMode::Off, _) => ActionMode::Off,
            (ActionMode::Auto, Some(true)) => ActionMode::Confirm,
            (ActionMode::Confirm, Some(false)) if ex.user_initiated => ActionMode::Auto,
            (m, _) => m,
        }
    }

    /// 送る前の共通チェック(ルールの経路)。
    fn rule_gate(&self, ex: &Exec) -> Result<(), String> {
        if ex.spent {
            return Err("1回の自動チェックで使う購入・コードは1つまでです。".into());
        }
        if ex.mode != RunMode::Simulate {
            self.gate().map_err(|f| f.message)?;
        }
        Ok(())
    }

    /// ルールによる購入の安全装置(送る前に確かめること全部)。
    pub(crate) fn buy_policy(&self, p: &Product) -> Result<u32, String> {
        if p.requires_3ds {
            return Err(format!("{} は3Dセキュアが必要なので、ルールでは買いません(ショップから手動で買えます)。", p.name));
        }
        let price = p.price_yen.ok_or_else(|| format!("{} の価格を読めないので、ルールでは買いません。", p.name))?;
        let b = self.budget();
        if b.rule_spent_yen + price > b.cap_yen {
            return Err(format!("今月の上限 {}円を超えるので買いません(使用済み {}円 + {}円)。", b.cap_yen, b.rule_spent_yen, price));
        }
        if b.rule_orders_today >= b.max_per_day {
            return Err(format!("今日はすでに{}回買っているので買いません(上限 {}回)。", b.rule_orders_today, b.max_per_day));
        }
        let gap = self.st.settings.order_gap_min as i64 * 60_000;
        let now = self.now();
        if let Some(last) = self.st.ledger.iter().filter(|e| e.source == OrderSource::Rule).map(|e| e.time_ms).max() {
            if now - last < gap {
                return Err(format!("前回の購入から{}分経っていないので買いません。", self.st.settings.order_gap_min));
            }
        }
        if self.recently_ordered(&p.sku) {
            return Err("同じ商品を2分以内に注文しているので、重ねて買いません。".into());
        }
        Ok(price)
    }

    fn exec_buy(&mut self, ex: &mut Exec, sku: Option<&str>, confirm: Option<bool>) -> Flow {
        let Some(sku) = sku.map(str::trim).filter(|s| !s.is_empty()) else {
            ex.push(ActionKind::Buy, OutcomeStatus::Refused, "購入", "買う商品が見つかりませんでした。");
            return Flow::Passed;
        };
        let mode = Self::effective_mode(self.st.settings.purchase_mode, confirm, ex);
        if mode == ActionMode::Off {
            ex.push(ActionKind::Buy, OutcomeStatus::Refused, format!("購入 {sku}"), "設定で、ルールによる購入はオフです。");
            return Flow::Passed;
        }
        if let Err(r) = self.rule_gate(ex) {
            ex.push(ActionKind::Buy, OutcomeStatus::Refused, format!("購入 {sku}"), r);
            return Flow::Passed;
        }
        // 商品を探す(シミュレーションは手元の一覧だけ。本番は古ければ取り直す)
        let product = if ex.mode == RunMode::Simulate {
            Ok(self.find_product(sku))
        } else {
            self.fresh_product(sku)
        };
        let product = match product {
            Ok(Some(p)) => p,
            Ok(None) => {
                let msg = if ex.mode == RunMode::Simulate && self.st.catalog.is_none() {
                    "トッピング一覧がまだ読み込まれていません(トッピング画面で一度読み込んでください)。".to_string()
                } else {
                    format!("{sku} は今の購入できる一覧にありません。")
                };
                ex.push(ActionKind::Buy, OutcomeStatus::Refused, format!("購入 {sku}"), msg);
                return Flow::Passed;
            }
            Err(f) => {
                ex.push(ActionKind::Buy, OutcomeStatus::Refused, format!("購入 {sku}"), format!("一覧を読めませんでした: {}", f.message));
                return if f.halt { Flow::Halt } else { Flow::Passed };
            }
        };
        let label = format!("{}{}", product.name, yen(product.price_yen));
        let price = match self.buy_policy(&product) {
            Ok(p) => p,
            Err(r) => {
                ex.push(ActionKind::Buy, OutcomeStatus::Refused, label, r);
                return Flow::Passed;
            }
        };
        if ex.mode != RunMode::Simulate && self.st.pending.iter().any(|p| p.kind == ActionKind::Buy) {
            ex.push(ActionKind::Buy, OutcomeStatus::Refused, label, "確認待ちの購入があるので、新しくは出しません。");
            return Flow::Passed;
        }
        ex.spent = true;
        let dry = ex.mode == RunMode::Dry || self.st.settings.dry_run;
        if ex.mode == RunMode::Simulate {
            let msg = if self.st.settings.dry_run {
                "試運転中なので、記録だけになります。"
            } else if mode == ActionMode::Confirm {
                "通知で確認してから購入します。"
            } else {
                "購入します。"
            };
            ex.push(ActionKind::Buy, OutcomeStatus::Simulated, label, msg).price_yen = Some(price);
            return Flow::Acted;
        }
        if dry {
            ex.push(ActionKind::Buy, OutcomeStatus::DryRun, label, "試運転: 購入するところでした。").price_yen = Some(price);
            return Flow::Acted;
        }
        if mode == ActionMode::Confirm {
            let pid = self.queue_pending(ActionKind::Buy, &label, format!("{} を {}円で購入します。", product.name, price), Some(sku.to_string()), None, Some(price), &ex.run_id);
            let o = ex.push(ActionKind::Buy, OutcomeStatus::Queued, label, "通知で確認待ちです。");
            o.pending_id = Some(pid);
            o.price_yen = Some(price);
            return Flow::Acted;
        }
        match self.send_order(sku, Some(&product), OrderSource::Rule) {
            Ok(r) => {
                let msg = if r.needs_3ds { "3Dセキュアの認証待ちです(アプリで認証してください)。" } else { "注文しました。" };
                let o = ex.push(ActionKind::Buy, OutcomeStatus::Done, label, msg);
                o.price_yen = Some(price);
                o.challenge_url = r.challenge_url;
                Flow::Acted
            }
            Err(f) => {
                ex.push(ActionKind::Buy, OutcomeStatus::Failed, label, format!("{}(課金された可能性があるので購入履歴を確認してください)", f.message)).price_yen = Some(price);
                Flow::Halt
            }
        }
    }

    fn pick_code(&self, tag: Option<&str>, id: Option<&str>) -> Result<usize, String> {
        if let Some(id) = id {
            return match self.st.codes.iter().position(|c| c.id == id) {
                Some(i) if self.st.codes[i].status == CodeStatus::Pending => Ok(i),
                Some(_) => Err("そのコードはもう使っています。".into()),
                None => Err("そのコードは見つかりません。".into()),
            };
        }
        let tag = tag.map(str::trim).filter(|t| !t.is_empty());
        self.st
            .codes
            .iter()
            .position(|c| c.status == CodeStatus::Pending && tag.map(|t| c.tag.eq_ignore_ascii_case(t)).unwrap_or(true))
            .ok_or_else(|| match tag {
                Some(t) => format!("タグ「{t}」の未使用コードがありません。"),
                None => "未使用のコードがありません。".into(),
            })
    }

    fn exec_code(&mut self, ex: &mut Exec, tag: Option<&str>, id: Option<&str>, confirm: Option<bool>) -> Flow {
        let mode = Self::effective_mode(self.st.settings.code_mode, confirm, ex);
        if mode == ActionMode::Off {
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, "コード", "設定で、ルールによるコード適用はオフです。");
            return Flow::Passed;
        }
        if let Err(r) = self.rule_gate(ex) {
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, "コード", r);
            return Flow::Passed;
        }
        let idx = match self.pick_code(tag, id) {
            Ok(i) => i,
            Err(r) => {
                ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, "コード", r);
                return Flow::Passed;
            }
        };
        let c = &self.st.codes[idx];
        let label = if c.tag.is_empty() { format!("コード {}", crate::engine::mask(&c.code)) } else { format!("コード {}({})", crate::engine::mask(&c.code), c.tag) };
        let code_id = c.id.clone();
        let left = self.code_cooldown_left_ms();
        if left > 0 && ex.mode != RunMode::Simulate {
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, label, format!("コードの送信は15秒に1回までです(あと{}秒)。", left / 1000 + 1));
            return Flow::Passed;
        }
        // 使い放題の有効期間中は送らない。分からないときも送らない。
        let block = if ex.mode == RunMode::Simulate {
            let active = ex.sim.as_ref().map(|s| s.unlimited).or_else(|| self.st.snapshot.as_ref().and_then(|s| s.unlimited.active));
            unlimited_reason(active, true)
        } else {
            match self.unlimited_block(true) {
                Ok(b) => b,
                Err(f) => {
                    ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, label, format!("使い放題中か確かめられませんでした: {}", f.message));
                    return if f.halt { Flow::Halt } else { Flow::Passed };
                }
            }
        };
        if let Some(r) = block {
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, label, r);
            return Flow::Passed;
        }
        if ex.mode != RunMode::Simulate && self.st.pending.iter().any(|p| p.kind == ActionKind::ApplyCode) {
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, label, "確認待ちのコードがあるので、新しくは出しません。");
            return Flow::Passed;
        }
        ex.spent = true;
        if ex.mode == RunMode::Simulate {
            let msg = if self.st.settings.dry_run {
                "試運転中なので、記録だけになります。"
            } else if mode == ActionMode::Confirm {
                "通知で確認してから適用します。"
            } else {
                "適用します。"
            };
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Simulated, label, msg);
            return Flow::Acted;
        }
        if ex.mode == RunMode::Dry || self.st.settings.dry_run {
            ex.push(ActionKind::ApplyCode, OutcomeStatus::DryRun, label, "試運転: 適用するところでした。");
            return Flow::Acted;
        }
        if mode == ActionMode::Confirm {
            let pid = self.queue_pending(ActionKind::ApplyCode, &label, format!("{label} を povo に送ります。"), None, Some(code_id), None, &ex.run_id);
            ex.push(ActionKind::ApplyCode, OutcomeStatus::Queued, label, "通知で確認待ちです。").pending_id = Some(pid);
            return Flow::Acted;
        }
        match self.send_code(idx, "ルールでコード適用") {
            Ok(r) if r.valid => {
                ex.push(ActionKind::ApplyCode, OutcomeStatus::Done, label, r.title.unwrap_or_else(|| "適用しました。".into()));
                Flow::Acted
            }
            Ok(r) => {
                // 受け付けられなかった(使用済みなど)。データは増えていないので次の手を試してよい。
                ex.spent = false;
                ex.push(ActionKind::ApplyCode, OutcomeStatus::Refused, label, format!("povo が受け付けませんでした: {}", r.title.unwrap_or_default()));
                Flow::Passed
            }
            Err(f) => {
                ex.push(ActionKind::ApplyCode, OutcomeStatus::Failed, label, format!("{}(適用されたか、ご利用中のトッピングで確認してください)", f.message));
                Flow::Halt
            }
        }
    }

    // ---- 確認待ち ------------------------------------------------------------------------

    #[allow(clippy::too_many_arguments)]
    fn queue_pending(&mut self, kind: ActionKind, label: &str, detail: String, sku: Option<String>, code_id: Option<String>, price: Option<u32>, run_id: &str) -> String {
        let now = self.now();
        let id = new_id();
        self.st.pending.push(PendingAction {
            id: id.clone(),
            kind,
            label: label.to_string(),
            detail,
            sku,
            code_id,
            price_yen: price,
            created_ms: now,
            expires_ms: now + self.st.settings.confirm_ttl_min as i64 * 60_000,
            run_id: run_id.to_string(),
        });
        id
    }

    pub fn pending_actions(&mut self) -> Vec<PendingAction> {
        self.prune_pending();
        self.st.pending.clone()
    }

    /// 期限の切れた確認待ちを片付ける。
    pub(crate) fn prune_pending(&mut self) {
        let now = self.now();
        let expired: Vec<PendingAction> = self.st.pending.iter().filter(|p| p.expires_ms <= now).cloned().collect();
        if expired.is_empty() {
            return;
        }
        self.st.pending.retain(|p| p.expires_ms > now);
        for p in expired {
            self.update_run_outcome(&p, OutcomeStatus::Skipped, "確認されないまま期限が切れました。");
            self.log(LogLevel::Info, format!("確認待ちの期限切れ: {}", p.label));
        }
    }

    fn update_run_outcome(&mut self, p: &PendingAction, status: OutcomeStatus, message: &str) {
        if let Some(run) = self.st.runs.iter_mut().rev().find(|r| r.id == p.run_id) {
            if let Some(o) = run.outcomes.iter_mut().find(|o| o.pending_id.as_deref() == Some(p.id.as_str())) {
                o.status = status;
                o.message = message.to_string();
            }
            run.summary = summarize(&run.outcomes);
        }
    }

    /// 確認待ちを実行する(通知の「実行」ボタン・アプリの確認カードから)。
    /// 実行の直前に安全装置をもう一度かける(確認するまでの間に上限などが変わっているかもしれない)。
    pub fn confirm_pending(&mut self, id: &str) -> Result<ActionOutcome, Failure> {
        self.prune_pending();
        let i = self
            .st
            .pending
            .iter()
            .position(|p| p.id == id)
            .ok_or_else(|| local("この確認はもうありません(期限切れか、実行・取り消し済みです)。"))?;
        let p = self.st.pending.remove(i);
        self.save();
        let mut outcome = ActionOutcome {
            kind: p.kind,
            status: OutcomeStatus::Refused,
            label: p.label.clone(),
            message: String::new(),
            title: None,
            body: None,
            pending_id: Some(p.id.clone()),
            challenge_url: None,
            price_yen: p.price_yen,
        };
        let result: Result<(OutcomeStatus, String, Option<String>), String> = (|| {
            self.gate().map_err(|f| f.message)?;
            match p.kind {
                ActionKind::Buy => {
                    let sku = p.sku.clone().ok_or("商品が記録されていません。")?;
                    let product = self.fresh_product(&sku).map_err(|f| f.message)?.ok_or("その商品は今の購入できる一覧にありません。")?;
                    self.buy_policy(&product)?;
                    match self.send_order(&sku, Some(&product), OrderSource::Rule) {
                        Ok(r) => Ok((
                            OutcomeStatus::Done,
                            if r.needs_3ds { "3Dセキュアの認証待ちです。".into() } else { "注文しました。".into() },
                            r.challenge_url,
                        )),
                        Err(f) => Ok((OutcomeStatus::Failed, format!("{}(課金された可能性があるので購入履歴を確認してください)", f.message), None)),
                    }
                }
                ActionKind::ApplyCode => {
                    let cid = p.code_id.clone().ok_or("コードが記録されていません。")?;
                    let idx = self.pick_code(None, Some(&cid))?;
                    let left = self.code_cooldown_left_ms();
                    if left > 0 {
                        return Err(format!("コードの送信は15秒に1回までです(あと{}秒)。", left / 1000 + 1));
                    }
                    if let Some(r) = self.unlimited_block(true).map_err(|f| f.message)? {
                        return Err(r);
                    }
                    match self.send_code(idx, "確認してコード適用") {
                        Ok(r) if r.valid => Ok((OutcomeStatus::Done, r.title.unwrap_or_else(|| "適用しました。".into()), None)),
                        Ok(r) => Ok((OutcomeStatus::Refused, format!("povo が受け付けませんでした: {}", r.title.unwrap_or_default()), None)),
                        Err(f) => Ok((OutcomeStatus::Failed, format!("{}(適用されたか、ご利用中のトッピングで確認してください)", f.message), None)),
                    }
                }
                _ => Err("実行できない種類です。".into()),
            }
        })();
        match result {
            Ok((status, message, challenge)) => {
                outcome.status = status;
                outcome.message = message;
                outcome.challenge_url = challenge;
            }
            Err(reason) => {
                outcome.status = OutcomeStatus::Refused;
                outcome.message = reason;
            }
        }
        self.update_run_outcome(&p, outcome.status, &outcome.message.clone());
        self.log(
            if outcome.status == OutcomeStatus::Done { LogLevel::Action } else { LogLevel::Warn },
            format!("確認待ちを実行: {}: {}", p.label, outcome.message),
        );
        self.save();
        Ok(outcome)
    }

    pub fn dismiss_pending(&mut self, id: &str) {
        if let Some(i) = self.st.pending.iter().position(|p| p.id == id) {
            let p = self.st.pending.remove(i);
            self.update_run_outcome(&p, OutcomeStatus::Skipped, "取り消しました。");
            self.log(LogLevel::Info, format!("確認待ちを取り消し: {}", p.label));
            self.save();
        }
    }

    pub fn runs(&self, limit: u32) -> Vec<RunRecord> {
        self.st.runs.iter().rev().take(limit as usize).cloned().collect()
    }
}

/// 実行結果を一行にまとめる。
pub(crate) fn summarize(outcomes: &[ActionOutcome]) -> String {
    let spend = outcomes.iter().find(|o| {
        matches!(o.kind, ActionKind::Buy | ActionKind::ApplyCode)
            && matches!(o.status, OutcomeStatus::Done | OutcomeStatus::Queued | OutcomeStatus::DryRun | OutcomeStatus::Simulated | OutcomeStatus::Failed)
    });
    if let Some(o) = spend {
        let what = match (o.kind, o.status) {
            (ActionKind::Buy, OutcomeStatus::Done) => "購入しました",
            (ActionKind::Buy, OutcomeStatus::Queued) => "購入の確認待ち",
            (ActionKind::Buy, OutcomeStatus::DryRun) => "購入するところでした(試運転)",
            (ActionKind::Buy, OutcomeStatus::Simulated) => "購入します",
            (ActionKind::Buy, _) => "購入に失敗",
            (_, OutcomeStatus::Done) => "適用しました",
            (_, OutcomeStatus::Queued) => "適用の確認待ち",
            (_, OutcomeStatus::DryRun) => "適用するところでした(試運転)",
            (_, OutcomeStatus::Simulated) => "適用します",
            _ => "適用に失敗",
        };
        return format!("{}: {what}", o.label);
    }
    if let Some(o) = outcomes.iter().find(|o| o.status == OutcomeStatus::Notified) {
        return o.label.clone();
    }
    if let Some(o) = outcomes.iter().find(|o| o.status == OutcomeStatus::Refused) {
        return format!("見送り: {}", o.message);
    }
    if let Some(o) = outcomes.iter().find(|o| o.status == OutcomeStatus::Skipped) {
        return o.message.clone();
    }
    "何もしませんでした".into()
}
