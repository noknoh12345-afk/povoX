//! JSON でエンジンを呼ぶ入口。
//! - ルールの JavaScript からは `script_call`(読み取りとログだけ。購入・コードは計画で返す)。
//! - 開発用 CLI・パソコン上のテストからは `dev_call`(全部)。

use serde::Serialize;
use serde_json::{json, Value};

use crate::backend::{Failure, R};
use crate::engine::Engine;
use crate::model::*;

fn ok<T: Serialize>(v: T) -> R<Value> {
    serde_json::to_value(v).map_err(|e| Failure::local(format!("内部エラー: {e}")))
}

fn s(args: &Value, key: &str) -> Option<String> {
    args.get(key).and_then(|v| v.as_str()).map(String::from)
}

fn b(args: &Value, key: &str) -> bool {
    args.get(key).and_then(|v| v.as_bool()).unwrap_or(false)
}

fn mode(args: &Value) -> RunMode {
    match args.get("mode").and_then(|v| v.as_str()) {
        Some("simulate") => RunMode::Simulate,
        Some("dry") => RunMode::Dry,
        _ => RunMode::Live,
    }
}

fn envelope(r: R<Value>) -> String {
    match r {
        Ok(v) => json!({"ok": true, "result": v}).to_string(),
        Err(f) => json!({"ok": false, "error": f}).to_string(),
    }
}

/// ルールの JavaScript から呼べる操作(読み取りとログだけ)。
pub fn script_call(e: &mut Engine, op: &str, args_json: &str) -> String {
    let args: Value = serde_json::from_str(args_json).unwrap_or(Value::Null);
    envelope(match op {
        "catalog" => e.rule_catalog(mode(&args)),
        "log" => {
            let level = match s(&args, "level").as_deref() {
                Some("warn") => LogLevel::Warn,
                Some("error") => LogLevel::Error,
                Some("action") => LogLevel::Action,
                _ => LogLevel::Info,
            };
            let msg: String = s(&args, "message").unwrap_or_default().chars().take(500).collect();
            e.log(level, msg);
            Ok(Value::Null)
        }
        other => Err(Failure::local(format!("ルールからは使えない操作です: {other}"))),
    })
}

/// 開発用: すべての操作を JSON で。
pub fn dev_call(e: &mut Engine, op: &str, args: &Value) -> String {
    let r: R<Value> = match op {
        "status" => ok(e.status()),
        "login_start" => e.login_start(s(args, "email"), s(args, "phone")).and_then(ok),
        "login_otp" => e.login_otp(&s(args, "code").unwrap_or_default()).and_then(ok),
        "logout" => {
            e.logout();
            Ok(Value::Null)
        }
        "unhalt" => {
            e.unhalt();
            Ok(Value::Null)
        }
        "snapshot" => e.snapshot(b(args, "force")).and_then(ok),
        "insights" => ok(e.insights()),
        "history" => ok(e.history(args.get("hours").and_then(|v| v.as_u64()).unwrap_or(72) as u32)),
        "catalog" => e.catalog(b(args, "force")).and_then(ok),
        "purchase_history" => e.purchase_history().and_then(ok),
        "order" => e.order_manual(&s(args, "sku").unwrap_or_default(), &s(args, "confirm").unwrap_or_default()).and_then(ok),
        "codes" => ok(e.codes()),
        "codes_add" => ok(e.add_codes(&s(args, "text").unwrap_or_default(), s(args, "tag"))),
        "apply_code" => e.apply_code_manual(s(args, "id"), s(args, "code"), &s(args, "confirm").unwrap_or_default()).and_then(ok),
        "settings" => ok(e.settings()),
        "settings_set" => {
            let mut cur = serde_json::to_value(e.settings()).unwrap_or(Value::Null);
            if let (Value::Object(c), Value::Object(a)) = (&mut cur, args) {
                for (k, v) in a {
                    if c.contains_key(k) {
                        c.insert(k.clone(), v.clone());
                    }
                }
            }
            match serde_json::from_value::<Settings>(cur) {
                Ok(st) => ok(e.update_settings(st)),
                Err(err) => Err(Failure::local(format!("設定を読めません: {err}"))),
            }
        }
        "budget" => ok(e.budget()),
        "ledger" => ok(e.ledger(100)),
        "logs" => ok(e.logs(args.get("limit").and_then(|v| v.as_u64()).unwrap_or(50) as u32)),
        "rule_context" => {
            let sim = args.get("sim").cloned().and_then(|v| serde_json::from_value::<SimInput>(v).ok());
            e.rule_context(mode(args), sim)
        }
        "execute_run" => match serde_json::from_value::<RunInput>(args.clone()) {
            Ok(input) => ok(e.execute_run(input)),
            Err(err) => Err(Failure::local(format!("RunInput を読めません: {err}"))),
        },
        "runs" => ok(e.runs(50)),
        "pending" => ok(e.pending_actions()),
        "confirm_pending" => e.confirm_pending(&s(args, "id").unwrap_or_default()).and_then(ok),
        "dismiss_pending" => {
            e.dismiss_pending(&s(args, "id").unwrap_or_default());
            Ok(Value::Null)
        }
        "next_check" => ok(e.next_check_delay_min()),
        // ルールと同じ入口も通す
        "script" => {
            let inner = s(args, "op").unwrap_or_default();
            let a = args.get("args").cloned().unwrap_or(Value::Null).to_string();
            return script_call(e, &inner, &a);
        }
        other => Err(Failure::local(format!("不明な操作: {other}"))),
    };
    e.save();
    envelope(r)
}
