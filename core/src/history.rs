//! 残量の履歴と、減り方の予測。

use crate::jptime;
use crate::model::{UsageInsights, UsageSample};

const KEEP_MS: i64 = 14 * 24 * 3600 * 1000;
const MAX_SAMPLES: usize = 4000;
/// 同じ値なら、この間隔より短く記録しない。
const MIN_GAP_MS: i64 = 5 * 60 * 1000;
/// 増えた(購入・コード)とみなす量。
const TOPUP_KB: f64 = 1024.0;
/// 減り方を見る期間。
const WINDOW_MS: i64 = 6 * 3600 * 1000;

/// 新しい観測を履歴に足す(必要なときだけ)。
pub fn record(history: &mut Vec<UsageSample>, s: UsageSample) {
    if let Some(last) = history.last() {
        let same = (last.left_kb - s.left_kb).abs() < 64.0 && last.unlimited == s.unlimited;
        if s.t_ms < last.t_ms || (same && s.t_ms - last.t_ms < MIN_GAP_MS) {
            return;
        }
    }
    history.push(s);
    let cutoff = history.last().map(|l| l.t_ms - KEEP_MS).unwrap_or(0);
    history.retain(|x| x.t_ms >= cutoff);
    if history.len() > MAX_SAMPLES {
        let cut = history.len() - MAX_SAMPLES;
        history.drain(..cut);
    }
}

/// 期間内に使った量(減った分だけを足す。増えた分=購入は数えない)。
fn used_since(history: &[UsageSample], since_ms: i64) -> f64 {
    let mut used = 0.0;
    for w in history.windows(2) {
        if w[1].t_ms < since_ms || w[0].unlimited || w[1].unlimited {
            continue;
        }
        let d = w[0].left_kb - w[1].left_kb;
        if d > 0.0 {
            used += d;
        }
    }
    used
}

pub fn insights(history: &[UsageSample], now_ms: i64) -> UsageInsights {
    let used_today_kb = used_since(history, jptime::jst_midnight_ms(now_ms));
    let used_7d_kb = used_since(history, now_ms - 7 * 24 * 3600 * 1000);
    let empty = UsageInsights { kb_per_hour: None, hours_left: None, used_today_kb, used_7d_kb, window_hours: 0.0 };
    let Some(last) = history.last() else { return empty };
    if last.unlimited {
        return UsageInsights { kb_per_hour: Some(0.0), ..empty };
    }
    // 直近の「増えた」点(購入・コード適用)より後だけを見る。使い放題の区間も切れ目にする。
    let mut start = history.len() - 1;
    while start > 0 {
        let (a, b) = (&history[start - 1], &history[start]);
        if a.unlimited || b.left_kb - a.left_kb > TOPUP_KB || last.t_ms - a.t_ms > WINDOW_MS {
            break;
        }
        start -= 1;
    }
    let first = &history[start];
    let span_h = (last.t_ms - first.t_ms) as f64 / 3_600_000.0;
    if span_h < 0.33 {
        return empty;
    }
    let rate = ((first.left_kb - last.left_kb) / span_h).max(0.0);
    let hours_left = if rate > 1.0 { Some(last.left_kb / rate) } else { None };
    UsageInsights { kb_per_hour: Some(rate), hours_left, used_today_kb, used_7d_kb, window_hours: span_h }
}

/// モック用: グラフが空にならないよう、過去3日のそれらしい履歴を作る(昼に多く使う)。
pub fn seed_mock(history: &mut Vec<UsageSample>, now_ms: i64, left_now_kb: f64) {
    if !history.is_empty() {
        return;
    }
    let step = 30 * 60 * 1000;
    let n = 72 * 2;
    let mut left = left_now_kb;
    let mut points = Vec::with_capacity(n);
    for k in 0..n {
        let t = now_ms - (k as i64) * step;
        points.push(UsageSample { t_ms: t, left_kb: left, unlimited: false });
        // 時刻(日本時間)で使い方を変える
        let hour = ((t / 1000 + 9 * 3600).rem_euclid(86_400) / 3600) as i64;
        let per_30min_kb = match hour {
            0..=6 => 2_000.0,
            7..=9 => 40_000.0,
            12..=13 => 60_000.0,
            18..=23 => 55_000.0,
            _ => 15_000.0,
        };
        left += per_30min_kb;
    }
    points.reverse();
    history.extend(points);
}

#[cfg(test)]
mod tests {
    use super::*;

    const H: i64 = 3_600_000;

    fn s(t_h: f64, gb: f64) -> UsageSample {
        UsageSample { t_ms: (t_h * H as f64) as i64, left_kb: gb * 1_048_576.0, unlimited: false }
    }

    #[test]
    fn rate_and_hours_left() {
        let h = vec![s(0.0, 10.0), s(1.0, 9.0), s(2.0, 8.0)];
        let i = insights(&h, 2 * H);
        assert!((i.kb_per_hour.unwrap() - 1_048_576.0).abs() < 1.0);
        assert!((i.hours_left.unwrap() - 8.0).abs() < 0.01);
    }

    #[test]
    fn topup_resets_window() {
        let h = vec![s(0.0, 1.0), s(1.0, 0.5), s(1.5, 3.5), s(2.5, 3.0)];
        let i = insights(&h, (2.5 * H as f64) as i64);
        // 購入(0.5→3.5)より後の 1時間で 0.5GB
        assert!((i.kb_per_hour.unwrap() - 524_288.0).abs() < 1.0);
        assert!((i.hours_left.unwrap() - 6.0).abs() < 0.01);
        // 使った量には購入の増加を含めない
        assert!((i.used_7d_kb - 1_048_576.0).abs() < 1.0);
    }

    #[test]
    fn not_enough_data_or_flat() {
        assert!(insights(&[], 0).kb_per_hour.is_none());
        assert!(insights(&[s(0.0, 1.0), s(0.1, 0.9)], H / 10).kb_per_hour.is_none());
        let flat = insights(&[s(0.0, 1.0), s(2.0, 1.0)], 2 * H);
        assert_eq!(flat.kb_per_hour, Some(0.0));
        assert!(flat.hours_left.is_none());
    }

    #[test]
    fn record_dedupes() {
        let mut h = vec![];
        record(&mut h, s(0.0, 1.0));
        record(&mut h, s(0.01, 1.0)); // 同じ値で近すぎる
        record(&mut h, s(0.02, 0.9)); // 値が変わった
        record(&mut h, s(0.01, 0.8)); // 時間が戻った
        assert_eq!(h.len(), 2);
    }

    #[test]
    fn mock_seed_is_plausible() {
        let mut h = vec![];
        seed_mock(&mut h, 100 * H, 5.0 * 1_048_576.0);
        assert_eq!(h.len(), 144);
        assert!(h.windows(2).all(|w| w[0].t_ms < w[1].t_ms && w[0].left_kb >= w[1].left_kb));
        assert_eq!(h.last().unwrap().left_kb, 5.0 * 1_048_576.0);
        let i = insights(&h, 100 * H);
        assert!(i.kb_per_hour.unwrap() > 0.0);
    }
}
