//! モック用の作り物データ(povo-web から流用、1時間使い放題を追加)。povo には一切通信しない。
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
