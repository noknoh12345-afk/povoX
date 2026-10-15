//! モック用の作り物データ。povo には一切通信しない。
//! 固定のサンプル(povo-web から流用)に加えて、購入・コード適用で残量やトッピングが
//! 変わる「状態つきモック」(`MockState`)を持つ。シミュレータでの画面テストに使う。
//! 形は povo-android の実測サンプルとパーサーに合わせてあるが、値はすべて架空。
#![allow(dead_code)]

pub const USAGE: &str = r#"{
  "data": {
    "basic": {"left": 2097152, "plan_kb": 3145728, "section": "DATA", "unit": "kilobytes", "used": 1048576},
    "extra": {"left": 15728640, "plan_kb": 20971520, "section": "DATA", "unit": "kilobytes", "used": 5242880},
    "bonus": {"left": 307200, "section": "BONUS", "unit": "kilobytes", "used": 0},
    "boost": {"left": 0, "section": "BOOST", "unit": "kilobytes", "used": 0},
    "plus":  {"left": 0, "plan_kb": 0, "section": "", "unit": "kilobytes", "used": 0},
    "promotion_text": {"line1": "Bonus", "line2": "300 MB"}
  },
  "other": {
    "basic": {
      "calls": {"used": 754, "left": 0, "unit": "seconds"},
      "sms": {"used": 3, "left": 0, "unit": "count"}
    }
  }
}"#;

pub const USER_PLAN_DETAILS: &str = r#"{
  "_id": "user-plan-details-v2",
  "widgets": [{"type": "list", "components": [
    {"type": "povo-tile-plan-header", "data": {"title": "データ"}},
    {"type": "povo-tile-plan-detail", "data": {
      "name": {"title": "(モック)データ追加20GB(30日間)"},
      "remaining": {"title": "残量", "value": "15.00GB / 20.00GB"},
      "expiry": {"title": "有効期限", "value": "2026年 10月 20日 午後11:59\n残り 6 日間"}}},
    {"type": "povo-tile-divider", "data": {"color": "primary"}},
    {"type": "povo-tile-plan-header", "data": {"title": "通話"}},
    {"type": "povo-tile-plan-detail", "data": {
      "name": {"title": "(モック)5分以内通話かけ放題"},
      "expiry": {"title": "次回更新", "value": "2026年 11月 1日"}}}
  ]}]
}"#;

pub const ORDER_HISTORY: &str = r#"{
  "_id": "order-history",
  "widgets": [{"type": "list", "components": [
    {"type": "tile-status-card", "data": {
      "order_id": "MOCK-0002", "order_status": "success", "status": "注文完了",
      "purchase_date": "2026年 9月 20日",
      "products": [{"product_name": "(モック)データ追加20GB(30日間)", "price": "2,700円"}]}},
    {"type": "tile-status-card", "data": {
      "order_id": "MOCK-0001", "order_status": "success", "status": "注文完了",
      "purchase_date": "2026年 6月 1日",
      "products": [{"product_name": "(モック)データ追加1GB(7日間)", "price": "390円"}]}}
  ]}]
}"#;

pub const DASHBOARD: &str = r#"{
  "_id": "dashboard-v2",
  "widgets": [{"type": "list", "components": [
    {"type": "image-banner", "data": {"title": "無視されるバナー"}},
    {"type": "addon-section", "data": {
      "sectionHeader": {"title": "データトッピング"},
      "items": [
        {"data": {"id": "MOCK_DATA_1GB_7D", "name": {"title": "データ追加1GB"}, "validity": {"title": "7日間"}, "price": {"title": "390円"}},
         "action": {"data": {"product_popup": {"id": "MOCK_DATA_1GB_7D", "title": "(モック)データ追加1GB(7日間)", "price": "390円", "is_3ds_topping": false}}}},
        {"data": {"id": "MOCK_DATA_20GB_30D", "name": {"title": "データ追加20GB"}, "validity": {"title": "30日間"}, "price": {"title": "2,700円"}},
         "action": {"data": {"product_popup": {"id": "MOCK_DATA_20GB_30D", "title": "(モック)データ追加20GB(30日間)", "price": "2,700円", "is_3ds_topping": true}}}}
      ]}},
    {"type": "addon-section", "data": {
      "sectionHeader": {"title": "使い放題"},
      "items": [
        {"data": {"id": "MOCK_UNLIMITED_1H", "name": {"title": "データ使い放題"}, "validity": {"title": "1時間"}, "price": {"title": "110円"}},
         "action": {"data": {"product_popup": {"id": "MOCK_UNLIMITED_1H", "title": "(モック)データ使い放題(1時間)", "price": "110円", "is_3ds_topping": false}}}},
        {"data": {"id": "MOCK_UNLIMITED_24H", "name": {"title": "データ使い放題"}, "validity": {"title": "24時間"}, "price": {"title": "330円"}},
         "action": {"data": {"product_popup": {"id": "MOCK_UNLIMITED_24H", "title": "(モック)データ使い放題(24時間)", "price": "330円", "is_3ds_topping": false}}}}
      ]}},
    {"type": "addon-section", "data": {"sectionHeader": {"title": "空のセクション"}, "items": []}}
  ]}]
}"#;

pub const BILLS: &str = r#"{
  "result": {
    "past_bills": {"list": [
      {"billId": "mock-bill-1", "title": "2026年9月分", "type": "PAID", "total": "2,700円", "time": 1789516800000, "actions": [{"type": "pdf"}]},
      {"billId": "mock-bill-0", "title": "2026年6月分", "type": "PAID", "total": "390円", "time": 1780531200000, "actions": [{"type": "pdf"}]}
    ]},
    "upcoming_bill": {"total": "0円", "list": []},
    "instant_charges": {"list": []}
  }
}"#;

pub const REFERRAL: &str = r#"{
  "result": {
    "referral_code": "MOCKREF123",
    "message": "友だちがこのコードで登録すると、おたがいに特典がもらえます。"
  }
}"#;

/// 3DS が要る商品を買うと challenge_url 付き、要らない商品は即完了を返す。
pub fn order_response(sku: &str) -> String {
    if sku == "MOCK_DATA_20GB_30D" {
        r#"{"result":{"challenge_url":"https://example.com/mock-3ds","order_ref":"MOCK-ORDER-3DS","p_ref":"MOCK-P"}}"#.into()
    } else {
        format!(r#"{{"result":{{"order_ref":"MOCK-ORDER-{sku}","p_ref":"MOCK-P"}}}}"#)
    }
}

/// コード適用の作り物の応答。
/// `MOCKOK` は成功、`MOCKUSED` は使用済み(200 で codeValid=false)、
/// `MOCKEXPIRED` は povo のエラー応答(422)を真似る。それ以外は無効なコード。
pub fn code_response(code: &str) -> crate::backend::R<String> {
    use povo_core::PovoError;
    match code {
        "MOCKOK" => Ok(r#"{"codeValid":true,"title":"(モック)コードを適用しました","subtitle":"データ追加1GB(7日間)","message":"トッピングに追加されました。反映まで数分かかることがあります。","images":[]}"#.into()),
        "MOCKUSED" => Ok(r#"{"codeValid":false,"title":"(モック)このコードは使用済みです","subtitle":"","message":"別のコードを入力してください。","images":[]}"#.into()),
        "MOCKEXPIRED" => Err(PovoError::Api {
            status: 422,
            server_message: "(モック)code expired".into(),
            code: Some(4221131),
            title: Some("(モック)コードの有効期限が切れています".into()),
            detail: None,
            block_until_epoch_millis: None,
        }
        .into()),
        _ => Ok(r#"{"codeValid":false,"title":"(モック)無効なコード","subtitle":"","message":"もう一度やり直してください。","images":[]}"#.into()),
    }
}

/// 最小の有効なPDF(1ページ、文字あり)。
pub fn bill_pdf() -> Vec<u8> {
    let body = "BT /F1 18 Tf 72 720 Td (povo-web mock bill) Tj ET";
    let objs = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".to_string(),
        format!("<< /Length {} >>\nstream\n{}\nendstream", body.len(), body),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
    ];
    let mut out = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        out.extend(format!("{} 0 obj\n{}\nendobj\n", i + 1, o).as_bytes());
    }
    let xref = out.len();
    out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for off in offsets {
        out.extend(format!("{off:010} 00000 n \n").as_bytes());
    }
    out.extend(
        format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n", objs.len() + 1, xref)
            .as_bytes(),
    );
    out
}


// ---- 状態つきモック ------------------------------------------------------------------

use crate::jptime;

const GB: f64 = 1_048_576.0;

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

struct MockTopping {
    name: String,
    remaining: Option<String>,
    expiry_ms: i64,
}

struct MockOrder {
    name: String,
    price: String,
    time_ms: i64,
}

/// 時間とともに残量が減り、購入・コードで増える、作り物の回線。
pub struct MockState {
    pub token: Option<String>,
    left_kb: f64,
    rate_kb_per_h: f64,
    updated_ms: i64,
    unlimited_until_ms: Option<i64>,
    unlimited_name: String,
    toppings: Vec<MockTopping>,
    orders: Vec<MockOrder>,
}

impl MockState {
    /// `scenario`: "" はふつう(残り約17GB)、"low" は残りわずか(300MB)から始める。
    pub fn new(scenario: &str) -> MockState {
        let now = now_ms();
        let (left, rate) = if scenario == "low" { (0.25 * GB, 40.0 * 1024.0) } else { (17.29 * GB, 25.0 * 1024.0) };
        MockState {
            token: None,
            left_kb: left,
            rate_kb_per_h: rate,
            updated_ms: now,
            unlimited_until_ms: None,
            unlimited_name: String::new(),
            toppings: vec![MockTopping {
                name: "(モック)データ追加20GB(30日間)".into(),
                remaining: None,
                expiry_ms: jptime::jst_midnight_ms(now) + 6 * 86_400_000 + 86_340_000,
            }],
            orders: vec![
                MockOrder { name: "(モック)データ追加20GB(30日間)".into(), price: "2,700円".into(), time_ms: now - 25 * 86_400_000 },
                MockOrder { name: "(モック)データ追加1GB(7日間)".into(), price: "390円".into(), time_ms: now - 120 * 86_400_000 },
            ],
        }
    }

    /// 経過時間ぶん残量を減らす(使い放題の間は減らさない)。
    fn advance(&mut self) {
        let now = now_ms();
        let mut from = self.updated_ms;
        if let Some(until) = self.unlimited_until_ms {
            if until > from {
                from = until.min(now);
            }
        }
        if now > from {
            let used = self.rate_kb_per_h * (now - from) as f64 / 3_600_000.0;
            self.left_kb = (self.left_kb - used).max(0.0);
        }
        self.updated_ms = now;
        if self.unlimited_until_ms.is_some_and(|u| u <= now) {
            self.unlimited_until_ms = None;
        }
    }

    fn add_unlimited(&mut self, hours: i64, name: &str) {
        let now = now_ms();
        let base = self.unlimited_until_ms.filter(|u| *u > now).unwrap_or(now);
        self.unlimited_until_ms = Some(base + hours * 3_600_000);
        self.unlimited_name = name.to_string();
    }

    fn add_data(&mut self, gb: f64, name: &str, days: i64) {
        self.left_kb += gb * GB;
        self.toppings.push(MockTopping {
            name: name.to_string(),
            remaining: Some(format!("{gb:.2}GB / {gb:.2}GB")),
            expiry_ms: jptime::jst_midnight_ms(now_ms()) + days * 86_400_000 + 86_340_000,
        });
    }

    pub fn usage_json(&mut self) -> String {
        self.advance();
        let left = self.left_kb;
        let bonus = left.min(0.3 * GB);
        let rest = left - bonus;
        let basic = rest.min(2.0 * GB);
        let extra = rest - basic;
        serde_json::json!({
            "data": {
                "basic": {"left": basic.round(), "plan_kb": 3.0 * GB, "unit": "kilobytes", "used": (3.0 * GB - basic).max(0.0).round()},
                "extra": {"left": extra.round(), "plan_kb": 20.0 * GB, "unit": "kilobytes", "used": (20.0 * GB - extra).max(0.0).round()},
                "bonus": {"left": bonus.round(), "unit": "kilobytes", "used": 0},
                "boost": {"left": 0, "unit": "kilobytes", "used": 0},
                "plus": {"left": 0, "plan_kb": 0, "unit": "kilobytes", "used": 0},
            },
            "other": {"basic": {
                "calls": {"used": 754, "left": 0, "unit": "seconds"},
                "sms": {"used": 3, "left": 0, "unit": "count"}
            }}
        })
        .to_string()
    }

    pub fn plan_details_json(&mut self) -> String {
        self.advance();
        let now = now_ms();
        let mut comps = vec![serde_json::json!({"type": "povo-tile-plan-header", "data": {"title": "データ"}})];
        if let Some(until) = self.unlimited_until_ms {
            comps.push(serde_json::json!({"type": "povo-tile-plan-detail", "data": {
                "name": {"title": self.unlimited_name},
                "expiry": {"title": "有効期限", "value": jptime::format_jp_datetime(until)}}}));
        }
        for t in self.toppings.iter().filter(|t| t.expiry_ms > now) {
            let days = ((t.expiry_ms - now) / 86_400_000).max(0);
            let mut d = serde_json::json!({
                "name": {"title": t.name},
                "expiry": {"title": "有効期限", "value": format!("{}\n残り {} 日間", jptime::format_jp_datetime(t.expiry_ms), days)}});
            if let Some(r) = &t.remaining {
                d["remaining"] = serde_json::json!({"title": "残量", "value": r});
            }
            comps.push(serde_json::json!({"type": "povo-tile-plan-detail", "data": d}));
        }
        comps.push(serde_json::json!({"type": "povo-tile-plan-header", "data": {"title": "通話"}}));
        comps.push(serde_json::json!({"type": "povo-tile-plan-detail", "data": {
            "name": {"title": "(モック)5分以内通話かけ放題"},
            "expiry": {"title": "次回更新", "value": "毎月1日"}}}));
        serde_json::json!({"_id": "user-plan-details-v2", "widgets": [{"type": "list", "components": comps}]}).to_string()
    }

    pub fn order_history_json(&self) -> String {
        let mut list: Vec<&MockOrder> = self.orders.iter().collect();
        list.sort_by_key(|o| -o.time_ms);
        let comps: Vec<serde_json::Value> = list
            .iter()
            .enumerate()
            .map(|(i, o)| {
                let (y, m, d) = jptime::jst_ymd(o.time_ms);
                serde_json::json!({"type": "tile-status-card", "data": {
                    "order_id": format!("MOCK-{:04}", list.len() - i), "order_status": "success", "status": "注文完了",
                    "purchase_date": format!("{y}年 {m}月 {d}日"),
                    "products": [{"product_name": o.name, "price": o.price}]}})
            })
            .collect();
        serde_json::json!({"_id": "order-history", "widgets": [{"type": "list", "components": comps}]}).to_string()
    }

    pub fn order(&mut self, sku: &str) -> Result<String, povo_core::PovoError> {
        use povo_core::PovoError;
        self.advance();
        let (name, price) = match sku {
            "MOCK_FORBIDDEN" => {
                return Err(PovoError::Api {
                    status: 403,
                    server_message: "(モック)device mismatch".into(),
                    code: Some(403001),
                    title: None,
                    detail: None,
                    block_until_epoch_millis: None,
                })
            }
            "MOCK_DATA_20GB_30D" => {
                return Ok(r#"{"result":{"challenge_url":"https://example.com/mock-3ds","order_ref":"MOCK-ORDER-3DS","p_ref":"MOCK-P"}}"#.into())
            }
            "MOCK_UNLIMITED_1H" => {
                self.add_unlimited(1, "(モック)データ使い放題(1時間)");
                ("(モック)データ使い放題(1時間)", "110円")
            }
            "MOCK_UNLIMITED_24H" => {
                self.add_unlimited(24, "(モック)データ使い放題(24時間)");
                ("(モック)データ使い放題(24時間)", "330円")
            }
            "MOCK_DATA_1GB_7D" => {
                self.add_data(1.0, "(モック)データ追加1GB(7日間)", 7);
                ("(モック)データ追加1GB(7日間)", "390円")
            }
            _ => {
                return Err(PovoError::Api {
                    status: 422,
                    server_message: "(モック)not purchasable".into(),
                    code: Some(4220000),
                    title: Some("(モック)この商品は購入できません".into()),
                    detail: None,
                    block_until_epoch_millis: None,
                })
            }
        };
        self.orders.push(MockOrder { name: name.into(), price: price.into(), time_ms: now_ms() });
        Ok(format!(r#"{{"result":{{"order_ref":"MOCK-ORDER-{sku}","p_ref":"MOCK-P"}}}}"#))
    }

    /// `MOCKOK…` は 1GB 追加、`MOCKUNL1H…` / `MOCKUNL…` は使い放題(1時間/24時間)、
    /// `MOCKUSED…` は使用済み、`MOCKEXPIRED…` は povo のエラー応答、それ以外は無効なコード。
    pub fn apply_code(&mut self, code: &str) -> Result<String, povo_core::PovoError> {
        use povo_core::PovoError;
        self.advance();
        let ok = |title: &str, sub: &str| {
            Ok(serde_json::json!({"codeValid": true, "title": title, "subtitle": sub,
                "message": "トッピングに追加されました。反映まで数分かかることがあります。", "images": []}).to_string())
        };
        if code.starts_with("MOCKUNL1H") {
            self.add_unlimited(1, "(モック)データ使い放題(1時間)");
            return ok("(モック)コードを適用しました", "データ使い放題(1時間)");
        }
        if code.starts_with("MOCKUNL") {
            self.add_unlimited(24, "(モック)データ使い放題(24時間)");
            return ok("(モック)コードを適用しました", "データ使い放題(24時間)");
        }
        if code.starts_with("MOCKOK") {
            self.add_data(1.0, "(モック)データ追加1GB(7日間・コード)", 7);
            return ok("(モック)コードを適用しました", "データ追加1GB(7日間)");
        }
        if code.starts_with("MOCKUSED") {
            return Ok(r#"{"codeValid":false,"title":"(モック)このコードは使用済みです","subtitle":"","message":"別のコードを入力してください。","images":[]}"#.into());
        }
        if code.starts_with("MOCKEXPIRED") {
            return Err(PovoError::Api {
                status: 422,
                server_message: "(モック)code expired".into(),
                code: Some(4221131),
                title: Some("(モック)コードの有効期限が切れています".into()),
                detail: None,
                block_until_epoch_millis: None,
            });
        }
        Ok(r#"{"codeValid":false,"title":"(モック)無効なコード","subtitle":"","message":"もう一度やり直してください。","images":[]}"#.into())
    }
}

#[cfg(test)]
mod state_tests {
    use super::*;

    #[test]
    fn purchases_change_state() {
        let mut m = MockState::new("low");
        let u = crate::parse::usage(&m.usage_json()).unwrap();
        let left: f64 = u["buckets"].as_array().unwrap().iter().map(|b| b["left_kb"].as_f64().unwrap()).sum();
        assert!(left > 0.24 * GB && left <= 0.25 * GB + 1.0, "{left}");
        m.order("MOCK_UNLIMITED_1H").unwrap();
        let t = crate::parse::toppings(&m.plan_details_json()).unwrap();
        assert!(t.as_array().unwrap().iter().any(|x| x["name"].as_str().unwrap().contains("使い放題")));
        m.apply_code("MOCKOK1").unwrap();
        let u = crate::parse::usage(&m.usage_json()).unwrap();
        let left: f64 = u["buckets"].as_array().unwrap().iter().map(|b| b["left_kb"].as_f64().unwrap()).sum();
        assert!(left > 1.24 * GB);
        let h = crate::parse::purchases(&m.order_history_json()).unwrap();
        assert_eq!(h.as_array().unwrap().len(), 3);
        assert!(m.order("MOCK_FORBIDDEN").is_err());
        assert!(m.order("NOPE").is_err());
    }
}
