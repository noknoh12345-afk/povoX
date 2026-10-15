//! 保存する状態(1つの JSON ファイル)。読み込みは項目ごとに行い、形が合わない項目だけを
//! 既定値に戻す(アプリの更新で形が変わっても、手持ちのコードなど他の項目は失わない)。

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::*;

pub const STATE_VERSION: u32 = 2;
const LOG_MAX: usize = 300;
const LEDGER_MAX: usize = 500;
const RUNS_MAX: usize = 200;

#[derive(Default, Serialize, Deserialize)]
pub struct PersistState {
    pub version: u32,
    pub settings: Settings,
    pub halted: Option<String>,
    pub blocked_until_ms: Option<i64>,
    pub codes: Vec<CodeEntry>,
    pub ledger: Vec<LedgerEntry>,
    pub last_code_sent_ms: Option<i64>,
    pub last_otp_sent_ms: Option<i64>,
    pub snapshot: Option<Snapshot>,
    pub catalog: Option<Catalog>,
    pub history: Vec<UsageSample>,
    pub runs: Vec<RunRecord>,
    pub pending: Vec<PendingAction>,
    pub log: Vec<LogEntry>,
    /// モックのときだけ、セッションもここに置く(本番はアプリのキーチェーン)。
    pub mock_session: Option<StoredSession>,
}

fn field<T: serde::de::DeserializeOwned + Default>(obj: &serde_json::Map<String, Value>, key: &str, dropped: &mut Vec<String>) -> T {
    match obj.get(key) {
        None | Some(Value::Null) => T::default(),
        Some(v) => match serde_json::from_value(v.clone()) {
            Ok(x) => x,
            Err(_) => {
                dropped.push(key.to_string());
                T::default()
            }
        },
    }
}

/// 配列は要素ごとに読み、読めない要素だけ捨てる。
fn list<T: serde::de::DeserializeOwned>(obj: &serde_json::Map<String, Value>, key: &str, dropped: &mut Vec<String>) -> Vec<T> {
    let Some(Value::Array(items)) = obj.get(key) else { return vec![] };
    let mut out = Vec::with_capacity(items.len());
    let mut bad = 0;
    for it in items {
        match serde_json::from_value(it.clone()) {
            Ok(x) => out.push(x),
            Err(_) => bad += 1,
        }
    }
    if bad > 0 {
        dropped.push(format!("{key}({bad}件)"));
    }
    out
}

impl PersistState {
    /// 読み込む。読めなかった項目名も返す(ログに残すため)。
    pub fn load(path: &Path) -> (PersistState, Vec<String>) {
        let Ok(bytes) = std::fs::read(path) else { return (PersistState { version: STATE_VERSION, ..Default::default() }, vec![]) };
        let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(&bytes) else {
            // 壊れたファイルは消さずに残しておく
            let _ = std::fs::copy(path, path.with_extension("broken.json"));
            return (PersistState { version: STATE_VERSION, ..Default::default() }, vec!["(ファイル全体)".into()]);
        };
        let mut dropped = Vec::new();
        let mut settings: Settings = Settings::default();
        if let Some(Value::Object(s)) = obj.get("settings") {
            // 設定は項目ごとに既定値で補う
            let mut merged = serde_json::to_value(Settings::default()).unwrap_or(Value::Null);
            if let Value::Object(m) = &mut merged {
                for (k, v) in s {
                    if m.contains_key(k) {
                        m.insert(k.clone(), v.clone());
                    }
                }
            }
            settings = serde_json::from_value(merged).unwrap_or_else(|_| {
                dropped.push("settings".into());
                Settings::default()
            });
        }
        let st = PersistState {
            version: STATE_VERSION,
            settings,
            halted: field(&obj, "halted", &mut dropped),
            blocked_until_ms: field(&obj, "blocked_until_ms", &mut dropped),
            codes: list(&obj, "codes", &mut dropped),
            ledger: list(&obj, "ledger", &mut dropped),
            last_code_sent_ms: field(&obj, "last_code_sent_ms", &mut dropped),
            last_otp_sent_ms: field(&obj, "last_otp_sent_ms", &mut dropped),
            snapshot: field(&obj, "snapshot", &mut dropped),
            catalog: field(&obj, "catalog", &mut dropped),
            history: list(&obj, "history", &mut dropped),
            runs: list(&obj, "runs", &mut dropped),
            pending: list(&obj, "pending", &mut dropped),
            log: list(&obj, "log", &mut dropped),
            mock_session: field(&obj, "mock_session", &mut dropped),
        };
        (st, dropped)
    }

    /// 書き込む(一時ファイルに書いてから置き換える)。
    pub fn save(&mut self, path: &PathBuf) {
        trim(&mut self.log, LOG_MAX);
        trim(&mut self.ledger, LEDGER_MAX);
        trim(&mut self.runs, RUNS_MAX);
        self.version = STATE_VERSION;
        let Ok(bytes) = serde_json::to_vec(self) else { return };
        let tmp = path.with_extension("tmp");
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
}

fn trim<T>(v: &mut Vec<T>, max: usize) {
    if v.len() > max {
        let cut = v.len() - max;
        v.drain(..cut);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tolerant_load_keeps_good_fields() {
        let dir = std::env::temp_dir().join(format!("povox-state-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");
        // v1 の形: ledger の形が違う・snapshot が別物・設定は一部だけ
        let v1 = serde_json::json!({
            "settings": {"dry_run": true, "monthly_cap_yen": 500, "unknown": 1},
            "codes": [
                {"id": "a", "code": "ABC", "tag": "1gb", "note": "", "status": "pending", "added_ms": 1},
                {"id": "b", "code": "DEF", "status": "weird", "added_ms": 1}
            ],
            "ledger": [{"time_ms": 1, "sku": "X", "auto": true, "status": "ok"}],
            "snapshot": {"usage": {"buckets": []}, "left_kb": 3},
            "halted": "HTTP 403 x",
        });
        std::fs::write(&path, v1.to_string()).unwrap();
        let (st, dropped) = PersistState::load(&path);
        assert_eq!(st.settings.monthly_cap_yen, 500);
        assert!(st.settings.dry_run);
        assert_eq!(st.settings.purchase_mode, ActionMode::Confirm);
        assert_eq!(st.codes.len(), 1);
        assert_eq!(st.codes[0].code, "ABC");
        assert!(st.ledger.is_empty());
        assert!(st.snapshot.is_none());
        assert_eq!(st.halted.as_deref(), Some("HTTP 403 x"));
        assert!(dropped.iter().any(|d| d.starts_with("codes")));
        assert!(dropped.iter().any(|d| d.starts_with("ledger")));
        assert!(dropped.contains(&"snapshot".to_string()));

        std::fs::write(&path, "not json").unwrap();
        let (st, dropped) = PersistState::load(&path);
        assert!(st.codes.is_empty());
        assert_eq!(dropped.len(), 1);
        assert!(dir.join("state.broken.json").exists());
    }
}
