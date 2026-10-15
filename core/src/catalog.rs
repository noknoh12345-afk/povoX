//! 購入できるトッピングの一覧(`dashboard-v2`)を、ルールで選びやすい形にする。
//! 名前と有効期間から、データ量(GB)・時間・使い放題かどうか・1GB あたりの価格を読む。

use serde_json::Value;

use crate::model::Product;

/// "2,700円" "¥330" "330" → 円。読めなければ None(その商品はルールでは買わない)。
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
        let rest = t[i..].trim_start_matches(['¥', '￥']).trim_start();
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

/// 全角英数字を半角にする(povo の表記ゆれ対策)。
fn half(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '０'..='９' => char::from_u32(c as u32 - '０' as u32 + '0' as u32).unwrap_or(c),
            'Ａ'..='Ｚ' => char::from_u32(c as u32 - 'Ａ' as u32 + 'A' as u32).unwrap_or(c),
            'ａ'..='ｚ' => char::from_u32(c as u32 - 'ａ' as u32 + 'a' as u32).unwrap_or(c),
            '．' => '.',
            _ => c,
        })
        .collect()
}

/// 数字(小数可)の直後に単位が続く最初の箇所を探す。
fn number_with_unit(text: &str, units: &[(&str, f64)]) -> Option<f64> {
    let t = half(text);
    let chars: Vec<(usize, char)> = t.char_indices().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].1.is_ascii_digit() {
            let start = chars[i].0;
            let mut j = i;
            while j < chars.len() && (chars[j].1.is_ascii_digit() || chars[j].1 == '.') {
                j += 1;
            }
            let end = if j < chars.len() { chars[j].0 } else { t.len() };
            let num: f64 = t[start..end].parse().unwrap_or(f64::NAN);
            let rest = t[end..].trim_start();
            for (unit, factor) in units {
                if rest.to_ascii_uppercase().starts_with(&unit.to_ascii_uppercase()) && num.is_finite() {
                    return Some(num * factor);
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    None
}

pub fn data_gb(name: &str) -> Option<f64> {
    number_with_unit(name, &[("GB", 1.0), ("MB", 1.0 / 1024.0)])
}

pub fn hours(text: &str) -> Option<f64> {
    number_with_unit(text, &[("時間", 1.0), ("日間", 24.0), ("日", 24.0), ("ヶ月", 720.0), ("か月", 720.0), ("カ月", 720.0)])
}

/// `parse::catalog` の結果(セクションの配列)を商品の平らな一覧にする。
pub fn products(sections: &Value) -> Vec<Product> {
    let mut out = Vec::new();
    for sec in sections.as_array().into_iter().flatten() {
        let section = sec.get("title").and_then(|v| v.as_str()).map(String::from);
        for p in sec.get("products").and_then(|v| v.as_array()).into_iter().flatten() {
            let Some(sku) = p.get("sku").and_then(|v| v.as_str()) else { continue };
            let name = p.get("name").and_then(|v| v.as_str()).unwrap_or(sku).to_string();
            let validity = p.get("validity").and_then(|v| v.as_str()).map(String::from);
            let price_text = p.get("price").and_then(|v| v.as_str()).map(String::from);
            let price = price_text.as_deref().and_then(price_yen);
            let unlimited = name.contains("使い放題") || section.as_deref().is_some_and(|s| s.contains("使い放題"));
            let gb = if unlimited { None } else { data_gb(&name) };
            let hrs = validity.as_deref().and_then(hours).or_else(|| hours(&name));
            let yen_per_gb = match (price, gb) {
                (Some(p), Some(g)) if g > 0.0 => Some((p as f64 / g * 10.0).round() / 10.0),
                _ => None,
            };
            out.push(Product {
                sku: sku.to_string(),
                name,
                section: section.clone(),
                validity,
                price_text,
                price_yen: price,
                requires_3ds: p.get("requires_3ds").and_then(|v| v.as_bool()).unwrap_or(false),
                data_gb: gb,
                hours: hrs,
                unlimited,
                yen_per_gb,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn amounts() {
        assert_eq!(data_gb("データ追加1GB(7日間)"), Some(1.0));
        assert_eq!(data_gb("データ追加20GB(30日間)"), Some(20.0));
        assert_eq!(data_gb("データ追加０．５ＧＢ"), Some(0.5));
        assert_eq!(data_gb("データ追加300MB"), Some(300.0 / 1024.0));
        assert_eq!(data_gb("データ使い放題(24時間)"), None);
        assert_eq!(hours("7日間"), Some(168.0));
        assert_eq!(hours("24時間"), Some(24.0));
        assert_eq!(hours("データ使い放題(1時間)"), Some(1.0));
        assert_eq!(hours("3ヶ月"), Some(2160.0));
    }

    #[test]
    fn flatten_mock() {
        let sections = crate::parse::catalog(crate::mock::DASHBOARD).unwrap();
        let ps = products(&sections);
        assert_eq!(ps.len(), 4);
        let one = ps.iter().find(|p| p.sku == "MOCK_DATA_1GB_7D").unwrap();
        assert_eq!(one.data_gb, Some(1.0));
        assert_eq!(one.hours, Some(168.0));
        assert_eq!(one.yen_per_gb, Some(390.0));
        let h1 = ps.iter().find(|p| p.sku == "MOCK_UNLIMITED_1H").unwrap();
        assert!(h1.unlimited);
        assert_eq!(h1.hours, Some(1.0));
        assert_eq!(h1.price_yen, Some(110));
        assert!(ps.iter().find(|p| p.sku == "MOCK_DATA_20GB_30D").unwrap().requires_3ds);
    }
}
