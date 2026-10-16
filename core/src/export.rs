//! 検証用の書き出し(端末の中の生データを JSON にする。外へは送らない。送るかは利用者が共有シートで決める)。
//!
//! 「推測の数字を使わない」ための材料: 残量の記録・実行の記録・購入の台帳・コード(伏せ字)・設定・
//! トッピング一覧・ログ、望めば povo 公式の購入履歴。ログイン情報(トークン・識別子の全文)は入れない。

use serde_json::{json, Value};

use crate::engine::{mask, Engine};

pub const FORMAT: &str = "povox-export/1";

impl Engine {
    pub fn export_json(&mut self, include_purchases: bool) -> String {
        let now = self.now();
        let codes: Vec<Value> = self
            .st
            .codes
            .iter()
            .map(|c| {
                json!({
                    "id": c.id, "masked": mask(&c.code), "tag": c.tag, "note": c.note,
                    "status": c.status, "addedMs": c.added_ms, "sentMs": c.sent_ms, "result": c.result,
                })
            })
            .collect();
        let samples: Vec<Value> = self.st.history.iter().map(|s| json!([s.t_ms, s.left_kb, s.unlimited])).collect();
        let mut out = json!({
            "format": FORMAT,
            "exportedMs": now,
            "timezone": "Asia/Tokyo",
            "mock": self.mock,
            "samplesColumns": ["tMs", "leftKb", "unlimited"],
            "samples": samples,
            "runs": self.st.runs,
            "ledger": self.st.ledger,
            "pending": self.st.pending,
            "codes": codes,
            "settings": self.st.settings,
            "budget": self.budget(),
            "insights": self.insights(),
            "snapshot": self.st.snapshot,
            "catalog": self.st.catalog,
            "logs": self.st.log,
        });
        if include_purchases {
            match self.purchase_history() {
                Ok(p) => out["purchases"] = json!(p),
                Err(f) => out["purchasesError"] = json!(f.message),
            }
        }
        out.to_string()
    }
}

#[cfg(test)]
mod tests {
    use crate::model::*;
    use crate::store::MemoryStore;
    use crate::engine::Engine;

    #[test]
    fn export_has_raw_material_but_no_secrets() {
        let dir = std::env::temp_dir().join(format!("povox-export-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut e = Engine::open(&EngineConfig { dir: dir.to_string_lossy().into(), mock: true, mock_scenario: String::new() },
                                 Box::new(MemoryStore::default()));
        e.login_start(Some("secret-user@example.com".into()), None).unwrap();
        e.login_otp("000000").unwrap();
        e.snapshot(false).unwrap();
        e.add_codes("MOCKSECRETCODE1 1gb", None);
        let s = e.export_json(true);
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["format"], super::FORMAT);
        assert!(v["samples"].as_array().unwrap().len() > 100);
        assert_eq!(v["samples"][0].as_array().unwrap().len(), 3);
        assert!(v["purchases"].as_array().is_some(), "{s}");
        assert!(!s.contains("MOCKSECRETCODE1"), "コードは伏せ字");
        assert!(!s.contains("secret-user@example.com"), "ログイン識別子は入れない");
    }
}
