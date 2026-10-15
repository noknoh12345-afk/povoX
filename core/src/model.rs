//! アプリとやり取りする型。UniFFI で Swift の型になり(フィールドは camelCase になる)、
//! serde で JSON にもなる(ルールの JavaScript と開発用 CLI 向け、snake_case のまま)。

use serde::{Deserialize, Serialize};

// ---- セッション・設定 ------------------------------------------------------------

/// 端末ID・トークン・回線番号。端末IDとトークンは必ず組で保存する(食い違うと 403001)。
#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct StoredSession {
    pub device_id: String,
    pub auth_token: String,
    pub sin: Option<String>,
    /// 画面表示用。ログインに使ったメールまたは電話番号。
    pub identifier: String,
}

/// エンジンの作り方。
#[derive(uniffi::Record, Clone, Debug)]
pub struct EngineConfig {
    /// 状態ファイルを置くフォルダ(アプリの Application Support など)。
    pub dir: String,
    /// true なら povo へ一切通信しない(作り物のデータ)。
    pub mock: bool,
    /// モックの筋書き: "" / "low"(残りわずかから始める)。
    pub mock_scenario: String,
}

/// 自動の購入・コード適用をどう扱うか。
#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ActionMode {
    /// しない(ルールが望んでも断る)。
    Off,
    /// 通知で確認し、利用者が「実行」を押したときだけ行う。
    Confirm,
    /// 安全装置の範囲で自動で行う。
    Auto,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Settings {
    pub purchase_mode: ActionMode,
    pub code_mode: ActionMode,
    /// 試運転: ルールの判断を記録するだけで、確認も実行もしない。
    pub dry_run: bool,
    /// ルールによる購入(自動・確認後)の月の上限(円、日本時間の暦月)。手動購入は数えない。
    pub monthly_cap_yen: u32,
    /// ルールによる購入の1日の上限回数(日本時間)。
    pub max_rule_orders_per_day: u32,
    /// ルールによる購入どうしの最小間隔(分)。
    pub order_gap_min: u32,
    /// 確認待ちの有効時間(分)。過ぎたら実行できない。
    pub confirm_ttl_min: u32,
    /// 自動チェックの間隔の下限・上限(分)。間には残量の減り方で自動調整する。
    pub check_min_interval_min: u32,
    pub check_max_interval_min: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            purchase_mode: ActionMode::Confirm,
            code_mode: ActionMode::Confirm,
            dry_run: false,
            monthly_cap_yen: 1000,
            max_rule_orders_per_day: 2,
            order_gap_min: 30,
            confirm_ttl_min: 30,
            check_min_interval_min: 15,
            check_max_interval_min: 120,
        }
    }
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Budget {
    pub cap_yen: u32,
    /// 今月のルールによる購入(送信したもの。結果不明・失敗も、課金の可能性があるので数える)。
    pub rule_spent_yen: u32,
    /// 今月の購入の合計(手動を含む)。
    pub all_spent_yen: u32,
    pub remaining_yen: u32,
    pub rule_orders_today: u32,
    pub max_per_day: u32,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LoginState {
    pub identifier: Option<String>,
    /// 今入力を求めているもの(例: 「メールに届いたコード」)。
    pub current: Option<String>,
    pub remaining: u32,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LoginStep {
    pub done: bool,
    pub sent: Option<String>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct EngineStatus {
    pub mock: bool,
    pub logged_in: bool,
    pub identifier: Option<String>,
    pub halted: Option<String>,
    pub blocked_until_ms: Option<i64>,
    pub login: Option<LoginState>,
    pub otp_cooldown_s: Option<u32>,
    pub settings: Settings,
    pub budget: Budget,
    pub codes_pending: u32,
    pub pending_actions: u32,
    pub snapshot_ms: Option<i64>,
}

// ---- 残量 ------------------------------------------------------------------------

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Bucket {
    pub key: String,
    pub label: String,
    pub used_kb: f64,
    pub left_kb: f64,
    pub plan_kb: Option<f64>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Topping {
    pub section: Option<String>,
    pub name: String,
    pub remaining: Option<String>,
    pub expiry: Option<String>,
    /// expiry を読めたときのエポックミリ秒(日本時間として解釈)。
    pub expiry_ms: Option<i64>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Unlimited {
    /// 使い放題の有効期間中か。トッピングを読めなければ None(分からない)。
    pub active: Option<bool>,
    pub name: Option<String>,
    pub until_ms: Option<i64>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub fetched_ms: i64,
    /// 全バケットの残りの合計(KB、1024基準)。読めなければ None。
    pub left_kb: Option<f64>,
    pub plan_kb: Option<f64>,
    pub buckets: Vec<Bucket>,
    pub calls_used_sec: Option<f64>,
    pub sms_used: Option<f64>,
    pub toppings: Option<Vec<Topping>>,
    pub toppings_error: Option<String>,
    pub unlimited: Unlimited,
    /// 前回の値を返したとき true。
    pub cached: bool,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct UsageSample {
    pub t_ms: i64,
    pub left_kb: f64,
    pub unlimited: bool,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct UsageInsights {
    /// 最近の減り方(KB/時)。減っていなければ 0、データが足りなければ None。
    pub kb_per_hour: Option<f64>,
    /// このペースで 0 になるまでの時間。減っていない・使い放題中なら None。
    pub hours_left: Option<f64>,
    pub used_today_kb: f64,
    pub used_7d_kb: f64,
    /// 減り方の計算に使った期間(時間)。
    pub window_hours: f64,
}

// ---- トッピング・購入 -------------------------------------------------------------

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Product {
    pub sku: String,
    pub name: String,
    pub section: Option<String>,
    pub validity: Option<String>,
    pub price_text: Option<String>,
    pub price_yen: Option<u32>,
    pub requires_3ds: bool,
    /// 名前から読んだデータ量(GB)。使い放題なら None。
    pub data_gb: Option<f64>,
    /// 有効期間(時間)。
    pub hours: Option<f64>,
    pub unlimited: bool,
    pub yen_per_gb: Option<f64>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Catalog {
    pub fetched_ms: i64,
    pub products: Vec<Product>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct PurchaseItem {
    pub name: Option<String>,
    pub price: Option<String>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Purchase {
    pub order_id: Option<String>,
    pub status: Option<String>,
    pub date: Option<String>,
    pub date_iso: Option<String>,
    pub items: Vec<PurchaseItem>,
}

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum OrderSource {
    Rule,
    Manual,
}

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LedgerStatus {
    /// 送信したが結果を受け取れていない。
    Sent,
    Ok,
    Needs3ds,
    Error,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LedgerEntry {
    pub time_ms: i64,
    pub sku: String,
    pub name: Option<String>,
    pub price_yen: Option<u32>,
    pub source: OrderSource,
    pub status: LedgerStatus,
    pub message: Option<String>,
    pub challenge_url: Option<String>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct OrderResult {
    pub needs_3ds: bool,
    pub challenge_url: Option<String>,
    pub order_ref: Option<String>,
}

// ---- コード ----------------------------------------------------------------------

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CodeStatus {
    Pending,
    /// 送信を始めたが結果を受け取れなかった。自動では送らない。
    Sent,
    Applied,
    Rejected,
    Error,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct CodeEntry {
    pub id: String,
    pub code: String,
    #[serde(default)]
    pub masked: String,
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

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct AddCodesResult {
    pub added: u32,
    pub duplicates: Vec<String>,
    pub invalid: Vec<String>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct CodeResult {
    pub masked: String,
    pub tag: String,
    pub valid: bool,
    pub title: Option<String>,
    pub message: Option<String>,
}

// ---- ログ ------------------------------------------------------------------------

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Info,
    Action,
    Warn,
    Error,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LogEntry {
    pub time_ms: i64,
    pub level: LogLevel,
    pub message: String,
}

// ---- 自動化(ルールの実行) -------------------------------------------------------

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RunMode {
    /// 本番: 設定(確認/自動/試運転)に従う。
    Live,
    /// 試運転: 本物の残量で判断し、記録だけする。
    Dry,
    /// シミュレーション: 仮の状態で判断する。povo に通信せず、記録も残さない。
    Simulate,
}

/// シミュレーションで使う仮の状態。
#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct SimInput {
    pub left_kb: f64,
    pub unlimited: bool,
    /// 使い放題の残り時間(時間)。
    pub unlimited_hours_left: Option<f64>,
    /// 0 になるまでの予測(時間)。None なら「減っていない」。
    pub hours_left: Option<f64>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RunInput {
    pub trigger: String,
    pub mode: RunMode,
    pub battery_level: Option<u32>,
    pub charging: bool,
    pub network: String,
    /// ルールが返した計画(JSON)。ルールが失敗したときは None。
    pub plan_json: Option<String>,
    /// ルールを評価できなかった理由(ルールのエラー・残量を取得できなかった等)。
    pub error: Option<String>,
    pub script_logs: Vec<String>,
    pub sim: Option<SimInput>,
}

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Skip,
    Notify,
    ApplyCode,
    Buy,
}

#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OutcomeStatus {
    /// 実行した。
    Done,
    /// 通知で確認待ち。
    Queued,
    /// 試運転なので記録だけ。
    DryRun,
    /// シミュレーション: 実行されるはず。
    Simulated,
    /// 安全装置・条件で断った(送っていない)。
    Refused,
    /// 送ったが失敗した(処理された可能性あり)。
    Failed,
    /// ルールが「何もしない」を選んだ。
    Skipped,
    /// 通知を出す。
    Notified,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ActionOutcome {
    pub kind: ActionKind,
    pub status: OutcomeStatus,
    /// 何をしたか(例: 「データ使い放題(1時間) 110円」)。
    pub label: String,
    /// 結果の説明。
    pub message: String,
    pub title: Option<String>,
    pub body: Option<String>,
    pub pending_id: Option<String>,
    pub challenge_url: Option<String>,
    pub price_yen: Option<u32>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RunRecord {
    pub id: String,
    pub trigger: String,
    pub mode: RunMode,
    pub started_ms: i64,
    pub finished_ms: i64,
    pub left_kb: Option<f64>,
    pub unlimited: Option<bool>,
    pub battery_level: Option<u32>,
    pub charging: bool,
    pub network: String,
    /// 一行の要約。
    pub summary: String,
    pub outcomes: Vec<ActionOutcome>,
    pub error: Option<String>,
    pub logs: Vec<String>,
}

#[derive(uniffi::Record, Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct PendingAction {
    pub id: String,
    pub kind: ActionKind,
    pub label: String,
    pub detail: String,
    pub sku: Option<String>,
    pub code_id: Option<String>,
    pub price_yen: Option<u32>,
    pub created_ms: i64,
    pub expires_ms: i64,
    pub run_id: String,
}
