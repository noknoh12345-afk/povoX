//! povo のレスポンスを画面用の小さな JSON に直す。
//!
//! 読み方は povo-android の QuiltParser / UsageParser / BillsParser と同じ。
//! 未知のタイルは無視し、形が変わって読めないときは「空」ではなく None を返して
//! 画面に「読めなかった」と出す(ゼロを本物の値のように見せないため)。
#![allow(dead_code)]

use serde_json::{json, Map, Value};

fn parse(raw: &str) -> Option<Value> {
    serde_json::from_str(raw).ok()
}

fn s(v: Option<&Value>, keys: &[&str]) -> Option<String> {
    let obj = v?.as_object()?;
    keys.iter().find_map(|k| {
        obj.get(*k).and_then(|x| match x {
            Value::String(t) => {
                let t = t.trim();
                (!t.is_empty()).then(|| t.to_string())
            }
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        })
    })
}

fn o<'a>(v: Option<&'a Value>, keys: &[&str]) -> Option<&'a Value> {
    let obj = v?.as_object()?;
    keys.iter().find_map(|k| obj.get(*k).filter(|x| x.is_object()))
}

fn arr<'a>(v: Option<&'a Value>, keys: &[&str]) -> Option<&'a Vec<Value>> {
    let obj = v?.as_object()?;
    keys.iter().find_map(|k| obj.get(*k).and_then(|x| x.as_array()))
}

fn f(v: Option<&Value>, keys: &[&str]) -> Option<f64> {
    let obj = v?.as_object()?;
    keys.iter().find_map(|k| match obj.get(*k)? {
        Value::Number(n) => n.as_f64(),
        Value::String(t) => t.parse().ok(),
        _ => None,
    })
}

/// `result` / `data` の封筒を、目印のキーが見えるところまで剥がす(最大3段)。
fn unwrap<'a>(mut cur: &'a Value, stop_at: &[&str]) -> &'a Value {
    for _ in 0..3 {
        let Some(obj) = cur.as_object() else { return cur };
        if stop_at.iter().any(|k| obj.contains_key(*k)) {
            return cur;
        }
        match obj.get("result").or_else(|| obj.get("data")) {
            Some(next) if next.is_object() => cur = next,
            _ => return cur,
        }
    }
    cur
}

/// Quilt ページの `widgets[].components[]` を平らにする。
fn components(root: &Value) -> Vec<&Value> {
    arr(Some(root), &["widgets", "pageWidgets"])
        .into_iter()
        .flatten()
        .flat_map(|w| arr(Some(w), &["components", "items"]).into_iter().flatten())
        .filter(|c| c.is_object())
        .collect()
}

fn tile_data(c: &Value) -> &Value {
    o(Some(c), &["data"]).unwrap_or(c)
}

const BUCKETS: &[(&str, &str)] = &[
    ("basic", "基本"),
    ("extra", "追加"),
    ("bonus", "ボーナス"),
    ("boost", "ブースト"),
    ("plus", "プラス"),
];

/// `account/usage/plan/get`。値は KB(1024基準)。
pub fn usage(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    let keys: Vec<&str> = BUCKETS.iter().map(|b| b.0).collect();
    let data = unwrap(&root, &keys);
    let buckets: Vec<Value> = BUCKETS
        .iter()
        .filter_map(|(key, label)| {
            let node = o(Some(data), &[key])?;
            Some(json!({
                "key": key,
                "label": label,
                "used_kb": f(Some(node), &["used", "used_kb"]).unwrap_or(0.0),
                "left_kb": f(Some(node), &["left", "remaining"]).unwrap_or(0.0),
                "plan_kb": f(Some(node), &["plan_kb"]),
            }))
        })
        .collect();
    if buckets.is_empty() {
        return None;
    }
    let promo = o(Some(data), &["promotion_text"]);
    // 通話・SMS は `other.basic.calls` / `other.basic.sms`(通話は秒)。
    // `other` は封筒の外にも中にもありうるので、外側から順に探す。
    let other_basic = [&root, unwrap(&root, &["other"]), data]
        .into_iter()
        .find_map(|n| o(o(Some(n), &["other"]), &["basic"]));
    let counter = |key: &str| {
        let node = o(other_basic, &[key])?;
        Some(json!({
            "used": f(Some(node), &["used"]).unwrap_or(0.0),
            "left": f(Some(node), &["left", "remaining"]),
            "unit": s(Some(node), &["unit"]),
        }))
    };
    Some(json!({
        "buckets": buckets,
        "promotion": [s(promo, &["line1"]), s(promo, &["line2"])],
        "calls": counter("calls"),
        "sms": counter("sms"),
    }))
}

/// `promotions/code/set` の応答。`codeValid` が無ければ None(形が違う)。
pub fn code_result(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    let doc = unwrap(&root, &["codeValid", "code_valid"]);
    let valid = doc.get("codeValid").or_else(|| doc.get("code_valid"))?.as_bool()?;
    let images: Vec<Value> = arr(Some(doc), &["images"])
        .into_iter()
        .flatten()
        .filter_map(|i| s(Some(i), &["url"]))
        .filter(|u| u.starts_with("https://"))
        .map(Value::String)
        .collect();
    Some(json!({
        "valid": valid,
        "title": s(Some(doc), &["title"]),
        "subtitle": s(Some(doc), &["subtitle"]),
        "message": s(Some(doc), &["message"]),
        "images": images,
    }))
}

/// `user-plan-details-v2`: 契約中のトッピング。
pub fn toppings(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    root.get("widgets").or_else(|| root.get("pageWidgets"))?;
    let mut section: Option<String> = None;
    let mut out = Vec::new();
    for c in components(&root) {
        let ty = s(Some(c), &["type"]).unwrap_or_default();
        let data = Some(tile_data(c));
        if ty.ends_with("plan-header") {
            section = s(data, &["title"]);
        } else if ty.ends_with("plan-detail") {
            let Some(name) = s(o(data, &["name"]), &["title"]).or_else(|| s(data, &["title"])) else {
                continue;
            };
            out.push(json!({
                "section": section,
                "name": name,
                "remaining": s(o(data, &["remaining"]), &["value"]),
                "expiry": s(o(data, &["expiry"]), &["value"]),
            }));
        }
    }
    Some(Value::Array(out))
}

/// `order-history`: 購入履歴。
pub fn purchases(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    root.get("widgets").or_else(|| root.get("pageWidgets"))?;
    let out: Vec<Value> = components(&root)
        .into_iter()
        .filter(|c| s(Some(c), &["type"]).is_some_and(|t| t.contains("status-card")))
        .map(|c| {
            let d = Some(tile_data(c));
            let products: Vec<Value> = arr(d, &["products"])
                .into_iter()
                .flatten()
                .map(|p| {
                    json!({
                        "name": s(Some(p), &["product_name", "name", "title"]),
                        "price": s(Some(p), &["price"]),
                    })
                })
                .collect();
            let date = s(d, &["purchase_date", "order_date", "date"]);
            json!({
                "order_id": s(d, &["order_id", "orderId"]),
                "status": s(d, &["status"]),
                "order_status": s(d, &["order_status", "orderStatus"]),
                "date": date,
                "date_iso": date.as_deref().and_then(japanese_date_to_iso),
                "products": products,
            })
        })
        .collect();
    Some(Value::Array(out))
}

/// "2026年 2月 28日" → "2026-02-28"
pub fn japanese_date_to_iso(text: &str) -> Option<String> {
    let nums: Vec<u32> = text
        .split(|c: char| !c.is_ascii_digit())
        .filter(|p| !p.is_empty())
        .filter_map(|p| p.parse().ok())
        .collect();
    match nums.as_slice() {
        [y, m, d, ..] if *y > 2000 && (1..=12).contains(m) && (1..=31).contains(d) => {
            Some(format!("{y:04}-{m:02}-{d:02}"))
        }
        _ => None,
    }
}

/// `dashboard-v2` の `addon-section` タイル: 購入できるトッピング一覧。
/// 各商品は一覧行(`data`)と確認シート(`action.data.product_popup`)の2か所にあり、
/// 確認シートの値を優先する。sku は確認シートの `id`。
pub fn catalog(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    root.get("widgets").or_else(|| root.get("pageWidgets"))?;
    let sections: Vec<Value> = components(&root)
        .into_iter()
        .filter(|c| s(Some(c), &["type"]).as_deref() == Some("addon-section"))
        .filter_map(|c| {
            let data = o(Some(c), &["data"])?;
            let products: Vec<Value> = arr(Some(data), &["items"])
                .into_iter()
                .flatten()
                .filter_map(|item| {
                    let tile = o(Some(item), &["data"]);
                    let popup = o(o(Some(item), &["action"]), &["data"])
                        .and_then(|d| o(Some(d), &["product_popup", "productPopup"]));
                    let id = s(popup, &["id"]).or_else(|| s(tile, &["id"]))?;
                    let name = s(popup, &["title"]).or_else(|| s(o(tile, &["name"]), &["title"]))?;
                    let requires_3ds = popup
                        .and_then(|p| p.get("is_3ds_topping").or_else(|| p.get("is3dsTopping")))
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false);
                    Some(json!({
                        "sku": id,
                        "name": name,
                        "validity": s(o(tile, &["validity"]), &["title"]),
                        "price": s(popup, &["price"]).or_else(|| s(o(tile, &["price"]), &["title"])),
                        "requires_3ds": requires_3ds,
                    }))
                })
                .collect();
            (!products.is_empty()).then(|| {
                json!({
                    "title": s(o(Some(data), &["sectionHeader"]), &["title"]),
                    "products": products,
                })
            })
        })
        .collect();
    Some(Value::Array(sections))
}

/// `shop/orders` の応答。`challenge_url` があれば3DSが必要で、まだ課金されていない。
pub fn order(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    let result = o(Some(&root), &["result"]).unwrap_or(&root);
    Some(json!({
        "challenge_url": s(Some(result), &["challenge_url", "challengeUrl"]),
        "order_ref": s(Some(result), &["order_ref", "orderRef", "order_id", "orderId"]),
        "payment_ref": s(Some(result), &["p_ref", "pRef"]),
    }))
}

fn money(v: Option<&Value>, keys: &[&str]) -> Option<String> {
    let obj = v?.as_object()?;
    keys.iter().find_map(|k| match obj.get(*k)? {
        Value::Number(n) => Some(format!("¥{}", n)),
        Value::String(t) if !t.trim().is_empty() => Some(t.trim().to_string()),
        Value::Object(m) => s(Some(&Value::Object(m.clone())), &["value", "amount", "text"]),
        _ => None,
    })
}

fn epoch_ms(v: Option<&Value>, keys: &[&str]) -> Option<i64> {
    let obj = v?.as_object()?;
    keys.iter().find_map(|k| match obj.get(*k)? {
        Value::Number(n) => n.as_i64(),
        Value::String(t) => t.parse().ok(),
        _ => None,
    })
}

/// `layout/bills/info`(v5)。
pub fn bills(raw: &str) -> Option<Value> {
    let root = parse(raw)?;
    let doc = unwrap(&root, &["past_bills", "upcoming_bill", "instant_charges"]);
    let past = o(Some(doc), &["past_bills"]);
    let upcoming = o(Some(doc), &["upcoming_bill"]);
    let instant = o(Some(doc), &["instant_charges"]);
    if past.is_none() && upcoming.is_none() && instant.is_none() {
        return None;
    }
    let list = |sec: Option<&Value>| arr(sec, &["list"]).cloned().unwrap_or_default();
    let mut out: Vec<Value> = Vec::new();
    for n in list(upcoming) {
        out.push(json!({
            "kind": "upcoming",
            "title": s(Some(&n), &["label", "title"]),
            "subtitle": s(Some(&n), &["subtitle"]),
            "amount": money(Some(&n), &["amount", "total", "price"]),
            "time_ms": epoch_ms(Some(&n), &["time", "date"]),
            "bill_id": Value::Null,
        }));
    }
    for n in list(past) {
        let paid = s(Some(&n), &["type"]).map(|t| t.eq_ignore_ascii_case("PAID"));
        let has_pdf = arr(Some(&n), &["actions"])
            .into_iter()
            .flatten()
            .any(|a| s(Some(a), &["type"]).as_deref() == Some("pdf"));
        let bill_id = s(Some(&n), &["billId", "bill_id"]);
        out.push(json!({
            "kind": match paid { Some(true) => "paid", Some(false) => "unpaid", None => "unknown" },
            "title": s(Some(&n), &["title"]),
            "subtitle": s(Some(&n), &["subtitle", "subtitleSuffix", "subtitle_suffix"]),
            "amount": money(Some(&n), &["total", "amount", "price"]),
            "time_ms": epoch_ms(Some(&n), &["time", "date"]),
            "bill_id": if has_pdf || bill_id.is_some() { json!(bill_id) } else { Value::Null },
        }));
    }
    for n in list(instant) {
        out.push(json!({
            "kind": "instant",
            "title": s(Some(&n), &["title", "label", "name"]),
            "subtitle": s(Some(&n), &["subtitle", "description"]),
            "amount": money(Some(&n), &["price", "paid", "amount", "total"]),
            "time_ms": epoch_ms(Some(&n), &["date", "time", "created_at"]),
            "bill_id": Value::Null,
        }));
    }
    let mut m = Map::new();
    m.insert("entries".into(), Value::Array(out));
    m.insert("upcoming_total".into(), json!(money(upcoming, &["total"])));
    Some(Value::Object(m))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock;

    #[test]
    fn parses_mock_pages() {
        let u = usage(mock::USAGE).unwrap();
        assert_eq!(u["buckets"].as_array().unwrap().len(), 5);
        let t = toppings(mock::USER_PLAN_DETAILS).unwrap();
        assert_eq!(t[0]["section"], "データ");
        assert!(t[0]["name"].as_str().unwrap().contains("20GB"));
        let p = purchases(mock::ORDER_HISTORY).unwrap();
        assert_eq!(p[0]["date_iso"], "2026-09-20");
        let c = catalog(mock::DASHBOARD).unwrap();
        assert_eq!(c[0]["products"][0]["sku"], "MOCK_DATA_1GB_7D");
        assert_eq!(c[0]["products"][1]["requires_3ds"], true);
        let b = bills(mock::BILLS).unwrap();
        assert!(b["entries"].as_array().unwrap().iter().any(|e| e["bill_id"] == "mock-bill-1"));
    }

    #[test]
    fn order_with_and_without_challenge() {
        let a = order(r#"{"result":{"challenge_url":"https://x/3ds","order_ref":"o1","p_ref":"p1"}}"#).unwrap();
        assert_eq!(a["challenge_url"], "https://x/3ds");
        let b = order(r#"{"order_ref":"o2"}"#).unwrap();
        assert!(b["challenge_url"].is_null());
        assert_eq!(b["order_ref"], "o2");
    }

    #[test]
    fn calls_and_sms() {
        let u = usage(mock::USAGE).unwrap();
        assert_eq!(u["calls"]["used"], 754.0);
        assert_eq!(u["sms"]["used"], 3.0);
        let bare = usage(r#"{"basic":{"left":1,"used":0}}"#).unwrap();
        assert!(bare["calls"].is_null());
    }

    #[test]
    fn code_results() {
        let ok = code_result(&mock::code_response("MOCKOK").unwrap()).unwrap();
        assert_eq!(ok["valid"], true);
        let used = code_result(&mock::code_response("MOCKUSED").unwrap()).unwrap();
        assert_eq!(used["valid"], false);
        let wrapped = code_result(r#"{"result":{"codeValid":true,"title":"t","images":[{"url":"https://x/a.png"},{"url":"http://bad"}]}}"#).unwrap();
        assert_eq!(wrapped["images"].as_array().unwrap().len(), 1);
        assert!(code_result(r#"{"title":"no flag"}"#).is_none());
    }

    #[test]
    fn unreadable_shapes_are_none() {
        assert!(usage("{}").is_none());
        assert!(toppings("{}").is_none());
        assert!(catalog("not json").is_none());
        assert!(bills("{}").is_none());
    }

    #[test]
    fn japanese_dates() {
        assert_eq!(japanese_date_to_iso("2026年 2月 28日").as_deref(), Some("2026-02-28"));
        assert_eq!(japanese_date_to_iso("不明"), None);
    }
}
