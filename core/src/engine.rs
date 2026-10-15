//! povoX のエンジン。povo への通信・安全装置・保存はすべてここで一元管理する。
//!
//! povo-web から引き継いだ約束ごと:
//! - povo への通信は常に1本ずつ(呼び出し側の Mutex で直列化)。自動リトライはしない。
//! - 403 や PIN 要求が返ったら、利用者がアプリで「再開」を押すまで povo への通信を止める
//!   (この停止は保存され、バックグラウンド実行・ショートカット・通知からも越えられない)。
//! - povo が待機時刻を返したら、その時刻まで送らない。
//! - トークン更新は期限切れ後だけ。端末IDとトークンは必ず組で保存する。
//! - OTP の再送は60秒に1回まで、入れ直しは3回まで。同じ商品の注文は120秒以内に繰り返せない。
//! - 購入・コード送信は、送る「前」に記録する(応答が失敗でも povo 側で処理された可能性があるため)。
//!
//! 自動化(ルールの実行)は plan.rs、ルールに渡す材料は rulectx.rs。

use std::path::PathBuf;

use povo_core::{ActionType, AuthChallenge};
use serde_json::Value;

use crate::backend::{Backend, Failure, R};
use crate::model::*;
use crate::state::PersistState;
use crate::store::SessionStore;
use crate::{catalog, history, jptime, parse, protocol};

pub const ORDER_CONFIRM: &str = "購入する";
pub const CODE_CONFIRM: &str = "利用する";
const OTP_COOLDOWN_MS: i64 = 60_000;
const MAX_OTP_ATTEMPTS: u32 = 3;
pub(crate) const SAME_ORDER_COOLDOWN_MS: i64 = 120_000;
pub(crate) const CODE_COOLDOWN_MS: i64 = 15_000;
const CODE_MAX_LEN: usize = 18;
/// 通常の残量取得は30秒以内なら前回の結果を返す。強制更新でも5秒は空ける。
const SNAPSHOT_MIN_GAP_MS: i64 = 30_000;
const SNAPSHOT_FORCE_GAP_MS: i64 = 5_000;
pub(crate) const CATALOG_MAX_AGE_MS: i64 = 6 * 3600 * 1000;
const RATE_WINDOW_MS: i64 = 5 * 60 * 1000;
const RATE_MAX_CALLS: usize = 20;
pub(crate) const GB: f64 = 1_048_576.0;

struct LoginFlow {
    backend: Backend,
    device_id: String,
    email: Option<String>,
    phone: Option<String>,
    pending: Vec<ActionType>,
    auth_id: Option<String>,
    challenges: Vec<(ActionType, AuthChallenge)>,
    failed_attempts: u32,
}

pub struct Engine {
    path: PathBuf,
    pub(crate) mock: bool,
    scenario: String,
    pub(crate) st: PersistState,
    session: Option<(Backend, StoredSession)>,
    login: Option<LoginFlow>,
    store: Box<dyn SessionStore>,
    calls: Vec<i64>,
    #[cfg(test)]
    pub clock: Option<i64>,
}

pub(crate) fn local(msg: impl Into<String>) -> Failure {
    Failure::local(msg)
}

pub(crate) fn new_id() -> String {
    use rand::RngCore;
    let mut b = [0u8; 6];
    rand::rngs::OsRng.fill_bytes(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn action_label(a: &ActionType) -> &'static str {
    match a {
        ActionType::EmailOtp => "メールに届いたコード",
        ActionType::LoginOtp | ActionType::RegisterOtp => "SMSに届いたコード",
    }
}

fn clean(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// 公式アプリの入力欄と同じ整え方(povo-web と同じ)。
pub fn normalize_code(raw: &str) -> Result<String, String> {
    let code = raw.trim().to_ascii_uppercase();
    if code.is_empty() {
        return Err("コードが空です。".into());
    }
    if code.chars().count() > CODE_MAX_LEN {
        return Err(format!("コードは{CODE_MAX_LEN}文字以内です(公式アプリと同じ上限)。"));
    }
    if !code.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err("コードに使えるのは英数字と - _ だけです。".into());
    }
    Ok(code)
}

pub fn mask(code: &str) -> String {
    let n = code.chars().count();
    if n <= 4 {
        return "•".repeat(n);
    }
    let head: String = code.chars().take(2).collect();
    let tail: String = code.chars().skip(n - 2).collect();
    format!("{head}{}{tail}", "•".repeat(n - 4))
}

pub(crate) fn yen(p: Option<u32>) -> String {
    p.map(|p| format!(" {p}円")).unwrap_or_default()
}

impl Engine {
    pub fn open(config: &EngineConfig, store: Box<dyn SessionStore>) -> Engine {
        let base = PathBuf::from(&config.dir);
        let _ = std::fs::create_dir_all(&base);
        let path = base.join(if config.mock { "state-mock.json" } else { "state.json" });
        let (st, dropped) = PersistState::load(&path);
        let mut e = Engine {
            path,
            mock: config.mock,
            scenario: config.mock_scenario.clone(),
            st,
            session: None,
            login: None,
            store,
            calls: vec![],
            #[cfg(test)]
            clock: None,
        };
        if !dropped.is_empty() {
            e.log(LogLevel::Warn, format!("保存データの一部を読めなかったので初期値に戻しました: {}", dropped.join(", ")));
        }
        let restore = if e.mock { e.st.mock_session.clone() } else { e.store.load() };
        if let Some(s) = restore {
            let b = Backend::with_scenario(e.mock, &s.device_id, &e.scenario);
            b.restore(&s.auth_token, s.sin.clone());
            e.session = Some((b, s));
        }
        e.save();
        e
    }

    pub(crate) fn now(&self) -> i64 {
        #[cfg(test)]
        if let Some(c) = self.clock {
            return c;
        }
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
    }

    pub(crate) fn save(&mut self) {
        let path = self.path.clone();
        self.st.save(&path);
    }

    pub(crate) fn log(&mut self, level: LogLevel, message: impl Into<String>) {
        let time_ms = self.now();
        self.st.log.push(LogEntry { time_ms, level, message: message.into() });
    }

    fn session_changed(&mut self) {
        let Some((_, s)) = &self.session else { return };
        let s = s.clone();
        if self.mock {
            self.st.mock_session = Some(s);
        } else {
            self.store.save(s);
        }
    }

    pub fn logged_in(&self) -> bool {
        self.session.is_some()
    }

    // ---- 状態 --------------------------------------------------------------------

    pub fn status(&self) -> EngineStatus {
        let now = self.now();
        let login = self.login.as_ref().map(|l| LoginState {
            identifier: l.email.clone().or(l.phone.clone()),
            current: l.pending.first().map(|a| action_label(a).to_string()),
            remaining: l.pending.len() as u32,
        });
        let otp_cooldown_s = self
            .st
            .last_otp_sent_ms
            .map(|t| (OTP_COOLDOWN_MS - (now - t)) / 1000)
            .filter(|s| *s > 0)
            .map(|s| s as u32);
        EngineStatus {
            mock: self.mock,
            logged_in: self.session.is_some(),
            identifier: self.session.as_ref().map(|(_, s)| s.identifier.clone()),
            halted: self.st.halted.clone(),
            blocked_until_ms: self.st.blocked_until_ms.filter(|t| *t > now),
            login,
            otp_cooldown_s,
            settings: self.st.settings.clone(),
            budget: self.budget(),
            codes_pending: self.st.codes.iter().filter(|c| c.status == CodeStatus::Pending).count() as u32,
            pending_actions: self.st.pending.iter().filter(|p| p.expires_ms > now).count() as u32,
            snapshot_ms: self.st.snapshot.as_ref().map(|s| s.fetched_ms),
        }
    }

    // ---- 安全装置 ------------------------------------------------------------------

    pub(crate) fn gate(&self) -> R<()> {
        if let Some(reason) = &self.st.halted {
            return Err(Failure {
                hint: Some("原因を確認してから、アプリの「通信を再開」を押してください。".into()),
                halt: true,
                ..local(format!("安全のため povo への通信を止めています: {reason}"))
            });
        }
        if let Some(until) = self.st.blocked_until_ms {
            if until > self.now() {
                return Err(Failure { block_until_ms: Some(until), ..local("povo から待機を求められています。") });
            }
        }
        Ok(())
    }

    pub(crate) fn note(&mut self, f: &Failure) {
        if f.halt {
            let reason = match f.povo_status {
                Some(s) => format!("HTTP {s} {}", f.message),
                None => f.message.clone(),
            };
            self.log(LogLevel::Error, format!("通信を停止しました: {reason}"));
            self.st.halted = Some(reason);
        }
        if let Some(until) = f.block_until_ms {
            self.st.blocked_until_ms = Some(until);
        }
    }

    fn backend(&self) -> R<Backend> {
        self.session.as_ref().map(|(b, _)| b.clone()).ok_or_else(|| local("ログインしていません。"))
    }

    fn count_call(&mut self) -> R<()> {
        let now = self.now();
        self.calls.retain(|t| now - *t < RATE_WINDOW_MS);
        if self.calls.len() >= RATE_MAX_CALLS {
            return Err(local(format!(
                "povo への通信が5分間に{RATE_MAX_CALLS}回を超えそうなので止めました。少し待ってからにしてください。"
            )));
        }
        self.calls.push(now);
        Ok(())
    }

    /// ログイン済みセッションで povo を1回呼ぶ。期限切れなら先にトークンを1回だけ更新して保存する。
    pub(crate) fn povo<T>(&mut self, op: impl FnOnce(&Backend) -> R<T>) -> R<T> {
        self.gate()?;
        let b = self.backend()?;
        if b.token().map(|t| protocol::is_expired(&t)).unwrap_or(true) {
            self.count_call()?;
        }
        match b.refresh_if_expired() {
            Ok(Some(token)) => {
                if let Some((_, s)) = self.session.as_mut() {
                    s.auth_token = token;
                }
                self.session_changed();
            }
            Ok(None) => {}
            Err(f) => {
                self.note(&f);
                return Err(f);
            }
        }
        self.count_call()?;
        let r = op(&b);
        if let Err(f) = &r {
            self.note(f);
        }
        r
    }

    pub fn unhalt(&mut self) {
        self.st.halted = None;
        self.st.blocked_until_ms = None;
        self.log(LogLevel::Info, "通信を再開しました");
    }

    // ---- ログイン ----------------------------------------------------------------

    fn otp_wait(&self) -> R<()> {
        if let Some(t) = self.st.last_otp_sent_ms {
            let left = OTP_COOLDOWN_MS - (self.now() - t);
            if left > 0 {
                return Err(local(format!("コード送信は60秒に1回までです。あと{}秒待ってください。", left / 1000 + 1)));
            }
        }
        Ok(())
    }

    pub fn login_start(&mut self, email: Option<String>, phone: Option<String>) -> R<LoginStep> {
        self.gate()?;
        if self.session.is_some() {
            return Err(local("既にログインしています。別の回線にするには先にログアウトしてください。"));
        }
        self.otp_wait()?;
        let email = clean(email);
        let phone = clean(phone).map(|p| p.replace(['-', ' '], ""));
        if email.is_none() && phone.is_none() {
            return Err(local("メールアドレスか電話番号を入力してください。"));
        }
        // 端末IDはこのアカウント用に1回だけ作り、以後ずっと使う。
        let device_id = protocol::new_device_id();
        let backend = Backend::with_scenario(self.mock, &device_id, &self.scenario);
        let result = (|| {
            let actions = backend.login_actions(email.clone(), phone.clone())?;
            let auth_id = backend.send_otp(actions[0], email.as_deref(), phone.as_deref())?;
            Ok((actions, auth_id))
        })();
        let (actions, auth_id) = match result {
            Ok(v) => v,
            Err(f) => {
                self.note(&f);
                return Err(f);
            }
        };
        self.st.last_otp_sent_ms = Some(self.now());
        let current = action_label(&actions[0]).to_string();
        self.login = Some(LoginFlow { backend, device_id, email, phone, pending: actions, auth_id: Some(auth_id), challenges: vec![], failed_attempts: 0 });
        Ok(LoginStep { done: false, sent: Some(current) })
    }

    pub fn login_resend(&mut self) -> R<LoginStep> {
        self.gate()?;
        self.otp_wait()?;
        let flow = self.login.as_ref().ok_or_else(|| local("ログイン手続き中ではありません。"))?;
        let action = *flow.pending.first().ok_or_else(|| local("送るコードがありません。"))?;
        match flow.backend.send_otp(action, flow.email.as_deref(), flow.phone.as_deref()) {
            Ok(auth_id) => {
                self.st.last_otp_sent_ms = Some(self.now());
                if let Some(f) = self.login.as_mut() {
                    f.auth_id = Some(auth_id);
                }
                Ok(LoginStep { done: false, sent: Some(action_label(&action).into()) })
            }
            Err(f) => {
                self.note(&f);
                Err(f)
            }
        }
    }

    pub fn login_otp(&mut self, code: &str) -> R<LoginStep> {
        self.gate()?;
        let code: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
        if code.is_empty() {
            return Err(local("コードを入力してください。"));
        }
        let flow = self.login.as_ref().ok_or_else(|| local("ログイン手続き中ではありません。"))?;
        let action = *flow.pending.first().ok_or_else(|| local("認証ステップがありません。"))?;
        let auth_id = flow.auth_id.clone().ok_or_else(|| local("先にコードを送信してください。"))?;
        let this = (action, AuthChallenge { auth_id, otp_code: code, device_id: flow.device_id.clone() });

        // 次の認証ステップがあれば、このコードを積んで次のコードを送る(povo-android と同じ)。
        if let Some(next) = flow.pending.get(1).copied() {
            return match flow.backend.send_otp(next, flow.email.as_deref(), flow.phone.as_deref()) {
                Ok(id) => {
                    self.st.last_otp_sent_ms = Some(self.now());
                    if let Some(flow) = self.login.as_mut() {
                        flow.challenges.push(this);
                        flow.pending.remove(0);
                        flow.auth_id = Some(id);
                    }
                    Ok(LoginStep { done: false, sent: Some(action_label(&next).into()) })
                }
                Err(f) => {
                    self.note(&f);
                    Err(f)
                }
            };
        }

        let mut all = flow.challenges.clone();
        all.push(this);
        let email_auth = all.iter().find(|(a, _)| *a == ActionType::EmailOtp).map(|(_, c)| c.clone());
        let mobile_auth = all.iter().find(|(a, _)| *a != ActionType::EmailOtp).map(|(_, c)| c.clone());
        let b = flow.backend.clone();
        // login → profile(SIN をここで確定)。トークンを得た後の profile 失敗でログインを捨てない。
        let result = b.login(email_auth, mobile_auth).map(|token| {
            let sin = b.profile().ok().and_then(|_| b.sin());
            (token, sin)
        });
        match result {
            Ok((token, sin)) => {
                let Some(flow) = self.login.take() else { return Err(local("ログイン手続きが見つかりません。")) };
                let stored = StoredSession {
                    device_id: flow.device_id,
                    auth_token: token,
                    sin,
                    identifier: flow.email.or(flow.phone).unwrap_or_default(),
                };
                self.session = Some((flow.backend, stored));
                self.session_changed();
                self.log(LogLevel::Info, "ログインしました");
                Ok(LoginStep { done: true, sent: None })
            }
            Err(mut f) => {
                self.note(&f);
                let attempts = self.login.as_mut().map(|fl| {
                    fl.failed_attempts += 1;
                    fl.failed_attempts
                });
                if attempts.unwrap_or(MAX_OTP_ATTEMPTS) >= MAX_OTP_ATTEMPTS {
                    self.login = None;
                    f.hint = Some("3回失敗したので手続きを中止しました。時間をおいて、最初からやり直してください。".into());
                } else {
                    f.hint = Some(format!(
                        "コードを確認してもう一度入力できます(あと{}回)。{}",
                        MAX_OTP_ATTEMPTS - attempts.unwrap_or(0),
                        f.hint.clone().unwrap_or_default()
                    ));
                }
                Err(f)
            }
        }
    }

    pub fn login_cancel(&mut self) {
        self.login = None;
    }

    /// この端末からセッションを消すだけ。povo 側には何も送らない。
    pub fn logout(&mut self) {
        self.session = None;
        self.login = None;
        self.st.snapshot = None;
        self.st.catalog = None;
        self.st.pending.clear();
        if self.mock {
            self.st.mock_session = None;
            self.st.history.clear();
        } else {
            self.store.clear();
        }
        self.log(LogLevel::Info, "ログアウトしました");
    }

    // ---- 残量 ----------------------------------------------------------------------

    pub fn snapshot(&mut self, force: bool) -> R<Snapshot> {
        let gap = if force { SNAPSHOT_FORCE_GAP_MS } else { SNAPSHOT_MIN_GAP_MS };
        if let Some(s) = &self.st.snapshot {
            if self.now() - s.fetched_ms < gap && self.session.is_some() {
                let mut s = s.clone();
                s.cached = true;
                return Ok(s);
            }
        }
        self.fetch_snapshot()
    }

    pub(crate) fn fetch_snapshot(&mut self) -> R<Snapshot> {
        // 回線番号(SIN)がまだ無いときだけ profile を呼ぶ(povo-android と同じく SIN はここで決まる)。
        if self.session.as_ref().is_some_and(|(_, s)| s.sin.is_none()) {
            self.povo(|b| b.profile())?;
            let sin = self.backend()?.sin();
            if sin.is_some() {
                if let Some((_, s)) = self.session.as_mut() {
                    s.sin = sin;
                }
                self.session_changed();
            }
        }
        let usage_raw = self.povo(|b| b.usage_raw())?;
        let usage = parse::usage(&usage_raw);
        let (toppings, toppings_error) = match self.povo(|b| b.quilt("user-plan-details-v2")) {
            Ok(raw) => (parse::toppings(&raw), None),
            Err(f) if f.halt || f.block_until_ms.is_some() => return Err(f),
            Err(f) => (None, Some(f.message)),
        };
        let now = self.now();
        let snap = build_snapshot(now, usage.as_ref(), toppings.as_ref(), toppings_error);
        if let Some(left) = snap.left_kb {
            if self.mock {
                history::seed_mock(&mut self.st.history, now, left);
            }
            history::record(&mut self.st.history, UsageSample { t_ms: now, left_kb: left, unlimited: snap.unlimited.active == Some(true) });
        }
        self.st.snapshot = Some(snap.clone());
        Ok(snap)
    }

    /// 十分新しい残量を用意する(コード適用前の「使い放題中か」の確認用)。
    pub(crate) fn recent_snapshot(&mut self, max_age_ms: i64) -> R<Snapshot> {
        match &self.st.snapshot {
            Some(s) if self.now() - s.fetched_ms <= max_age_ms => Ok(s.clone()),
            _ => self.fetch_snapshot(),
        }
    }

    pub fn cached_snapshot(&self) -> Option<Snapshot> {
        self.st.snapshot.clone()
    }

    pub fn history(&self, hours: u32) -> Vec<UsageSample> {
        let since = self.now() - hours as i64 * 3_600_000;
        self.st.history.iter().filter(|s| s.t_ms >= since).cloned().collect()
    }

    pub fn insights(&self) -> UsageInsights {
        history::insights(&self.st.history, self.now())
    }

    pub fn purchase_history(&mut self) -> R<Vec<Purchase>> {
        let raw = self.povo(|b| b.quilt("order-history"))?;
        let v = parse::purchases(&raw).ok_or_else(|| local("購入履歴の形を読めませんでした。"))?;
        Ok(v.as_array()
            .into_iter()
            .flatten()
            .map(|p| Purchase {
                order_id: p["order_id"].as_str().map(String::from),
                status: p["status"].as_str().map(String::from),
                date: p["date"].as_str().map(String::from),
                date_iso: p["date_iso"].as_str().map(String::from),
                items: p["products"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|i| PurchaseItem { name: i["name"].as_str().map(String::from), price: i["price"].as_str().map(String::from) })
                    .collect(),
            })
            .collect())
    }

    // ---- 請求・紹介・プロフィール(読み取り) --------------------------------------

    /// 請求の一覧(過去・今月・都度課金)。
    pub fn bills(&mut self) -> R<Bills> {
        let raw = self.povo(|b| b.bills_raw())?;
        let v = parse::bills(&raw).ok_or_else(|| local("請求の形を読めませんでした。"))?;
        let entries = v["entries"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|e| BillEntry {
                kind: e["kind"].as_str().unwrap_or("unknown").to_string(),
                title: e["title"].as_str().map(String::from),
                subtitle: e["subtitle"].as_str().map(String::from),
                amount: e["amount"].as_str().map(String::from),
                time_ms: e["time_ms"].as_i64(),
                bill_id: e["bill_id"].as_str().map(String::from),
            })
            .collect();
        Ok(Bills { entries, upcoming_total: v["upcoming_total"].as_str().map(String::from) })
    }

    /// 請求書 PDF の中身(パスワード付き。パスワードは生年月日 YYYY-MM-DD)。
    pub fn bill_pdf(&mut self, bill_id: &str) -> R<Vec<u8>> {
        self.povo(|b| b.bill_pdf(bill_id))
    }

    /// 友だち紹介コード。
    pub fn referral(&mut self) -> R<Referral> {
        let raw = self.povo(|b| b.referral_raw())?;
        let v = parse::referral(&raw).ok_or_else(|| local("紹介コードの形を読めませんでした。"))?;
        Ok(Referral { code: v["code"].as_str().map(String::from), message: v["message"].as_str().map(String::from) })
    }

    /// アカウントの基本情報。
    pub fn account_profile(&mut self) -> R<AccountProfile> {
        let v = self.povo(|b| b.profile())?;
        Ok(AccountProfile {
            first_name: v["first_name"].as_str().map(String::from),
            email: v["email"].as_str().map(String::from),
            phone: v["phone"].as_str().map(String::from),
            status: v["status"].as_str().map(String::from),
            plan: v["plan"].as_str().map(String::from),
            activation_date: v["activation_date"].as_str().map(String::from),
        })
    }

    // ---- 次の自動チェック ------------------------------------------------------------

    /// 次の自動チェックまでの目安(分)。残量の減り方・使い放題の終わり・残りの少なさで縮める。
    pub fn next_check_delay_min(&self) -> u32 {
        let s = &self.st.settings;
        let min = s.check_min_interval_min.max(15) as f64;
        let max = (s.check_max_interval_min as f64).max(min);
        let mut d = max;
        let now = self.now();
        if let Some(snap) = &self.st.snapshot {
            if snap.unlimited.active == Some(true) {
                if let Some(u) = snap.unlimited.until_ms {
                    d = d.min((u - now) as f64 / 60_000.0 + 2.0);
                }
            } else {
                if let Some(h) = self.insights().hours_left {
                    d = d.min(h * 60.0 / 4.0);
                }
                if snap.left_kb.is_some_and(|l| l < GB) {
                    d = d.min(30.0);
                }
            }
        }
        d.clamp(min, max).round() as u32
    }

    // ---- カタログと手動購入 ------------------------------------------------------------

    pub fn catalog(&mut self, force: bool) -> R<Catalog> {
        if !force {
            if let Some(c) = &self.st.catalog {
                if self.now() - c.fetched_ms < CATALOG_MAX_AGE_MS {
                    return Ok(c.clone());
                }
            }
        }
        let raw = self.povo(|b| b.quilt("dashboard-v2"))?;
        let sections = parse::catalog(&raw)
            .ok_or_else(|| local("トッピング一覧の形を読めませんでした(povo 側の変更の可能性)。購入は行わないでください。"))?;
        let c = Catalog { fetched_ms: self.now(), products: catalog::products(&sections) };
        self.st.catalog = Some(c.clone());
        Ok(c)
    }

    pub fn cached_catalog(&self) -> Option<Catalog> {
        self.st.catalog.clone()
    }

    pub(crate) fn find_product(&self, sku: &str) -> Option<Product> {
        self.st.catalog.as_ref()?.products.iter().find(|p| p.sku == sku).cloned()
    }

    /// 新しいカタログに載っている商品を探す(古ければ取り直す)。
    pub(crate) fn fresh_product(&mut self, sku: &str) -> R<Option<Product>> {
        let now = self.now();
        let stale = self.st.catalog.as_ref().map(|c| now - c.fetched_ms >= CATALOG_MAX_AGE_MS).unwrap_or(true);
        if stale || self.find_product(sku).is_none() {
            self.catalog(true)?;
        }
        Ok(self.find_product(sku))
    }

    pub fn budget(&self) -> Budget {
        let now = self.now();
        let (y, m, _) = jptime::jst_ymd(now);
        let today = jptime::jst_ymd(now);
        let in_month = |e: &&LedgerEntry| {
            let (ey, em, _) = jptime::jst_ymd(e.time_ms);
            ey == y && em == m
        };
        let rule = |e: &&LedgerEntry| e.source == OrderSource::Rule;
        let rule_spent: u32 = self.st.ledger.iter().filter(rule).filter(in_month).filter_map(|e| e.price_yen).sum();
        let all_spent: u32 = self.st.ledger.iter().filter(in_month).filter_map(|e| e.price_yen).sum();
        let today_count = self.st.ledger.iter().filter(rule).filter(|e| jptime::jst_ymd(e.time_ms) == today).count() as u32;
        let cap = self.st.settings.monthly_cap_yen;
        Budget {
            cap_yen: cap,
            rule_spent_yen: rule_spent,
            all_spent_yen: all_spent,
            remaining_yen: cap.saturating_sub(rule_spent),
            rule_orders_today: today_count,
            max_per_day: self.st.settings.max_rule_orders_per_day,
        }
    }

    pub(crate) fn recently_ordered(&self, sku: &str) -> bool {
        let now = self.now();
        self.st.ledger.iter().any(|e| e.sku == sku && now - e.time_ms < SAME_ORDER_COOLDOWN_MS)
    }

    /// 注文を送る(手動・ルール共通)。送る前に記録・保存する。
    pub(crate) fn send_order(&mut self, sku: &str, product: Option<&Product>, source: OrderSource) -> R<OrderResult> {
        let now = self.now();
        let name = product.map(|p| p.name.clone());
        let price = product.and_then(|p| p.price_yen);
        self.st.ledger.push(LedgerEntry {
            time_ms: now,
            sku: sku.to_string(),
            name: name.clone(),
            price_yen: price,
            source,
            status: LedgerStatus::Sent,
            message: None,
            challenge_url: None,
        });
        let idx = self.st.ledger.len() - 1;
        self.save();
        let label = name.unwrap_or_else(|| sku.to_string());
        let who = if source == OrderSource::Rule { "ルールで購入" } else { "購入" };
        let s = sku.to_string();
        match self.povo(move |b| b.place_order(&s)) {
            Ok(raw) => {
                let parsed = parse::order(&raw).unwrap_or(Value::Null);
                let challenge = parsed.get("challenge_url").and_then(|v| v.as_str()).map(String::from);
                let order_ref = parsed.get("order_ref").and_then(|v| v.as_str()).map(String::from);
                let e = &mut self.st.ledger[idx];
                if let Some(url) = &challenge {
                    e.status = LedgerStatus::Needs3ds;
                    e.challenge_url = Some(url.clone());
                    self.log(LogLevel::Warn, format!("{who}: {label} は3Dセキュアの認証待ちです(まだ課金されていません)"));
                } else {
                    e.status = LedgerStatus::Ok;
                    self.log(LogLevel::Action, format!("{who}: {label}{} を注文しました", yen(price)));
                }
                // 次の残量取得で反映を確かめる
                if let Some(s) = self.st.snapshot.as_mut() {
                    s.fetched_ms = 0;
                }
                Ok(OrderResult { needs_3ds: challenge.is_some(), challenge_url: challenge, order_ref })
            }
            Err(f) => {
                let e = &mut self.st.ledger[idx];
                e.status = LedgerStatus::Error;
                e.message = Some(f.message.clone());
                self.log(LogLevel::Error, format!("{who}に失敗: {label}: {}(課金された可能性があるので購入履歴を確認してください)", f.message));
                Err(f)
            }
        }
    }

    /// ショップからの手動購入。確認語が要る。
    pub fn order_manual(&mut self, sku: &str, confirm: &str) -> R<OrderResult> {
        let sku = sku.trim();
        if sku.is_empty() || sku.len() > 200 {
            return Err(local("商品IDが不正です。"));
        }
        if confirm.trim() != ORDER_CONFIRM {
            return Err(local(format!("確認欄に「{ORDER_CONFIRM}」と入力してください。")));
        }
        self.gate()?;
        self.backend()?;
        if self.recently_ordered(sku) {
            return Err(local("同じ商品を続けて注文しようとしています。二重購入防止のため2分待ち、購入履歴を確認してください。"));
        }
        let product = self.find_product(sku);
        self.send_order(sku, product.as_ref(), OrderSource::Manual)
    }

    // ---- コード ---------------------------------------------------------------------

    pub fn codes(&self) -> Vec<CodeEntry> {
        self.st.codes.iter().map(|c| CodeEntry { masked: mask(&c.code), ..c.clone() }).collect()
    }

    /// 1行に1コード。「コード タグ メモ…」(空白・カンマ・タブ区切り)。
    pub fn add_codes(&mut self, text: &str, default_tag: Option<String>) -> AddCodesResult {
        let default_tag = clean(default_tag).unwrap_or_default();
        let mut added = 0;
        let mut duplicates = Vec::new();
        let mut invalid = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut parts = line.split(|c: char| c.is_whitespace() || c == ',').filter(|s| !s.is_empty());
            let raw = parts.next().unwrap_or("");
            let code = match normalize_code(raw) {
                Ok(c) => c,
                Err(e) => {
                    invalid.push(format!("{raw}: {e}"));
                    continue;
                }
            };
            if self.st.codes.iter().any(|c| c.code == code) {
                duplicates.push(mask(&code));
                continue;
            }
            let tag = parts.next().map(|t| t.to_string()).unwrap_or_else(|| default_tag.clone());
            let note = parts.collect::<Vec<_>>().join(" ");
            let now = self.now();
            self.st.codes.push(CodeEntry {
                id: new_id(),
                masked: mask(&code),
                code,
                tag,
                note,
                status: CodeStatus::Pending,
                added_ms: now,
                sent_ms: None,
                result: None,
            });
            added += 1;
        }
        if added > 0 {
            self.log(LogLevel::Info, format!("コードを{added}件登録しました"));
        }
        AddCodesResult { added, duplicates, invalid }
    }

    fn code_index(&self, id: &str) -> R<usize> {
        self.st.codes.iter().position(|c| c.id == id).ok_or_else(|| local("そのコードは見つかりません。"))
    }

    pub fn remove_code(&mut self, id: &str) -> R<()> {
        let i = self.code_index(id)?;
        self.st.codes.remove(i);
        self.st.pending.retain(|p| p.code_id.as_deref() != Some(id));
        Ok(())
    }

    /// 利用者が明示的に「未使用に戻す」ときだけ。自動では決してしない。
    pub fn reset_code(&mut self, id: &str) -> R<()> {
        let i = self.code_index(id)?;
        let c = &mut self.st.codes[i];
        c.status = CodeStatus::Pending;
        c.result = None;
        Ok(())
    }

    pub fn update_code(&mut self, id: &str, tag: &str, note: &str) -> R<()> {
        let i = self.code_index(id)?;
        let c = &mut self.st.codes[i];
        c.tag = tag.trim().to_string();
        c.note = note.trim().to_string();
        Ok(())
    }

    pub(crate) fn code_cooldown_left_ms(&self) -> i64 {
        self.st.last_code_sent_ms.map(|t| CODE_COOLDOWN_MS - (self.now() - t)).unwrap_or(0)
    }

    /// コードを送る(手動・ルール共通)。送る前に「送信済み」にして保存する。
    /// povo が受け付けなかった(codeValid=false)ときは Ok(valid=false)。
    pub(crate) fn send_code(&mut self, idx: usize, who: &str) -> R<CodeResult> {
        let now = self.now();
        {
            let c = &mut self.st.codes[idx];
            c.status = CodeStatus::Sent;
            c.sent_ms = Some(now);
        }
        self.st.last_code_sent_ms = Some(now);
        self.save();
        let code = self.st.codes[idx].code.clone();
        let masked = mask(&code);
        let tag = self.st.codes[idx].tag.clone();
        match self.povo(move |b| b.apply_code(&code)) {
            Ok(raw) => match parse::code_result(&raw) {
                Some(v) => {
                    let valid = v["valid"].as_bool().unwrap_or(false);
                    let title = v["title"].as_str().map(String::from);
                    let message = [v["subtitle"].as_str(), v["message"].as_str()]
                        .into_iter()
                        .flatten()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(" / ");
                    let text = [title.clone().unwrap_or_default(), message.clone()]
                        .into_iter()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(" / ");
                    let c = &mut self.st.codes[idx];
                    c.status = if valid { CodeStatus::Applied } else { CodeStatus::Rejected };
                    c.result = Some(text.clone());
                    if let Some(s) = self.st.snapshot.as_mut() {
                        s.fetched_ms = 0;
                    }
                    if valid {
                        self.log(LogLevel::Action, format!("{who}: {masked}({tag})を適用しました: {text}"));
                    } else {
                        self.log(LogLevel::Warn, format!("{who}: {masked}({tag})は受け付けられませんでした: {text}"));
                    }
                    Ok(CodeResult { masked, tag, valid, title, message: Some(message).filter(|m| !m.is_empty()) })
                }
                None => {
                    let msg = "応答の形を読めませんでした。適用されたかどうかは、ご利用中のトッピングで確認してください。";
                    let c = &mut self.st.codes[idx];
                    c.status = CodeStatus::Error;
                    c.result = Some(msg.into());
                    self.log(LogLevel::Error, format!("{who}: {masked}: {msg}"));
                    Err(local(msg))
                }
            },
            Err(f) => {
                let c = &mut self.st.codes[idx];
                c.status = CodeStatus::Error;
                c.result = Some(f.message.clone());
                self.log(LogLevel::Error, format!("{who}に失敗: {masked}: {}", f.message));
                Err(f)
            }
        }
    }

    /// 「使い放題中か」の確認。止めるべき理由があれば Some(理由)。
    /// strict なら「分からない」ときも止める(ルールによる適用)。
    pub(crate) fn unlimited_block(&mut self, strict: bool) -> R<Option<String>> {
        let snap = self.recent_snapshot(5 * 60 * 1000)?;
        Ok(unlimited_reason(snap.unlimited.active, strict))
    }

    /// コード画面からの手動適用。確認語が要る。
    pub fn apply_code_manual(&mut self, id: Option<String>, raw: Option<String>, confirm: &str) -> R<CodeResult> {
        if confirm.trim() != CODE_CONFIRM {
            return Err(local(format!("確認欄に「{CODE_CONFIRM}」と入力してください。")));
        }
        self.gate()?;
        self.backend()?;
        let idx = if let Some(raw) = clean(raw) {
            let code = normalize_code(&raw).map_err(local)?;
            match self.st.codes.iter().position(|c| c.code == code) {
                Some(i) => i,
                None => {
                    let now = self.now();
                    self.st.codes.push(CodeEntry {
                        id: new_id(),
                        masked: mask(&code),
                        code,
                        tag: "手入力".into(),
                        note: String::new(),
                        status: CodeStatus::Pending,
                        added_ms: now,
                        sent_ms: None,
                        result: None,
                    });
                    self.st.codes.len() - 1
                }
            }
        } else if let Some(id) = clean(id) {
            self.code_index(&id)?
        } else {
            return Err(local("コードが指定されていません。"));
        };
        if self.st.codes[idx].status != CodeStatus::Pending {
            return Err(local(
                "このコードはすでに送っています。結果はご利用中のトッピングで確認してください(送り直すには、コード一覧で「未使用に戻す」)。",
            ));
        }
        let left = self.code_cooldown_left_ms();
        if left > 0 {
            return Err(local(format!("コードの送信は15秒に1回までです。あと{}秒待ってください。", left / 1000 + 1)));
        }
        if let Some(reason) = self.unlimited_block(false)? {
            return Err(local(reason));
        }
        let id = self.st.codes[idx].id.clone();
        self.st.pending.retain(|p| p.code_id.as_deref() != Some(id.as_str()));
        self.send_code(idx, "コード適用")
    }

    // ---- 設定・記録 ---------------------------------------------------------------------

    pub fn settings(&self) -> Settings {
        self.st.settings.clone()
    }

    pub fn update_settings(&mut self, mut s: Settings) -> Settings {
        s.monthly_cap_yen = s.monthly_cap_yen.min(100_000);
        s.max_rule_orders_per_day = s.max_rule_orders_per_day.min(20);
        s.order_gap_min = s.order_gap_min.min(24 * 60);
        s.confirm_ttl_min = s.confirm_ttl_min.clamp(5, 24 * 60);
        s.check_min_interval_min = s.check_min_interval_min.clamp(15, 24 * 60);
        s.check_max_interval_min = s.check_max_interval_min.clamp(s.check_min_interval_min, 24 * 60);
        let before = self.st.settings.clone();
        let label = |m: ActionMode| match m {
            ActionMode::Off => "しない",
            ActionMode::Confirm => "通知で確認",
            ActionMode::Auto => "自動",
        };
        if before.purchase_mode != s.purchase_mode {
            self.log(LogLevel::Info, format!("ルールによる購入: {}", label(s.purchase_mode)));
        }
        if before.code_mode != s.code_mode {
            self.log(LogLevel::Info, format!("ルールによるコード適用: {}", label(s.code_mode)));
        }
        if before.dry_run != s.dry_run {
            self.log(LogLevel::Info, if s.dry_run { "試運転にしました(記録だけ)" } else { "試運転を切りました" });
        }
        self.st.settings = s.clone();
        s
    }

    pub fn ledger(&self, limit: u32) -> Vec<LedgerEntry> {
        self.st.ledger.iter().rev().take(limit as usize).cloned().collect()
    }

    pub fn logs(&self, limit: u32) -> Vec<LogEntry> {
        self.st.log.iter().rev().take(limit as usize).cloned().collect()
    }

    pub fn clear_logs(&mut self) {
        self.st.log.clear();
    }
}

pub(crate) fn unlimited_reason(active: Option<bool>, strict: bool) -> Option<String> {
    match active {
        Some(true) => Some("データ使い放題の有効期間中なので、コードを送りません(公式アプリの注意書きと同じ)。".into()),
        Some(false) => None,
        None if strict => Some("ご利用中のトッピングを読めず、使い放題中か確かめられないので、コードを送りません。".into()),
        None => None,
    }
}

/// 残量とトッピングの読み取り結果から Snapshot を作る。
pub(crate) fn build_snapshot(now: i64, usage: Option<&Value>, toppings: Option<&Value>, toppings_error: Option<String>) -> Snapshot {
    let buckets: Vec<Bucket> = usage
        .and_then(|u| u.get("buckets"))
        .and_then(|b| b.as_array())
        .map(|bs| {
            bs.iter()
                .map(|b| Bucket {
                    key: b["key"].as_str().unwrap_or("").to_string(),
                    label: b["label"].as_str().unwrap_or("").to_string(),
                    used_kb: b["used_kb"].as_f64().unwrap_or(0.0),
                    left_kb: b["left_kb"].as_f64().unwrap_or(0.0),
                    plan_kb: b["plan_kb"].as_f64(),
                })
                .collect()
        })
        .unwrap_or_default();
    let left_kb = usage.map(|_| buckets.iter().map(|b| b.left_kb).sum());
    let plan: f64 = buckets.iter().filter_map(|b| b.plan_kb).sum();
    let toppings: Option<Vec<Topping>> = toppings.and_then(|t| t.as_array()).map(|list| {
        list.iter()
            .filter_map(|t| {
                let name = t["name"].as_str()?.to_string();
                let expiry = t["expiry"].as_str().map(String::from);
                Some(Topping {
                    section: t["section"].as_str().map(String::from),
                    remaining: t["remaining"].as_str().map(String::from),
                    expiry_ms: expiry.as_deref().and_then(jptime::parse_jp_datetime),
                    expiry,
                    name,
                })
            })
            .collect()
    });
    // 「使い放題」のトッピングがあれば有効期間中とみなす(「かけ放題」は通話なので別)。
    let unl = toppings.as_ref().map(|list| list.iter().find(|t| t.name.contains("使い放題")).cloned());
    let unlimited = Unlimited {
        active: unl.as_ref().map(|u| u.is_some()),
        name: unl.as_ref().and_then(|u| u.as_ref().map(|t| t.name.clone())),
        until_ms: unl.as_ref().and_then(|u| u.as_ref().and_then(|t| t.expiry_ms)),
    };
    Snapshot {
        fetched_ms: now,
        left_kb,
        plan_kb: (plan > 0.0).then_some(plan),
        buckets,
        calls_used_sec: usage.and_then(|u| u["calls"]["used"].as_f64()),
        sms_used: usage.and_then(|u| u["sms"]["used"].as_f64()),
        toppings,
        toppings_error,
        unlimited,
        cached: false,
    }
}
