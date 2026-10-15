//! 日本時間(UTC+9、夏時間なし)の暦と、povo の画面にある日本語の日時の読み取り。

const JST_OFFSET_S: i64 = 9 * 3600;

/// エポックミリ秒 → 日本時間の (年, 月, 日)。
pub fn jst_ymd(ms: i64) -> (i64, u32, u32) {
    let secs = ms.div_euclid(1000) + JST_OFFSET_S;
    civil_from_days(secs.div_euclid(86_400))
}

/// 日本時間のその日の 0:00 のエポックミリ秒。
pub fn jst_midnight_ms(ms: i64) -> i64 {
    let secs = ms.div_euclid(1000) + JST_OFFSET_S;
    (secs.div_euclid(86_400) * 86_400 - JST_OFFSET_S) * 1000
}

/// 日本時間の (年, 月, 日, 時, 分) → エポックミリ秒。
pub fn jst_to_ms(y: i64, m: u32, d: u32, hour: u32, minute: u32) -> i64 {
    let days = days_from_civil(y, m, d);
    (days * 86_400 + hour as i64 * 3600 + minute as i64 * 60 - JST_OFFSET_S) * 1000
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 文字列から、指定の記号の直前にある数字を読む("2026年" の 2026 など)。探し始め位置も返す。
fn number_before(text: &str, from: usize, marker: char) -> Option<(i64, usize)> {
    let rest = &text[from..];
    let pos = rest.find(marker)?;
    let before = &rest[..pos];
    let digits: String = before.chars().rev().skip_while(|c| c.is_whitespace()).take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    let n: i64 = digits.chars().rev().collect::<String>().parse().ok()?;
    Some((n, from + pos + marker.len_utf8()))
}

/// "2026年 10月 20日 午後11:59\n残り 6 日間" → 日本時間として解釈したエポックミリ秒。
/// 時刻が無ければその日の 23:59。読めなければ None。
pub fn parse_jp_datetime(text: &str) -> Option<i64> {
    let (y, i) = number_before(text, 0, '年')?;
    let (m, i) = number_before(text, i, '月')?;
    let (d, i) = number_before(text, i, '日')?;
    if !(2000..=2100).contains(&y) || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // 日付の後ろ(同じ行)から時刻を探す
    let tail = text[i..].lines().next().unwrap_or("");
    let pm = tail.contains("午後") || tail.to_ascii_uppercase().contains("PM");
    let am = tail.contains("午前") || tail.to_ascii_uppercase().contains("AM");
    let (mut hour, mut minute) = (23u32, 59u32);
    if let Some(colon) = tail.find(':') {
        let h: String = tail[..colon].chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect();
        let mi: String = tail[colon + 1..].chars().take_while(|c| c.is_ascii_digit()).collect();
        if let (Ok(h), Ok(mi)) = (h.parse::<u32>(), mi.parse::<u32>()) {
            if h <= 23 && mi <= 59 {
                hour = h;
                minute = mi;
                if pm && hour < 12 {
                    hour += 12;
                }
                if am && hour == 12 {
                    hour = 0;
                }
            }
        }
    }
    Some(jst_to_ms(y, m as u32, d as u32, hour, minute))
}

/// エポックミリ秒 → povo の画面と同じ書き方("2026年 10月 20日 午後11:59")。モック用。
pub fn format_jp_datetime(ms: i64) -> String {
    let (y, m, d) = jst_ymd(ms);
    let secs = (ms.div_euclid(1000) + JST_OFFSET_S).rem_euclid(86_400);
    let (h, mi) = ((secs / 3600) as u32, ((secs % 3600) / 60) as u32);
    let (ampm, h12) = if h < 12 { ("午前", if h == 0 { 12 } else { h }) } else { ("午後", if h == 12 { 12 } else { h - 12 }) };
    format!("{y}年 {m}月 {d}日 {ampm}{h12}:{mi:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jst_dates() {
        assert_eq!(jst_ymd(0), (1970, 1, 1));
        assert_eq!(jst_ymd(1_791_990_000_000), (2026, 10, 15));
        assert_eq!(jst_ymd(1_791_989_999_000), (2026, 10, 14));
        assert_eq!(jst_ymd(1_709_175_600_000), (2024, 2, 29));
        assert_eq!(jst_midnight_ms(1_792_000_000_000), 1_791_990_000_000);
    }

    #[test]
    fn roundtrip_days() {
        for ms in [0i64, 951_782_400_000, 1_709_175_600_000, 1_792_000_000_000, 4_102_444_800_000] {
            let (y, m, d) = jst_ymd(ms);
            let back = jst_to_ms(y, m, d, 0, 0);
            assert_eq!(jst_ymd(back), (y, m, d));
        }
    }

    #[test]
    fn povo_expiry_texts() {
        let t = parse_jp_datetime("2026年 10月 20日 午後11:59\n残り 6 日間").unwrap();
        assert_eq!(format_jp_datetime(t), "2026年 10月 20日 午後11:59");
        let t = parse_jp_datetime("2026年 1月 2日 午前0:05").unwrap();
        assert_eq!(format_jp_datetime(t), "2026年 1月 2日 午前12:05");
        let t = parse_jp_datetime("2026年 11月 1日").unwrap();
        assert_eq!(format_jp_datetime(t), "2026年 11月 1日 午後11:59");
        let t = parse_jp_datetime("2026年 3月 4日 13:30").unwrap();
        assert_eq!(format_jp_datetime(t), "2026年 3月 4日 午後1:30");
        assert_eq!(parse_jp_datetime("残り 6 日間"), None);
        assert_eq!(parse_jp_datetime("不明"), None);
    }
}
