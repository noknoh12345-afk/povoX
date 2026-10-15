//! 日本時間(UTC+9、夏時間なし)の年月日。月の上限・1日の回数の区切りに使う。

/// エポックミリ秒 → 日本時間の (年, 月, 日)。
pub fn jst_ymd(ms: i64) -> (i64, u32, u32) {
    let secs = ms.div_euclid(1000) + 9 * 3600;
    civil_from_days(secs.div_euclid(86_400))
}

/// Howard Hinnant の days_from_civil の逆。
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jst_dates() {
        assert_eq!(jst_ymd(0), (1970, 1, 1));
        // 2026-10-14T15:00:00Z は日本時間 10/15 0:00
        assert_eq!(jst_ymd(1_791_990_000_000), (2026, 10, 15));
        assert_eq!(jst_ymd(1_791_989_999_000), (2026, 10, 14));
        // 2024-02-29 閏日(日本時間正午)
        assert_eq!(jst_ymd(1_709_175_600_000), (2024, 2, 29));
    }
}
