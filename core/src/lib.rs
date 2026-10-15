//! povoX の中身(Rust)。iOS アプリからは C の関数2つ(`povo_auto_call` / `povo_auto_free`)
//! だけを呼び、要求も応答も JSON 文字列でやり取りする。
//!
//! 要求: `{"op": "...", ...引数}`
//! 応答: `{"ok": true, "result": ...}` または `{"ok": false, "error": {message, povo_status, povo_code, hint, block_until_ms, halt}}`
//!       本番でセッションが変わったときは `"session": {"save": {...}}` / `{"clear": true}` が付く
//!       (アプリはそれをキーチェーンに反映する)。

mod backend;
mod engine;
mod mock;
mod parse;
mod protocol;
mod timeutil;

use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

use serde_json::{json, Value};

pub use backend::Failure;
pub use engine::{Engine, SessionEvent, Stored};

/// エンジンは1つだけ。Mutex で povo への通信を常に1本ずつにする
/// (画面・スクリプト・バックグラウンド・ショートカットが同時に呼んでも直列になる)。
static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

fn err(f: Failure) -> Value {
    json!({ "ok": false, "error": f })
}

/// JSON の要求を1つ処理して JSON の応答を返す。
pub fn handle_json(input: &str) -> String {
    let req: Value = match serde_json::from_str(input) {
        Ok(v) => v,
        Err(e) => return err(Failure::local(format!("要求を読めません: {e}"))).to_string(),
    };
    let op = req.get("op").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let mut guard = ENGINE.lock().unwrap_or_else(|e| e.into_inner());

    if op == "init" {
        let Some(dir) = req.get("dir").and_then(|v| v.as_str()) else {
            return err(Failure::local("init には dir が必要です")).to_string();
        };
        let mock = req.get("mock").and_then(|v| v.as_bool()).unwrap_or(false);
        let session: Option<Stored> = req.get("session").cloned().and_then(|v| serde_json::from_value(v).ok());
        let mut engine = Engine::open(dir, mock, session);
        let status = engine.handle("status", &json!({}));
        *guard = Some(engine);
        return match status {
            Ok(v) => json!({ "ok": true, "result": v }).to_string(),
            Err(f) => err(f).to_string(),
        };
    }

    let Some(engine) = guard.as_mut() else {
        return err(Failure::local("エンジンが初期化されていません")).to_string();
    };
    let mut out = match engine.handle(&op, &req) {
        Ok(v) => json!({ "ok": true, "result": v }),
        Err(f) => err(f),
    };
    match engine.take_session_event() {
        Some(SessionEvent::Save(s)) => out["session"] = json!({ "save": s }),
        Some(SessionEvent::Clear) => out["session"] = json!({ "clear": true }),
        None => {}
    }
    out.to_string()
}

/// # Safety
/// `req` は NUL 終端の UTF-8 文字列。戻り値は必ず `povo_auto_free` で解放すること。
#[no_mangle]
pub unsafe extern "C" fn povo_auto_call(req: *const c_char) -> *mut c_char {
    let out = std::panic::catch_unwind(|| {
        if req.is_null() {
            return err(Failure::local("要求が空です")).to_string();
        }
        let input = CStr::from_ptr(req).to_string_lossy().into_owned();
        handle_json(&input)
    })
    .unwrap_or_else(|_| err(Failure::local("内部エラー(panic)")).to_string());
    CString::new(out).unwrap_or_default().into_raw()
}

/// # Safety
/// `povo_auto_call` が返したポインタだけを渡すこと。
#[no_mangle]
pub unsafe extern "C" fn povo_auto_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_roundtrip() {
        let dir = std::env::temp_dir().join(format!("povo-auto-ffi-{}", rand::random::<u64>()));
        let init = json!({"op": "init", "dir": dir, "mock": true}).to_string();
        let c = CString::new(init).unwrap();
        let out = unsafe { povo_auto_call(c.as_ptr()) };
        let s = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { povo_auto_free(out) };
        let v: Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["result"]["mock"], true);
        let v: Value = serde_json::from_str(&handle_json(r#"{"op":"nope"}"#)).unwrap();
        assert_eq!(v["ok"], false);
        let v: Value = serde_json::from_str(&handle_json("not json")).unwrap();
        assert_eq!(v["ok"], false);
    }
}
