//! povoX のエンジン。iOS アプリ(画面・スクリプト・バックグラウンド・ショートカット)からの
//! 操作はすべてここを通り、povo への通信と安全装置はここで一元管理する。
//!
//! povo-web から引き継いだ約束ごと:
//! - povo への通信は常に1本ずつ(呼び出し側の Mutex で直列化)。自動リトライはしない。
//! - 403 や PIN 要求が返ったら、利用者がアプリで「再開」を押すまで povo への通信を止める
//!   (この停止は保存され、バックグラウンド実行やショートカットからも越えられない)。
//! - povo が待機時刻を返したら、その時刻まで送らない。
//! - トークン更新は期限切れ後だけ。端末IDとトークンは必ず組で保存する。
//! - OTP の再送は60秒に1回まで、入れ直しは3回まで。同じ商品の注文は120秒以内に繰り返せない。
//! - 購入・コード送信は、送る「前」に記録する(応答が失敗でも povo 側で処理された可能性があるため)。
//!
//! 自動化のために足したもの:
//! - 自動購入は「試運転」設定・月の上限金額・1日の回数・間隔・3DS 不要の商品だけ、をすべて満たすときだけ。
//! - コードの自動適用は、手持ちのコード一覧から1件ずつ。送ったコードは二度と自動では送らない。
//!   データ使い放題の有効期間中は送らない(公式アプリの注意書きと同じ)。
//! - povo への通信は5分間に20回まで(スクリプトの書き間違いで連打しないため)。

use std::path::PathBuf;

use povo_core::{ActionType, AuthChallenge};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::backend::{Backend, Failure, R};
use crate::{parse, protocol, timeutil};

pub const ORDER_CONFIRM: &str = "購入する";
pub const CODE_CONFIRM: &str = "利用する";
const OTP_COOLDOWN_MS: i64 = 60_000;
const MAX_OTP_ATTEMPTS: u32 = 3;
const SAME_ORDER_COOLDOWN_MS: i64 = 120_000;
const CODE_COOLDOWN_MS: i64 = 15_000;
const CODE_MAX_LEN: usize = 18;
/// 通常の残量取得は30秒以内なら前回の結果を返す。強制更新でも5秒は空ける。
const SNAPSHOT_MIN_GAP_MS: i64 = 30_000;
const SNAPSHOT_FORCE_GAP_MS: i64 = 5_000;
const CATALOG_MAX_AGE_MS: i64 = 6 * 3600 * 1000;
/// コード適用前の「使い放題中か」の確認に使える残量の古さ。
const UNLIMITED_CHECK_MAX_AGE_MS: i64 = 5 * 60 * 1000;
const RATE_WINDOW_MS: i64 = 5 * 60 * 1000;
const RATE_MAX_CALLS: usize = 20;
const LOG_MAX: usize = 300;
const LEDGER_MAX: usize = 500;

// ---- 保存する状態 -----------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Stored {
    pub device_id: String,
    pub auth_token: String,
    pub sin: Option<String>,
    pub identifier: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// 試運転: 自動の購入・コード適用を「したことにして」実際には送らない。
    pub dry_run: bool,
    /// 自動購入の月の上限(円、日本時間の暦月)。手動購入は数えない。
    pub monthly_cap_yen: u32,
    /// 自動購入の1日の上限回数(日本時間)。
    pub max_auto_orders_per_day: u32,
    /// 自動購入どうしの最小間隔(分)。
    pub auto_order_gap_min: u32,
    /// スクリプトからのコード自動適用を許すか。
    pub auto_codes: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { dry_run: true, monthly_cap_yen: 1000, max_auto_orders_per_day: 2, auto_order_gap_min: 30, auto_codes: true }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CodeStatus {
    /// 未使用。自動・手動で使える。
    Pending,
    /// 送信を始めたが結果を受け取れなかった(通信切れ・アプリ終了)。自動では送らない。
    Sent,
    Applied,
    Rejected,
    Error,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CodeEntry {
    pub id: String,
    pub code: String,
    #[serde(default)]
    pub tag: String,
    #[serde(default)]
    pub note: String,
    pub status: CodeStatus,
    pub added_ms: i64,
    #[serde(default)]
    pub sent_ms: Option<i64>,
    #[serde(default)]
    pub result: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub time_ms: i64,
    pub sku: String,
    pub name: Option<String>,
    pub price_yen: Option<u32>,
    pub auto: bool,
    /// sent(送信中・結果不明) / ok / needs_3ds / error
    pub status: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub challenge_url: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LogEntry {
    pub time_ms: i64,
    /// info / action / warn / error
    pub level: String,
    pub message: String,
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct PersistState {
    settings: Settings,
    halted: Option<String>,
    blocked_until_ms: Option<i64>,
    codes: Vec<CodeEntry>,
    ledger: Vec<LedgerEntry>,
    last_code_sent_ms: Option<i64>,
    last_otp_sent_ms: Option<i64>,
    snapshot: Option<Value>,
    snapshot_ms: i64,
    catalog: Option<Value>,
    catalog_ms: i64,
    log: Vec<LogEntry>,
    /// モックのときだけ、セッションもここに置く(本番はアプリがキーチェーンに置く)。
    mock_session: Option<Stored>,
}

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

/// アプリに伝えるセッションの変化(本番のみ)。アプリはこれをキーチェーンに反映する。
#[derive(Debug, Clone, PartialEq)]
pub enum SessionEvent {
    Save(Stored),
    Clear,
}

pub struct Engine {
    path: PathBuf,
    mock: bool,
    st: PersistState,
    session: Option<(Backend, Stored)>,
    login: Option<LoginFlow>,
    session_event: Option<SessionEvent>,
    calls: Vec<i64>,
    #[cfg(test)]
    pub clock: Option<i64>,
}

fn now_ms_real() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn local(msg: impl Into<String>) -> Failure {
    Failure::local(msg)
}

fn arg_str(req: &Value, key: &str) -> Option<String> {
    req.get(key).and_then(|v| v.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn arg_bool(req: &Value, key: &str) -> bool {
    req.get(key).and_then(|v| v.as_bool()).unwrap_or(false)
}

fn action_label(a: &ActionType) -> &'static str {
    match a {
        ActionType::EmailOtp => "メールに届いたコード",
        ActionType::LoginOtp | ActionType::RegisterOtp => "SMSに届いたコード",
    }
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

/// "2,700円" "¥330" "330" → 円。読めなければ None(その商品は自動購入しない)。
pub fn price_yen(text: &str) -> Option<u32> {
    let t = text.trim();
    if t.contains("無料") {
        return Some(0);
    }
    let digits_at = |s: &str| -> Option<u32> {
        let d: String = s.chars().take_while(|c| c.is_ascii_digit() || *c == ',').filter(|c| *c != ',').collect();
        d.parse().ok()
    };
    if let Some(i) = t.find(['¥', '￥']) {
        let rest = &t[i..];
        let rest = rest.trim_start_matches(['¥', '￥']).trim_start();
        if let Some(v) = digits_at(rest) {
            return Some(v);
        }
    }
    if let Some(i) = t.find('円') {
        let before: String = t[..i].chars().rev().take_while(|c| c.is_ascii_digit() || *c == ',').collect();
        let before: String = before.chars().rev().filter(|c| *c != ',').collect();
        if let Ok(v) = before.parse() {
            return Some(v);
        }
    }
    if !t.is_empty() && t.chars().all(|c| c.is_ascii_digit() || c == ',') {
        return digits_at(t);
    }
    None
}

fn mask(code: &str) -> String {
    let n = code.chars().count();
    if n <= 4 {
        return "•".repeat(n);
    }
    let head: String = code.chars().take(2).collect();
    let tail: String = code.chars().skip(n - 2).collect();
    format!("{head}{}{tail}", "•".repeat(n - 4))
}

impl Engine {
    /// `dir` はアプリの Application Support など。モックと本番は別のファイルに分ける。
    pub fn open(dir: &str, mock: bool, session: Option<Stored>) -> Engine {
        let base = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&base);
        let path = base.join(if mock { "state-mock.json" } else { "state.json" });
        let st: PersistState = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let mut e = Engine {
            path,
            mock,
            st,
            session: None,
            login: None,
            session_event: None,
            calls: vec![],
            #[cfg(test)]
            clock: None,
        };
        let restore = if mock { e.st.mock_session.clone() } else { session };
        if let Some(s) = restore {
            let b = Backend::new(mock, &s.device_id);
            b.restore(&s.auth_token, s.sin.clone());
            e.session = Some((b, s));
        }
        e
    }

    fn now(&self) -> i64 {
        #[cfg(test)]
        if let Some(c) = self.clock {
            return c;
        }
        now_ms_real()
    }

    pub fn take_session_event(&mut self) -> Option<SessionEvent> {
        self.session_event.take()
    }

    fn save(&mut self) {
        if self.st.log.len() > LOG_MAX {
            let cut = self.st.log.len() - LOG_MAX;
            self.st.log.drain(..cut);
        }
        if self.st.ledger.len() > LEDGER_MAX {
            let cut = self.st.ledger.len() - LEDGER_MAX;
            self.st.ledger.drain(..cut);
        }
        let Ok(bytes) = serde_json::to_vec(&self.st) else { return };
        let tmp = self.path.with_extension("tmp");
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }

    fn log(&mut self, level: &str, message: impl Into<String>) {
        let time_ms = self.now();
        self.st.log.push(LogEntry { time_ms, level: level.into(), message: message.into() });
    }

    fn session_changed(&mut self) {
        let Some((_, s)) = &self.session else { return };
        if self.mock {
            self.st.mock_session = Some(s.clone());
        } else {
            self.session_event = Some(SessionEvent::Save(s.clone()));
        }
    }

    // ---- 入口 ----------------------------------------------------------------

    pub fn handle(&mut self, op: &str, req: &Value) -> R<Value> {
        let out = match op {
            "status" => Ok(self.status()),
            "login_start" => self.login_start(req),
            "login_resend" => self.login_resend(),
            "login_otp" => self.login_otp(req),
            "login_cancel" => {
                self.login = None;
                Ok(json!({"ok": true}))
            }
            "logout" => Ok(self.logout()),
            "unhalt" => {
                self.st.halted = None;
                self.st.blocked_until_ms = None;
                self.log("info", "通信を再開しました");
                Ok(json!({"ok": true}))
            }
            "snapshot" => self.snapshot(arg_bool(req, "force")),
            "cached_snapshot" => Ok(self.st.snapshot.clone().unwrap_or(Value::Null)),
            "catalog" => self.catalog(arg_bool(req, "force")),
            "history" => self.history(),
            "order" => self.order(req),
            "codes" => Ok(self.codes_json()),
            "codes_add" => self.codes_add(req),
            "code_remove" => self.code_edit(req, "remove"),
            "code_reset" => self.code_edit(req, "reset"),
            "code_update" => self.code_edit(req, "update"),
            "apply_code" => self.apply_code(req),
            "settings" => Ok(json!(self.st.settings)),
            "settings_set" => self.settings_set(req),
            "budget" => Ok(self.budget()),
            "ledger" => Ok(json!(self.st.ledger.iter().rev().take(100).collect::<Vec<_>>())),
            "log" => {
                let level = arg_str(req, "level").unwrap_or_else(|| "info".into());
                let level = if ["info", "action", "warn", "error"].contains(&level.as_str()) { level } else { "info".into() };
                let msg: String = arg_str(req, "message").unwrap_or_default().chars().take(500).collect();
                self.log(&level, msg);
                Ok(json!({"ok": true}))
            }
            "logs" => {
                let limit = req.get("limit").and_then(|v| v.as_u64()).unwrap_or(200) as usize;
                Ok(json!(self.st.log.iter().rev().take(limit).collect::<Vec<_>>()))
            }
            "logs_clear" => {
                self.st.log.clear();
                Ok(json!({"ok": true}))
            }
            other => Err(local(format!("不明な操作: {other}"))),
        };
        self.save();
        out
    }

    fn status(&self) -> Value {
        let now = self.now();
        let login = self.login.as_ref().map(|l| {
            json!({
                "identifier": l.email.clone().or(l.phone.clone()),
                "current": l.pending.first().map(action_label),
                "remaining": l.pending.len(),
            })
        });
        let otp_cooldown_s = self
            .st
            .last_otp_sent_ms
            .map(|t| (OTP_COOLDOWN_MS - (now - t)) / 1000)
            .filter(|s| *s > 0);
        json!({
            "mock": self.mock,
            "logged_in": self.session.is_some(),
            "identifier": self.session.as_ref().map(|(_, s)| s.identifier.clone()),
            "halted": self.st.halted,
            "blocked_until_ms": self.st.blocked_until_ms.filter(|t| *t > now),
            "login": login,
            "otp_cooldown_s": otp_cooldown_s,
            "settings": self.st.settings,
            "budget": self.budget(),
            "codes_pending": self.st.codes.iter().filter(|c| c.status == CodeStatus::Pending).count(),
            "snapshot_ms": if self.st.snapshot.is_some() { json!(self.st.snapshot_ms) } else { Value::Null },
        })
    }

    // ---- 安全装置 --------------------------------------------------------------

    fn gate(&self) -> R<()> {
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

    fn note(&mut self, f: &Failure) {
        if f.halt {
            let reason = match f.povo_status {
                Some(s) => format!("HTTP {s} {}", f.message),
                None => f.message.clone(),
            };
            self.log("error", format!("通信を停止: {reason}"));
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
                "povo への通信が5分間に{RATE_MAX_CALLS}回を超えそうなので止めました。スクリプトが繰り返し呼んでいないか確認してください。"
            )));
        }
        self.calls.push(now);
        Ok(())
    }

    /// ログイン済みセッションで povo を1回呼ぶ。期限切れなら先にトークンを1回だけ更新して保存する。
    fn povo<T>(&mut self, op: impl FnOnce(&Backend) -> R<T>) -> R<T> {
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

    fn login_start(&mut self, req: &Value) -> R<Value> {
        self.gate()?;
        if self.session.is_some() {
            return Err(local("既にログインしています。別の回線にするには先にログアウトしてください。"));
        }
        self.otp_wait()?;
        let email = arg_str(req, "email");
        let phone = arg_str(req, "phone").map(|p| p.replace(['-', ' '], ""));
        if email.is_none() && phone.is_none() {
            return Err(local("メールアドレスか電話番号を入力してください。"));
        }
        // 端末IDはこのアカウント用に1回だけ作り、以後ずっと使う。
        let device_id = protocol::new_device_id();
        let backend = Backend::new(self.mock, &device_id);
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
        let current = action_label(&actions[0]);
        self.login = Some(LoginFlow { backend, device_id, email, phone, pending: actions, auth_id: Some(auth_id), challenges: vec![], failed_attempts: 0 });
        Ok(json!({ "sent": current }))
    }

    fn login_resend(&mut self) -> R<Value> {
        self.gate()?;
        self.otp_wait()?;
        let flow = self.login.as_ref().ok_or_else(|| local("ログイン手続き中ではありません。"))?;
        let action = *flow.pending.first().ok_or_else(|| local("送るコードがありません。"))?;
        let r = flow.backend.send_otp(action, flow.email.as_deref(), flow.phone.as_deref());
        match r {
            Ok(auth_id) => {
                self.st.last_otp_sent_ms = Some(self.now());
                self.login.as_mut().unwrap().auth_id = Some(auth_id);
                Ok(json!({ "sent": action_label(&action) }))
            }
            Err(f) => {
                self.note(&f);
                Err(f)
            }
        }
    }

    fn login_otp(&mut self, req: &Value) -> R<Value> {
        self.gate()?;
        let code: String = arg_str(req, "code").unwrap_or_default().chars().filter(|c| c.is_ascii_digit()).collect();
        if code.is_empty() {
            return Err(local("コードを入力してください。"));
        }
        let flow = self.login.as_ref().ok_or_else(|| local("ログイン手続き中ではありません。"))?;
        let action = *flow.pending.first().ok_or_else(|| local("認証ステップがありません。"))?;
        let auth_id = flow.auth_id.clone().ok_or_else(|| local("先にコードを送信してください。"))?;
        let this = (action, AuthChallenge { auth_id, otp_code: code, device_id: flow.device_id.clone() });

        // 次の認証ステップがあれば、このコードを積んで次のコードを送る(povo-android と同じ)。
        if let Some(next) = flow.pending.get(1).copied() {
            let r = flow.backend.send_otp(next, flow.email.as_deref(), flow.phone.as_deref());
            return match r {
                Ok(id) => {
                    self.st.last_otp_sent_ms = Some(self.now());
                    let flow = self.login.as_mut().unwrap();
                    flow.challenges.push(this);
                    flow.pending.remove(0);
                    flow.auth_id = Some(id);
                    Ok(json!({ "done": false, "sent": action_label(&next) }))
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
                let flow = self.login.take().unwrap();
                let stored = Stored {
                    device_id: flow.device_id,
                    auth_token: token,
                    sin,
                    identifier: flow.email.or(flow.phone).unwrap_or_default(),
                };
                self.session = Some((flow.backend, stored));
                self.session_changed();
                self.log("info", "ログインしました");
                Ok(json!({ "done": true }))
            }
            Err(mut f) => {
                self.note(&f);
                let flow = self.login.as_mut().unwrap();
                flow.failed_attempts += 1;
                if flow.failed_attempts >= MAX_OTP_ATTEMPTS {
                    self.login = None;
                    f.hint = Some("3回失敗したので手続きを中止しました。時間をおいて、最初からやり直してください。".into());
                } else {
                    f.hint = Some(format!(
                        "コードを確認してもう一度入力できます(あと{}回)。{}",
                        MAX_OTP_ATTEMPTS - flow.failed_attempts,
                        f.hint.clone().unwrap_or_default()
                    ));
                }
                Err(f)
            }
        }
    }

    /// この端末からセッションを消すだけ。povo 側には何も送らない。
    fn logout(&mut self) -> Value {
        self.session = None;
        self.login = None;
        self.st.snapshot = None;
        self.st.snapshot_ms = 0;
        self.st.catalog = None;
        self.st.catalog_ms = 0;
        if self.mock {
            self.st.mock_session = None;
        } else {
            self.session_event = Some(SessionEvent::Clear);
        }
        self.log("info", "ログアウトしました");
        json!({"ok": true})
    }

    // ---- 残量 ----------------------------------------------------------------------

    fn snapshot(&mut self, force: bool) -> R<Value> {
        let age = self.now() - self.st.snapshot_ms;
        let gap = if force { SNAPSHOT_FORCE_GAP_MS } else { SNAPSHOT_MIN_GAP_MS };
        if let Some(s) = &self.st.snapshot {
            if age < gap && self.session.is_some() {
                let mut s = s.clone();
                s["cached"] = json!(true);
                return Ok(s);
            }
        }
        self.fetch_snapshot()
    }

    fn fetch_snapshot(&mut self) -> R<Value> {
        let mut profile = Value::Null;
        // 回線番号(SIN)がまだ無いときだけ profile を呼ぶ(povo-android と同じく SIN はここで決まる)。
        if self.session.as_ref().is_some_and(|(_, s)| s.sin.is_none()) {
            profile = self.povo(|b| b.profile())?;
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
        let snap = derive_snapshot(self.now(), usage, toppings, toppings_error, profile);
        self.st.snapshot = Some(snap.clone());
        self.st.snapshot_ms = self.now();
        Ok(snap)
    }

    /// コード適用前の確認用に、十分新しい残量を用意する。
    fn recent_snapshot(&mut self, max_age: i64) -> R<Value> {
        match &self.st.snapshot {
            Some(s) if self.now() - self.st.snapshot_ms <= max_age => Ok(s.clone()),
            _ => self.fetch_snapshot(),
        }
    }

    fn history(&mut self) -> R<Value> {
        let raw = self.povo(|b| b.quilt("order-history"))?;
        parse::purchases(&raw).ok_or_else(|| local("購入履歴の形を読めませんでした。"))
    }

    // ---- カタログと購入 ------------------------------------------------------------

    fn catalog(&mut self, force: bool) -> R<Value> {
        if !force {
            if let Some(c) = &self.st.catalog {
                if self.now() - self.st.catalog_ms < CATALOG_MAX_AGE_MS {
                    return Ok(c.clone());
                }
            }
        }
        let raw = self.povo(|b| b.quilt("dashboard-v2"))?;
        let sections = parse::catalog(&raw)
            .ok_or_else(|| local("カタログの形を読めませんでした(povo 側の変更の可能性)。購入は行わないでください。"))?;
        let mut products = Vec::new();
        for sec in sections.as_array().into_iter().flatten() {
            let title = sec.get("title").cloned().unwrap_or(Value::Null);
            for p in sec.get("products").and_then(|v| v.as_array()).into_iter().flatten() {
                let mut p = p.clone();
                let yen = p.get("price").and_then(|v| v.as_str()).and_then(price_yen);
                p["price_yen"] = json!(yen);
                p["section"] = title.clone();
                products.push(p);
            }
        }
        let doc = json!({ "fetched_ms": self.now(), "sections": sections, "products": products });
        self.st.catalog = Some(doc.clone());
        self.st.catalog_ms = self.now();
        Ok(doc)
    }

    fn find_product(&self, sku: &str) -> Option<Value> {
        self.st
            .catalog
            .as_ref()?
            .get("products")?
            .as_array()?
            .iter()
            .find(|p| p.get("sku").and_then(|v| v.as_str()) == Some(sku))
            .cloned()
    }

    fn month_key(&self, ms: i64) -> (i64, u32) {
        let (y, m, _) = timeutil::jst_ymd(ms);
        (y, m)
    }

    fn budget(&self) -> Value {
        let now = self.now();
        let this_month = self.month_key(now);
        let today = timeutil::jst_ymd(now);
        let in_month = |e: &&LedgerEntry| self.month_key(e.time_ms) == this_month;
        let auto_month: u32 = self.st.ledger.iter().filter(|e| e.auto).filter(in_month).filter_map(|e| e.price_yen).sum();
        let all_month: u32 = self.st.ledger.iter().filter(in_month).filter_map(|e| e.price_yen).sum();
        let auto_today = self.st.ledger.iter().filter(|e| e.auto && timeutil::jst_ymd(e.time_ms) == today).count();
        let cap = self.st.settings.monthly_cap_yen;
        json!({
            "cap_yen": cap,
            "auto_spent_yen": auto_month,
            "all_spent_yen": all_month,
            "remaining_yen": cap.saturating_sub(auto_month),
            "auto_today": auto_today,
            "max_auto_per_day": self.st.settings.max_auto_orders_per_day,
        })
    }

    fn order(&mut self, req: &Value) -> R<Value> {
        let sku = arg_str(req, "sku").ok_or_else(|| local("商品IDがありません。"))?;
        if sku.len() > 200 {
            return Err(local("商品IDが不正です。"));
        }
        let auto = arg_bool(req, "auto");
        if !auto && arg_str(req, "confirm").as_deref() != Some(ORDER_CONFIRM) {
            return Err(local(format!("確認欄に「{ORDER_CONFIRM}」と入力してください。")));
        }
        self.gate()?;
        self.backend()?;
        let now = self.now();
        if self.st.ledger.iter().any(|e| e.sku == sku && now - e.time_ms < SAME_ORDER_COOLDOWN_MS) {
            return Err(local("同じ商品を続けて注文しようとしています。二重購入防止のため2分待ち、購入履歴を確認してください。"));
        }

        let mut product = self.find_product(&sku);
        if auto {
            // 自動購入は、新しいカタログに載っている商品だけ。
            if product.is_none() || now - self.st.catalog_ms >= CATALOG_MAX_AGE_MS {
                self.catalog(true)?;
                product = self.find_product(&sku);
            }
            let p = product.clone().ok_or_else(|| local(format!("自動購入: 商品 {sku} が購入できる一覧にありません。")))?;
            let name = p.get("name").and_then(|v| v.as_str()).unwrap_or(&sku).to_string();
            if p.get("requires_3ds").and_then(|v| v.as_bool()).unwrap_or(false) {
                let msg = format!("自動購入しません: {name} は3Dセキュアが必要です。アプリから手動で購入してください。");
                self.log("warn", &msg);
                return Err(local(msg));
            }
            let price = p.get("price_yen").and_then(|v| v.as_u64()).map(|v| v as u32).ok_or_else(|| {
                local(format!("自動購入しません: {name} の価格を読めませんでした。"))
            })?;
            let b = self.budget();
            let spent = b["auto_spent_yen"].as_u64().unwrap_or(0) as u32;
            let cap = self.st.settings.monthly_cap_yen;
            if spent + price > cap {
                let msg = format!("自動購入しません: 今月の上限 {cap}円を超えます(使用済み {spent}円 + {name} {price}円)。");
                self.log("warn", &msg);
                return Err(local(msg));
            }
            let today = b["auto_today"].as_u64().unwrap_or(0) as u32;
            if today >= self.st.settings.max_auto_orders_per_day {
                let msg = format!("自動購入しません: 今日はすでに{today}回自動購入しています(上限 {}回)。", self.st.settings.max_auto_orders_per_day);
                self.log("warn", &msg);
                return Err(local(msg));
            }
            let gap_ms = self.st.settings.auto_order_gap_min as i64 * 60_000;
            if let Some(last) = self.st.ledger.iter().filter(|e| e.auto).map(|e| e.time_ms).max() {
                if now - last < gap_ms {
                    let msg = format!("自動購入しません: 前回の自動購入から{}分経っていません。", self.st.settings.auto_order_gap_min);
                    self.log("warn", &msg);
                    return Err(local(msg));
                }
            }
            if self.st.settings.dry_run || arg_bool(req, "dry_run") {
                self.log("action", format!("(試運転){name} {price}円 を購入するところでした"));
                return Ok(json!({ "dry_run": true, "product": p, "needs_3ds": false }));
            }
        }

        let name = product.as_ref().and_then(|p| p.get("name")).and_then(|v| v.as_str()).map(String::from);
        let price = product.as_ref().and_then(|p| p.get("price_yen")).and_then(|v| v.as_u64()).map(|v| v as u32);
        // 送信前に記録・保存する。
        self.st.ledger.push(LedgerEntry {
            time_ms: now,
            sku: sku.clone(),
            name: name.clone(),
            price_yen: price,
            auto,
            status: "sent".into(),
            message: None,
            challenge_url: None,
        });
        let idx = self.st.ledger.len() - 1;
        self.save();
        let label = name.clone().unwrap_or_else(|| sku.clone());
        let who = if auto { "自動購入" } else { "購入" };
        let s = sku.clone();
        match self.povo(move |b| b.place_order(&s)) {
            Ok(raw) => {
                let parsed = parse::order(&raw).unwrap_or(Value::Null);
                let challenge = parsed.get("challenge_url").and_then(|v| v.as_str()).map(String::from);
                let e = &mut self.st.ledger[idx];
                if let Some(url) = &challenge {
                    e.status = "needs_3ds".into();
                    e.challenge_url = Some(url.clone());
                    self.log("warn", format!("{who}: {label} は3Dセキュアの認証待ちです(まだ課金されていません)"));
                } else {
                    e.status = "ok".into();
                    self.log("action", format!("{who}: {label}{} を注文しました", price.map(|p| format!(" {p}円")).unwrap_or_default()));
                }
                self.st.snapshot_ms = 0;
                Ok(json!({ "dry_run": false, "order": parsed, "needs_3ds": challenge.is_some(), "challenge_url": challenge, "product": product }))
            }
            Err(f) => {
                let e = &mut self.st.ledger[idx];
                e.status = "error".into();
                e.message = Some(f.message.clone());
                self.log("error", format!("{who}失敗: {label}: {}(課金された可能性があるので購入履歴を確認してください)", f.message));
                Err(f)
            }
        }
    }

    // ---- コード ---------------------------------------------------------------------

    fn codes_json(&self) -> Value {
        let list: Vec<Value> = self
            .st
            .codes
            .iter()
            .map(|c| {
                let mut v = json!(c);
                v["masked"] = json!(mask(&c.code));
                v
            })
            .collect();
        json!(list)
    }

    fn new_code_id(&self) -> String {
        use rand::RngCore;
        let mut b = [0u8; 6];
        rand::rngs::OsRng.fill_bytes(&mut b);
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    /// 1行に1コード。「コード タグ メモ…」(空白・カンマ・タブ区切り)。
    fn codes_add(&mut self, req: &Value) -> R<Value> {
        let text = req.get("text").and_then(|v| v.as_str()).unwrap_or("");
        let default_tag = arg_str(req, "tag").unwrap_or_default();
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
            let entry = CodeEntry {
                id: self.new_code_id(),
                code,
                tag,
                note,
                status: CodeStatus::Pending,
                added_ms: self.now(),
                sent_ms: None,
                result: None,
            };
            self.st.codes.push(entry);
            added += 1;
        }
        if added > 0 {
            self.log("info", format!("コードを{added}件追加しました"));
        }
        Ok(json!({ "added": added, "duplicates": duplicates, "invalid": invalid }))
    }

    fn code_edit(&mut self, req: &Value, what: &str) -> R<Value> {
        let id = arg_str(req, "id").ok_or_else(|| local("id がありません。"))?;
        let i = self.st.codes.iter().position(|c| c.id == id).ok_or_else(|| local("そのコードは見つかりません。"))?;
        match what {
            "remove" => {
                self.st.codes.remove(i);
            }
            "reset" => {
                // 利用者が明示的に「未使用に戻す」ときだけ。自動では決してしない。
                let c = &mut self.st.codes[i];
                c.status = CodeStatus::Pending;
                c.result = None;
            }
            _ => {
                let c = &mut self.st.codes[i];
                if let Some(t) = req.get("tag").and_then(|v| v.as_str()) {
                    c.tag = t.trim().to_string();
                }
                if let Some(n) = req.get("note").and_then(|v| v.as_str()) {
                    c.note = n.trim().to_string();
                }
            }
        }
        Ok(self.codes_json())
    }

    fn apply_code(&mut self, req: &Value) -> R<Value> {
        let auto = arg_bool(req, "auto");
        if !auto && arg_str(req, "confirm").as_deref() != Some(CODE_CONFIRM) {
            return Err(local(format!("確認欄に「{CODE_CONFIRM}」と入力してください。")));
        }
        if auto && !self.st.settings.auto_codes {
            return Err(local("設定でコードの自動適用が切られています。"));
        }
        self.gate()?;
        self.backend()?;

        // どのコードを使うか
        let idx = if let Some(raw) = arg_str(req, "code") {
            if auto {
                return Err(local("自動適用では、コード一覧に登録したものだけを使います。"));
            }
            let code = normalize_code(&raw).map_err(local)?;
            match self.st.codes.iter().position(|c| c.code == code) {
                Some(i) => i,
                None => {
                    let entry = CodeEntry {
                        id: self.new_code_id(),
                        code,
                        tag: "手入力".into(),
                        note: String::new(),
                        status: CodeStatus::Pending,
                        added_ms: self.now(),
                        sent_ms: None,
                        result: None,
                    };
                    self.st.codes.push(entry);
                    self.st.codes.len() - 1
                }
            }
        } else if let Some(id) = arg_str(req, "id") {
            self.st.codes.iter().position(|c| c.id == id).ok_or_else(|| local("そのコードは見つかりません。"))?
        } else {
            let tag = arg_str(req, "tag");
            self.st
                .codes
                .iter()
                .position(|c| {
                    c.status == CodeStatus::Pending
                        && tag.as_ref().map(|t| c.tag.eq_ignore_ascii_case(t)).unwrap_or(true)
                })
                .ok_or_else(|| {
                    local(match &tag {
                        Some(t) => format!("タグ「{t}」の未使用コードがありません。"),
                        None => "未使用のコードがありません。".into(),
                    })
                })?
        };
        if self.st.codes[idx].status != CodeStatus::Pending {
            return Err(local(
                "このコードはすでに送っています。結果は契約中のトッピングで確認してください(送り直すには、コード一覧で「未使用に戻す」を押してください)。",
            ));
        }
        if let Some(t) = self.st.last_code_sent_ms {
            let left = CODE_COOLDOWN_MS - (self.now() - t);
            if left > 0 {
                return Err(local(format!("コードの送信は15秒に1回までです。あと{}秒待ってください。", left / 1000 + 1)));
            }
        }

        // データ使い放題の有効期間中は送らない(公式アプリの注意書き)。
        let snap = self.recent_snapshot(UNLIMITED_CHECK_MAX_AGE_MS)?;
        match snap.get("unlimited_active").and_then(|v| v.as_bool()) {
            Some(true) => {
                let msg = "データ使い放題の有効期間中なので、コードを送りません(公式アプリの注意書きと同じ)。";
                if auto {
                    self.log("warn", msg);
                }
                return Err(local(msg));
            }
            Some(false) => {}
            None if auto => {
                let msg = "契約中のトッピングを読めず、使い放題中か確かめられないので、自動ではコードを送りません。";
                self.log("warn", msg);
                return Err(local(msg));
            }
            None => {}
        }

        let masked = mask(&self.st.codes[idx].code);
        let tag = self.st.codes[idx].tag.clone();
        if auto && (self.st.settings.dry_run || arg_bool(req, "dry_run")) {
            self.log("action", format!("(試運転)コード {masked}({tag})を適用するところでした"));
            return Ok(json!({ "dry_run": true, "id": self.st.codes[idx].id, "masked": masked, "tag": tag }));
        }

        // 送信前に記録・保存する。
        let now = self.now();
        {
            let c = &mut self.st.codes[idx];
            c.status = CodeStatus::Sent;
            c.sent_ms = Some(now);
        }
        self.st.last_code_sent_ms = Some(now);
        self.save();
        let code = self.st.codes[idx].code.clone();
        let who = if auto { "自動適用" } else { "コード適用" };
        let r = self.povo(move |b| b.apply_code(&code));
        let id = self.st.codes[idx].id.clone();
        match r {
            Ok(raw) => match parse::code_result(&raw) {
                Some(v) => {
                    let valid = v["valid"].as_bool().unwrap_or(false);
                    let text = [v["title"].as_str(), v["subtitle"].as_str(), v["message"].as_str()]
                        .into_iter()
                        .flatten()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(" / ");
                    let c = &mut self.st.codes[idx];
                    c.status = if valid { CodeStatus::Applied } else { CodeStatus::Rejected };
                    c.result = Some(text.clone());
                    self.st.snapshot_ms = 0;
                    if valid {
                        self.log("action", format!("{who}: {masked}({tag})を適用しました: {text}"));
                    } else {
                        self.log("warn", format!("{who}: {masked}({tag})は受け付けられませんでした: {text}"));
                    }
                    Ok(json!({ "dry_run": false, "id": id, "masked": masked, "tag": tag, "valid": valid, "result": v }))
                }
                None => {
                    let msg = "応答の形を読めませんでした。適用されたかどうかは、契約中のトッピングで確認してください。";
                    let c = &mut self.st.codes[idx];
                    c.status = CodeStatus::Error;
                    c.result = Some(msg.into());
                    self.log("error", format!("{who}: {masked}: {msg}"));
                    Err(local(msg))
                }
            },
            Err(f) => {
                let c = &mut self.st.codes[idx];
                c.status = CodeStatus::Error;
                c.result = Some(f.message.clone());
                self.log("error", format!("{who}失敗: {masked}: {}", f.message));
                Err(f)
            }
        }
    }

    // ---- 設定 -------------------------------------------------------------------------

    fn settings_set(&mut self, req: &Value) -> R<Value> {
        let s = &mut self.st.settings;
        let before = s.clone();
        if let Some(v) = req.get("dry_run").and_then(|v| v.as_bool()) {
            s.dry_run = v;
        }
        if let Some(v) = req.get("monthly_cap_yen").and_then(|v| v.as_u64()) {
            s.monthly_cap_yen = v.min(100_000) as u32;
        }
        if let Some(v) = req.get("max_auto_orders_per_day").and_then(|v| v.as_u64()) {
            s.max_auto_orders_per_day = v.min(20) as u32;
        }
        if let Some(v) = req.get("auto_order_gap_min").and_then(|v| v.as_u64()) {
            s.auto_order_gap_min = v.min(24 * 60) as u32;
        }
        if let Some(v) = req.get("auto_codes").and_then(|v| v.as_bool()) {
            s.auto_codes = v;
        }
        let after = s.clone();
        if before.dry_run != after.dry_run {
            self.log("info", if after.dry_run { "試運転モードにしました" } else { "試運転モードを切りました(自動の購入・コード適用が実際に行われます)" });
        }
        Ok(json!(after))
    }
}

/// 残量とトッピングから、スクリプトが使いやすい形を作る。
fn derive_snapshot(now: i64, usage: Option<Value>, toppings: Option<Value>, toppings_error: Option<String>, profile: Value) -> Value {
    let left_kb: Option<f64> = usage.as_ref().and_then(|u| u.get("buckets")).and_then(|b| b.as_array()).map(|bs| {
        bs.iter().filter_map(|b| b.get("left_kb").and_then(|v| v.as_f64())).sum()
    });
    // 契約中のトッピングに「使い放題」があれば有効期間中とみなす(「かけ放題」は通話なので別)。
    let unlimited = toppings.as_ref().and_then(|t| t.as_array()).map(|list| {
        list.iter()
            .find(|t| t.get("name").and_then(|v| v.as_str()).is_some_and(|n| n.contains("使い放題")))
            .cloned()
    });
    json!({
        "fetched_ms": now,
        "usage": usage,
        "toppings": toppings,
        "toppings_error": toppings_error,
        "left_kb": left_kb,
        "unlimited_active": unlimited.as_ref().map(|u| u.is_some()),
        "unlimited": unlimited.flatten(),
        "profile": profile,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine() -> (Engine, PathBuf) {
        let dir = std::env::temp_dir().join(format!("povo-auto-test-{}", rand::random::<u64>()));
        let e = Engine::open(dir.to_str().unwrap(), true, None);
        (e, dir)
    }

    fn login(e: &mut Engine) {
        e.handle("login_start", &json!({"email": "a@example.com"})).unwrap();
        let r = e.handle("login_otp", &json!({"code": "000000"})).unwrap();
        assert_eq!(r["done"], true);
    }

    #[test]
    fn prices() {
        assert_eq!(price_yen("390円"), Some(390));
        assert_eq!(price_yen("2,700円"), Some(2700));
        assert_eq!(price_yen("¥330"), Some(330));
        assert_eq!(price_yen("330円(税込)"), Some(330));
        assert_eq!(price_yen("1,000"), Some(1000));
        assert_eq!(price_yen("無料"), Some(0));
        assert_eq!(price_yen("価格未定"), None);
        assert_eq!(price_yen(""), None);
    }

    #[test]
    fn masking() {
        assert_eq!(mask("ABCDEFGH"), "AB••••GH");
        assert_eq!(mask("ABC"), "•••");
    }

    #[test]
    fn login_and_snapshot() {
        let (mut e, _) = engine();
        assert!(e.handle("snapshot", &json!({})).is_err());
        login(&mut e);
        let s = e.handle("snapshot", &json!({})).unwrap();
        assert!(s["left_kb"].as_f64().unwrap() > 0.0);
        assert_eq!(s["unlimited_active"], false);
        // 30秒以内は前回の結果
        let s2 = e.handle("snapshot", &json!({})).unwrap();
        assert_eq!(s2["cached"], true);
    }

    #[test]
    fn session_persists_in_mock_state() {
        let (mut e, dir) = engine();
        login(&mut e);
        let e2 = Engine::open(dir.to_str().unwrap(), true, None);
        assert!(e2.session.is_some());
    }

    #[test]
    fn auto_order_respects_dry_run_budget_and_3ds() {
        let (mut e, _) = engine();
        login(&mut e);
        e.clock = Some(1_790_000_000_000);
        // 既定は試運転
        let r = e.handle("order", &json!({"sku": "MOCK_UNLIMITED_1H", "auto": true})).unwrap();
        assert_eq!(r["dry_run"], true);
        assert!(e.st.ledger.is_empty());

        e.handle("settings_set", &json!({"dry_run": false, "monthly_cap_yen": 400, "max_auto_orders_per_day": 5, "auto_order_gap_min": 0})).unwrap();
        // 3DS が要る商品は自動では買わない
        assert!(e.handle("order", &json!({"sku": "MOCK_DATA_20GB_30D", "auto": true})).is_err());
        // 一覧に無い商品
        assert!(e.handle("order", &json!({"sku": "NOPE", "auto": true})).is_err());
        // 330円は通る
        let r = e.handle("order", &json!({"sku": "MOCK_UNLIMITED_24H", "auto": true})).unwrap();
        assert_eq!(r["dry_run"], false);
        assert_eq!(e.st.ledger.last().unwrap().status, "ok");
        // 同じ商品はすぐには不可
        assert!(e.handle("order", &json!({"sku": "MOCK_UNLIMITED_24H", "auto": true})).is_err());
        // 110円は上限400を超える(330+110)
        e.clock = Some(1_790_000_000_000 + 200_000);
        let err = e.handle("order", &json!({"sku": "MOCK_UNLIMITED_1H", "auto": true})).unwrap_err();
        assert!(err.message.contains("上限"));
        assert_eq!(e.budget()["auto_spent_yen"], 330);
    }

    #[test]
    fn auto_order_daily_limit_and_gap() {
        let (mut e, _) = engine();
        login(&mut e);
        let t0 = 1_790_000_000_000;
        e.clock = Some(t0);
        e.handle("settings_set", &json!({"dry_run": false, "monthly_cap_yen": 5000, "max_auto_orders_per_day": 1, "auto_order_gap_min": 30})).unwrap();
        e.handle("order", &json!({"sku": "MOCK_UNLIMITED_1H", "auto": true})).unwrap();
        e.clock = Some(t0 + 10 * 60_000);
        assert!(e.handle("order", &json!({"sku": "MOCK_DATA_1GB_7D", "auto": true})).unwrap_err().message.contains("今日"));
        e.handle("settings_set", &json!({"max_auto_orders_per_day": 5})).unwrap();
        assert!(e.handle("order", &json!({"sku": "MOCK_DATA_1GB_7D", "auto": true})).unwrap_err().message.contains("分経って"));
    }

    #[test]
    fn manual_order_needs_confirm() {
        let (mut e, _) = engine();
        login(&mut e);
        assert!(e.handle("order", &json!({"sku": "MOCK_DATA_1GB_7D"})).is_err());
        let r = e.handle("order", &json!({"sku": "MOCK_DATA_20GB_30D", "confirm": "購入する"})).unwrap();
        assert_eq!(r["needs_3ds"], true);
        assert_eq!(e.st.ledger.last().unwrap().status, "needs_3ds");
    }

    #[test]
    fn forbidden_halts_everything() {
        let (mut e, dir) = engine();
        login(&mut e);
        let err = e.handle("order", &json!({"sku": "MOCK_FORBIDDEN", "confirm": "購入する"})).unwrap_err();
        assert!(err.halt);
        assert!(e.handle("snapshot", &json!({"force": true})).unwrap_err().halt);
        // 停止は保存され、次の起動(バックグラウンド)でも続く
        let mut e2 = Engine::open(dir.to_str().unwrap(), true, None);
        assert!(e2.handle("snapshot", &json!({"force": true})).unwrap_err().halt);
        e2.handle("unhalt", &json!({})).unwrap();
        assert!(e2.handle("snapshot", &json!({"force": true})).is_ok());
    }

    #[test]
    fn codes_flow() {
        let (mut e, _) = engine();
        login(&mut e);
        let r = e.handle("codes_add", &json!({"text": "mockok 1gb 7日\nMOCKUSED,unl\nbad!code\n# comment\nMOCKOK"})).unwrap();
        assert_eq!(r["added"], 2);
        assert_eq!(r["duplicates"].as_array().unwrap().len(), 1);
        assert_eq!(r["invalid"].as_array().unwrap().len(), 1);
        e.clock = Some(1_790_000_000_000);
        // 既定は試運転なので送らない
        let d = e.handle("apply_code", &json!({"auto": true})).unwrap();
        assert_eq!(d["dry_run"], true);
        assert_eq!(e.st.codes[0].status, CodeStatus::Pending);
        e.handle("settings_set", &json!({"dry_run": false})).unwrap();
        let ok = e.handle("apply_code", &json!({"auto": true, "tag": "1GB"})).unwrap();
        assert_eq!(ok["valid"], true);
        assert_eq!(e.st.codes[0].status, CodeStatus::Applied);
        // 15秒は空ける
        assert!(e.handle("apply_code", &json!({"auto": true})).unwrap_err().message.contains("15秒"));
        e.clock = Some(1_790_000_000_000 + 16_000);
        let used = e.handle("apply_code", &json!({"auto": true})).unwrap();
        assert_eq!(used["valid"], false);
        assert_eq!(e.st.codes[1].status, CodeStatus::Rejected);
        // 未使用はもう無い
        e.clock = Some(1_790_000_000_000 + 40_000);
        assert!(e.handle("apply_code", &json!({"auto": true})).is_err());
        // 手入力は確認語が要る
        assert!(e.handle("apply_code", &json!({"code": "MOCKOK"})).is_err());
        // 送ったコードは手入力でも送り直さない
        assert!(e.handle("apply_code", &json!({"code": "mockok", "confirm": "利用する"})).unwrap_err().message.contains("すでに"));
    }

    #[test]
    fn unlimited_blocks_codes() {
        let snap = derive_snapshot(
            0,
            parse::usage(crate::mock::USAGE),
            Some(json!([{"section": "データ", "name": "データ使い放題(24時間)", "remaining": null, "expiry": "x"}])),
            None,
            Value::Null,
        );
        assert_eq!(snap["unlimited_active"], true);
        let kake = derive_snapshot(0, None, Some(json!([{"name": "5分以内通話かけ放題"}])), None, Value::Null);
        assert_eq!(kake["unlimited_active"], false);
        let unknown = derive_snapshot(0, None, None, Some("x".into()), Value::Null);
        assert!(unknown["unlimited_active"].is_null());

        let (mut e, _) = engine();
        login(&mut e);
        e.handle("settings_set", &json!({"dry_run": false})).unwrap();
        e.handle("codes_add", &json!({"text": "MOCKOK"})).unwrap();
        e.handle("snapshot", &json!({})).unwrap();
        let now = e.now();
        e.st.snapshot = Some(snap);
        e.st.snapshot_ms = now;
        assert!(e.handle("apply_code", &json!({"auto": true})).unwrap_err().message.contains("使い放題"));
        assert_eq!(e.st.codes[0].status, CodeStatus::Pending);
    }

    #[test]
    fn rate_limit() {
        let (mut e, _) = engine();
        login(&mut e);
        let mut t = 1_790_000_000_000;
        let mut failed = false;
        for _ in 0..30 {
            t += 6_000;
            e.clock = Some(t);
            if e.handle("snapshot", &json!({"force": true})).is_err() {
                failed = true;
                break;
            }
        }
        assert!(failed, "5分20回の上限で止まるはず");
    }
}
