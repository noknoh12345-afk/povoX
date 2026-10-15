//! povoX の中身(Rust)。iOS アプリには UniFFI で型付きの API(`PovoEngine`)として見える。
//!
//! 役割分担:
//! - povo への通信・安全装置・保存・ルールの計画の実行 … ここ(Rust)
//! - 画面・通知・バックグラウンド更新・ルールの JavaScript の評価・キーチェーン … アプリ(Swift)
//!
//! ルールは「何をするか」の計画を返すだけで、povo へ送れるのはこのエンジンだけ。

uniffi::setup_scaffolding!();

mod backend;
mod catalog;
mod engine;
mod error;
mod history;
mod jptime;
mod mock;
mod model;
mod parse;
mod plan;
mod protocol;
mod rulectx;
mod script;
mod state;
mod store;

use std::sync::{Arc, Mutex, MutexGuard};

pub use engine::Engine;
pub use error::PovoXError;
pub use model::*;
pub use store::{MemoryStore, SessionStore};

/// アプリから使うエンジン。中の Mutex で povo への通信を常に1本ずつにする
/// (画面・ルール・バックグラウンド・ショートカット・通知が同時に呼んでも直列になる)。
#[derive(uniffi::Object)]
pub struct PovoEngine {
    inner: Mutex<Engine>,
}

impl PovoEngine {
    fn lock(&self) -> MutexGuard<'_, Engine> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 状態を変える操作。終わったら保存する。
    fn write<T>(&self, f: impl FnOnce(&mut Engine) -> T) -> T {
        let mut e = self.lock();
        let r = f(&mut e);
        e.save();
        r
    }

    /// 開発・テスト用: JSON で全部の操作を呼ぶ。
    pub fn dev_call(&self, op: &str, args: &serde_json::Value) -> String {
        script::dev_call(&mut self.lock(), op, args)
    }
}

#[uniffi::export]
impl PovoEngine {
    #[uniffi::constructor]
    pub fn new(config: EngineConfig, store: Box<dyn SessionStore>) -> Arc<Self> {
        Arc::new(PovoEngine { inner: Mutex::new(Engine::open(&config, store)) })
    }

    pub fn status(&self) -> EngineStatus {
        self.lock().status()
    }

    // ---- ログイン
    pub fn login_start(&self, email: Option<String>, phone: Option<String>) -> Result<LoginStep, PovoXError> {
        self.write(|e| e.login_start(email, phone)).map_err(Into::into)
    }
    pub fn login_resend(&self) -> Result<LoginStep, PovoXError> {
        self.write(|e| e.login_resend()).map_err(Into::into)
    }
    pub fn login_otp(&self, code: String) -> Result<LoginStep, PovoXError> {
        self.write(|e| e.login_otp(&code)).map_err(Into::into)
    }
    pub fn login_cancel(&self) {
        self.write(|e| e.login_cancel())
    }
    pub fn logout(&self) {
        self.write(|e| e.logout())
    }
    pub fn unhalt(&self) {
        self.write(|e| e.unhalt())
    }

    // ---- 残量
    pub fn snapshot(&self, force: bool) -> Result<Snapshot, PovoXError> {
        self.write(|e| e.snapshot(force)).map_err(Into::into)
    }
    pub fn cached_snapshot(&self) -> Option<Snapshot> {
        self.lock().cached_snapshot()
    }
    pub fn history(&self, hours: u32) -> Vec<UsageSample> {
        self.lock().history(hours)
    }
    pub fn insights(&self) -> UsageInsights {
        self.lock().insights()
    }
    pub fn next_check_delay_min(&self) -> u32 {
        self.lock().next_check_delay_min()
    }

    // ---- トッピング
    pub fn catalog(&self, force: bool) -> Result<Catalog, PovoXError> {
        self.write(|e| e.catalog(force)).map_err(Into::into)
    }
    pub fn cached_catalog(&self) -> Option<Catalog> {
        self.lock().cached_catalog()
    }
    pub fn purchase_history(&self) -> Result<Vec<Purchase>, PovoXError> {
        self.write(|e| e.purchase_history()).map_err(Into::into)
    }
    pub fn order(&self, sku: String, confirm: String) -> Result<OrderResult, PovoXError> {
        self.write(|e| e.order_manual(&sku, &confirm)).map_err(Into::into)
    }

    // ---- コード
    pub fn codes(&self) -> Vec<CodeEntry> {
        self.lock().codes()
    }
    pub fn add_codes(&self, text: String, default_tag: Option<String>) -> AddCodesResult {
        self.write(|e| e.add_codes(&text, default_tag))
    }
    pub fn remove_code(&self, id: String) -> Result<(), PovoXError> {
        self.write(|e| e.remove_code(&id)).map_err(Into::into)
    }
    pub fn reset_code(&self, id: String) -> Result<(), PovoXError> {
        self.write(|e| e.reset_code(&id)).map_err(Into::into)
    }
    pub fn update_code(&self, id: String, tag: String, note: String) -> Result<(), PovoXError> {
        self.write(|e| e.update_code(&id, &tag, &note)).map_err(Into::into)
    }
    pub fn apply_code(&self, id: Option<String>, raw: Option<String>, confirm: String) -> Result<CodeResult, PovoXError> {
        self.write(|e| e.apply_code_manual(id, raw, &confirm)).map_err(Into::into)
    }

    // ---- 設定・記録
    pub fn settings(&self) -> Settings {
        self.lock().settings()
    }
    pub fn update_settings(&self, settings: Settings) -> Settings {
        self.write(|e| e.update_settings(settings))
    }
    pub fn budget(&self) -> Budget {
        self.lock().budget()
    }
    pub fn ledger(&self, limit: u32) -> Vec<LedgerEntry> {
        self.lock().ledger(limit)
    }
    pub fn logs(&self, limit: u32) -> Vec<LogEntry> {
        self.lock().logs(limit)
    }
    pub fn log(&self, level: LogLevel, message: String) {
        let msg: String = message.chars().take(500).collect();
        self.write(|e| e.log(level, msg))
    }
    pub fn clear_logs(&self) {
        self.write(|e| e.clear_logs())
    }

    // ---- 自動化
    /// ルールに渡す材料(JSON)。本番・試運転では残量を取得する。
    pub fn rule_context_json(&self, mode: RunMode, sim: Option<SimInput>) -> Result<String, PovoXError> {
        self.write(|e| e.rule_context(mode, sim)).map(|v| v.to_string()).map_err(Into::into)
    }
    /// ルールの JavaScript からの呼び出し(読み取りとログだけ)。応答は JSON。
    pub fn script_call(&self, op: String, args_json: String) -> String {
        self.write(|e| script::script_call(e, &op, &args_json))
    }
    /// ルールの計画を実行して記録を返す。
    pub fn execute_run(&self, input: RunInput) -> RunRecord {
        self.write(|e| e.execute_run(input))
    }
    pub fn runs(&self, limit: u32) -> Vec<RunRecord> {
        self.lock().runs(limit)
    }
    pub fn pending_actions(&self) -> Vec<PendingAction> {
        self.write(|e| e.pending_actions())
    }
    pub fn confirm_pending(&self, id: String) -> Result<ActionOutcome, PovoXError> {
        self.write(|e| e.confirm_pending(&id)).map_err(Into::into)
    }
    pub fn dismiss_pending(&self, id: String) {
        self.write(|e| e.dismiss_pending(&id))
    }
}

#[cfg(test)]
mod tests;
