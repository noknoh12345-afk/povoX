//! ルール(JavaScript)に渡す材料。JS で扱いやすいよう camelCase・GB/MB 単位にする。
//! 電池・ネットワーク・時刻などの端末の情報はアプリ側が足す。

use serde_json::{json, Value};

use crate::backend::R;
use crate::engine::{local, Engine, GB};
use crate::model::*;

fn round(x: f64, digits: i32) -> f64 {
    let p = 10f64.powi(digits);
    (x * p).round() / p
}

pub(crate) fn product_js(p: &Product) -> Value {
    json!({
        "sku": p.sku,
        "name": p.name,
        "section": p.section,
        "validity": p.validity,
        "price": p.price_yen,
        "priceText": p.price_text,
        "requires3ds": p.requires_3ds,
        "gb": p.data_gb,
        "hours": p.hours,
        "unlimited": p.unlimited,
        "yenPerGB": p.yen_per_gb,
    })
}

impl Engine {
    /// ルールの `ctx` のうち、エンジンが知っている部分。
    /// 本番・試運転では残量を取得する(30秒以内なら前回の値)。シミュレーションでは通信しない。
    pub fn rule_context(&mut self, mode: RunMode, sim: Option<SimInput>) -> R<Value> {
        if !self.logged_in() {
            return Err(local("ログインしていません。"));
        }
        self.prune_pending();
        let now = self.now();
        let snap = match mode {
            RunMode::Simulate => self.st.snapshot.clone(),
            _ => Some(self.snapshot(false)?),
        };
        let ins = self.insights();
        let mut left_kb = snap.as_ref().and_then(|s| s.left_kb);
        let mut unl_active = snap.as_ref().and_then(|s| s.unlimited.active);
        let mut unl_until = snap.as_ref().and_then(|s| s.unlimited.until_ms);
        let mut hours_left = ins.hours_left;
        if let (RunMode::Simulate, Some(s)) = (mode, &sim) {
            left_kb = Some(s.left_kb.max(0.0));
            unl_active = Some(s.unlimited);
            unl_until = if s.unlimited { s.unlimited_hours_left.map(|h| now + (h * 3_600_000.0) as i64) } else { None };
            hours_left = s.hours_left;
        }
        let buckets: Vec<Value> = snap
            .as_ref()
            .map(|s| {
                s.buckets
                    .iter()
                    .map(|b| {
                        json!({
                            "key": b.key, "label": b.label,
                            "leftGB": round(b.left_kb / GB, 3), "usedGB": round(b.used_kb / GB, 3),
                            "planGB": b.plan_kb.map(|p| round(p / GB, 3)),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let toppings: Vec<Value> = snap
            .as_ref()
            .and_then(|s| s.toppings.as_ref())
            .map(|ts| {
                ts.iter()
                    .map(|t| json!({"section": t.section, "name": t.name, "remaining": t.remaining, "expiry": t.expiry, "expiryMs": t.expiry_ms}))
                    .collect()
            })
            .unwrap_or_default();
        let codes: Vec<Value> = self
            .st
            .codes
            .iter()
            .filter(|c| c.status == CodeStatus::Pending)
            .map(|c| json!({"id": c.id, "tag": c.tag, "note": c.note, "masked": crate::engine::mask(&c.code)}))
            .collect();
        let b = self.budget();
        let s = &self.st.settings;
        let mode_str = |m: ActionMode| match m {
            ActionMode::Off => "off",
            ActionMode::Confirm => "confirm",
            ActionMode::Auto => "auto",
        };
        let last = self.st.runs.last().map(|r| json!({"ms": r.started_ms, "summary": r.summary, "trigger": r.trigger}));
        Ok(json!({
            "mode": match mode { RunMode::Live => "live", RunMode::Dry => "dry", RunMode::Simulate => "simulate" },
            "data": {
                "leftKB": left_kb,
                "leftMB": left_kb.map(|k| round(k / 1024.0, 1)),
                "leftGB": left_kb.map(|k| round(k / GB, 3)),
                "planGB": snap.as_ref().and_then(|s| s.plan_kb).map(|p| round(p / GB, 3)),
                "buckets": buckets,
                "toppings": toppings,
                "toppingsReadable": snap.as_ref().map(|s| s.toppings.is_some()).unwrap_or(false),
                "unlimited": {
                    "active": unl_active,
                    "name": snap.as_ref().and_then(|s| s.unlimited.name.clone()),
                    "untilMs": unl_until,
                    "hoursLeft": unl_until.map(|u| round(((u - now) as f64 / 3_600_000.0).max(0.0), 2)),
                },
                "fetchedMs": snap.as_ref().map(|s| s.fetched_ms),
                "cached": snap.as_ref().map(|s| s.cached).unwrap_or(true),
            },
            "forecast": {
                "mbPerHour": ins.kb_per_hour.map(|k| round(k / 1024.0, 1)),
                "hoursLeft": hours_left.map(|h| round(h, 2)),
                "usedTodayMB": round(ins.used_today_kb / 1024.0, 1),
                "used7dMB": round(ins.used_7d_kb / 1024.0, 1),
            },
            "codes": codes,
            "budget": {
                "capYen": b.cap_yen, "spentYen": b.rule_spent_yen, "remainingYen": b.remaining_yen,
                "todayCount": b.rule_orders_today, "maxPerDay": b.max_per_day,
            },
            "settings": {
                "purchaseMode": mode_str(s.purchase_mode),
                "codeMode": mode_str(s.code_mode),
                "dryRun": s.dry_run,
            },
            "pending": self.st.pending.iter().map(|p| json!({"kind": p.kind, "label": p.label})).collect::<Vec<_>>(),
            "lastRun": last,
        }))
    }

    /// ルールの `ctx.catalog()` 用。シミュレーションでは手元の一覧だけ。
    pub fn rule_catalog(&mut self, mode: RunMode) -> R<Value> {
        let cat = match mode {
            RunMode::Simulate => self.st.catalog.clone().unwrap_or(Catalog { fetched_ms: 0, products: vec![] }),
            _ => self.catalog(false)?,
        };
        Ok(Value::Array(cat.products.iter().map(product_js).collect()))
    }
}
