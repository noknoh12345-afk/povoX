//! エンジン全体のテスト(モック。povo には通信しない)。

use serde_json::{json, Value};

use crate::engine::{mask, Engine, GB};
use crate::model::*;
use crate::store::{MemoryStore, SessionStore};

const T0: i64 = 1_792_000_000_000; // 2026-10-14 頃

fn config(dir: &std::path::Path, scenario: &str) -> EngineConfig {
    EngineConfig { dir: dir.to_string_lossy().into(), mock: true, mock_scenario: scenario.into() }
}

fn tempdir() -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("povox-test-{}", rand::random::<u64>()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn engine(scenario: &str) -> (Engine, std::path::PathBuf) {
    let dir = tempdir();
    let mut e = Engine::open(&config(&dir, scenario), Box::new(MemoryStore::default()));
    e.clock = Some(T0);
    (e, dir)
}

fn login(e: &mut Engine) {
    e.login_start(Some("a@example.com".into()), None).unwrap();
    assert!(e.login_otp("000000").unwrap().done);
}

fn run(e: &mut Engine, mode: RunMode, plan: Value) -> RunRecord {
    e.execute_run(RunInput {
        trigger: "test".into(),
        mode,
        battery_level: Some(50),
        charging: false,
        network: "cellular".into(),
        plan_json: Some(plan.to_string()),
        error: None,
        script_logs: vec![],
        sim: None,
    })
}

fn set(e: &mut Engine, f: impl FnOnce(&mut Settings)) {
    let mut s = e.settings();
    f(&mut s);
    e.update_settings(s);
}

fn status_of(r: &RunRecord, kind: ActionKind) -> Vec<OutcomeStatus> {
    r.outcomes.iter().filter(|o| o.kind == kind).map(|o| o.status).collect()
}

#[test]
fn login_snapshot_and_history() {
    let (mut e, dir) = engine("");
    assert!(e.snapshot(false).is_err());
    login(&mut e);
    let s = e.snapshot(false).unwrap();
    assert!(s.left_kb.unwrap() > 17.0 * GB);
    assert_eq!(s.unlimited.active, Some(false));
    assert!(s.toppings.as_ref().unwrap().iter().any(|t| t.expiry_ms.is_some()));
    assert!(!s.cached);
    assert!(e.snapshot(false).unwrap().cached);
    // モックは過去3日分の履歴を作る → 予測が出る
    let ins = e.insights();
    assert!(ins.kb_per_hour.unwrap() > 0.0);
    assert!(ins.hours_left.unwrap() > 1.0);
    assert!(e.history(72).len() > 100);
    // セッションと状態は保存され、開き直しても残る(アプリからの呼び出しは毎回保存される)
    e.save();
    let e2 = Engine::open(&config(&dir, ""), Box::new(MemoryStore::default()));
    assert!(e2.logged_in());
    assert!(e2.cached_snapshot().is_some());
}

#[test]
fn real_session_goes_to_store() {
    // 本番(mock=false)ではセッションをアプリの保存先に渡す。ここでは通信しない範囲だけ確かめる。
    let dir = tempdir();
    let store = std::sync::Arc::new(MemoryStore::default());
    struct Shared(std::sync::Arc<MemoryStore>);
    impl SessionStore for Shared {
        fn load(&self) -> Option<StoredSession> {
            self.0.load()
        }
        fn save(&self, s: StoredSession) {
            self.0.save(s)
        }
        fn clear(&self) {
            self.0.clear()
        }
    }
    store.save(StoredSession { device_id: "d".into(), auth_token: "t".into(), sin: None, identifier: "x@y".into() });
    let mut e = Engine::open(&EngineConfig { dir: dir.to_string_lossy().into(), mock: false, mock_scenario: String::new() }, Box::new(Shared(store.clone())));
    assert!(e.logged_in());
    assert_eq!(e.status().identifier.as_deref(), Some("x@y"));
    e.logout();
    assert!(store.load().is_none());
}

#[test]
fn skip_and_notify() {
    let (mut e, _) = engine("");
    login(&mut e);
    let r = run(&mut e, RunMode::Live, json!({"type": "skip", "reason": "Wi-Fi なので何もしない"}));
    assert_eq!(r.summary, "Wi-Fi なので何もしない");
    let r = run(&mut e, RunMode::Live, json!({"type": "notify", "title": "残りわずか", "body": "300MB"}));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::Notified);
    assert_eq!(r.outcomes[0].body.as_deref(), Some("300MB"));
    assert_eq!(e.runs(10).len(), 2);
}

#[test]
fn bad_plans_are_errors_not_crashes() {
    let (mut e, _) = engine("");
    login(&mut e);
    let r = run(&mut e, RunMode::Live, json!({"type": "explode"}));
    assert!(r.error.is_some());
    let deep = (0..12).fold(json!({"type": "skip"}), |acc, _| json!({"type": "firstOf", "items": [acc]}));
    assert!(run(&mut e, RunMode::Live, deep).error.unwrap().contains("大きすぎ"));
    let r = e.execute_run(RunInput {
        trigger: "t".into(),
        mode: RunMode::Live,
        battery_level: None,
        charging: false,
        network: "wifi".into(),
        plan_json: None,
        error: Some("ReferenceError: x is not defined(3行目)".into()),
        script_logs: vec!["a".into()],
        sim: None,
    });
    assert!(r.summary.starts_with("実行できませんでした"));
    assert_eq!(r.logs, vec!["a".to_string()]);
}

#[test]
fn confirm_mode_queues_then_executes_on_confirm() {
    let (mut e, _) = engine("low");
    login(&mut e);
    e.catalog(false).unwrap();
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_1H"}));
    assert_eq!(status_of(&r, ActionKind::Buy), vec![OutcomeStatus::Queued]);
    assert!(r.summary.contains("確認待ち"));
    let pid = r.outcomes[0].pending_id.clone().unwrap();
    assert_eq!(e.pending_actions().len(), 1);
    assert!(e.ledger(10).is_empty(), "確認前には何も送らない");
    // 同じ種類の確認待ちがある間は重ねて出さない
    let r2 = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_24H"}));
    assert_eq!(status_of(&r2, ActionKind::Buy), vec![OutcomeStatus::Refused]);
    // 実行
    let o = e.confirm_pending(&pid).unwrap();
    assert_eq!(o.status, OutcomeStatus::Done, "{}", o.message);
    assert_eq!(e.ledger(10)[0].source, OrderSource::Rule);
    assert_eq!(e.budget().rule_spent_yen, 110);
    // 記録の結果も「実行」に変わる
    let run_rec = e.runs(10).into_iter().find(|x| x.id == r.id).unwrap();
    assert_eq!(run_rec.outcomes[0].status, OutcomeStatus::Done);
    assert!(run_rec.summary.contains("購入しました"), "{}", run_rec.summary);
    // 2回目の確認はできない
    assert!(e.confirm_pending(&pid).is_err());
    // 使い放題が反映される
    e.clock = Some(T0 + 60_000);
    let s = e.snapshot(true).unwrap();
    assert_eq!(s.unlimited.active, Some(true));
    assert!(s.unlimited.until_ms.is_some());
}

#[test]
fn pending_expires_and_dismiss() {
    let (mut e, _) = engine("low");
    login(&mut e);
    e.catalog(false).unwrap();
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_1H"}));
    let pid = r.outcomes[0].pending_id.clone().unwrap();
    e.clock = Some(T0 + 31 * 60_000);
    assert!(e.pending_actions().is_empty());
    assert!(e.confirm_pending(&pid).is_err());
    let rec = e.runs(10).into_iter().find(|x| x.id == r.id).unwrap();
    assert_eq!(rec.outcomes[0].status, OutcomeStatus::Skipped);
    // 取り消し
    e.add_codes("MOCKOK1", None);
    let r = run(&mut e, RunMode::Live, json!({"type": "applyCode"}));
    let pid = r.outcomes[0].pending_id.clone().unwrap();
    e.dismiss_pending(&pid);
    assert!(e.pending_actions().is_empty());
    assert_eq!(e.codes()[0].status, CodeStatus::Pending, "取り消したコードは未使用のまま");
}

#[test]
fn auto_mode_policy_budget_day_gap_3ds() {
    let (mut e, _) = engine("low");
    login(&mut e);
    set(&mut e, |s| {
        s.purchase_mode = ActionMode::Auto;
        s.monthly_cap_yen = 400;
        s.max_rule_orders_per_day = 5;
        s.order_gap_min = 0;
    });
    // 3DS が要る商品・一覧に無い商品は断る(送らない)
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_DATA_20GB_30D"}));
    assert!(r.outcomes[0].message.contains("3Dセキュア"));
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "NOPE"}));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::Refused);
    // 330円は通る
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_24H"}));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::Done, "{}", r.outcomes[0].message);
    // 110円は上限を超える
    e.clock = Some(T0 + 200_000);
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_1H"}));
    assert!(r.outcomes[0].message.contains("上限"), "{}", r.outcomes[0].message);
    // 1日の回数・間隔
    set(&mut e, |s| {
        s.monthly_cap_yen = 5000;
        s.max_rule_orders_per_day = 1;
    });
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_1H"}));
    assert!(r.outcomes[0].message.contains("今日"), "{}", r.outcomes[0].message);
    set(&mut e, |s| {
        s.max_rule_orders_per_day = 5;
        s.order_gap_min = 30;
    });
    let r = run(&mut e, RunMode::Live, json!({"type": "buy", "sku": "MOCK_UNLIMITED_1H"}));
    assert!(r.outcomes[0].message.contains("分経って"), "{}", r.outcomes[0].message);
    // 手動購入は上限の外
    e.clock = Some(T0 + 400_000);
    assert!(e.order_manual("MOCK_DATA_1GB_7D", "購入する").is_ok());
    assert_eq!(e.budget().rule_spent_yen, 330);
    assert_eq!(e.budget().all_spent_yen, 720);
}

#[test]
fn one_spending_action_per_run_and_first_of() {
    let (mut e, _) = engine("low");
    login(&mut e);
    set(&mut e, |s| {
        s.purchase_mode = ActionMode::Auto;
        s.code_mode = ActionMode::Auto;
        s.order_gap_min = 0;
    });
    e.add_codes("MOCKUSED1 a\nMOCKOK1 b", None);
    // firstOf: 使用済みコード(受け付けられない)→ 次のコード → ここで終わる(購入はしない)
    let plan = json!({"type": "firstOf", "items": [
        {"type": "applyCode", "tag": "a"},
        {"type": "applyCode", "tag": "b"},
        {"type": "buy", "sku": "MOCK_UNLIMITED_1H"},
        {"type": "notify", "title": "x"}
    ]});
    let r = run(&mut e, RunMode::Live, plan.clone());
    assert_eq!(status_of(&r, ActionKind::ApplyCode), vec![OutcomeStatus::Refused, OutcomeStatus::Refused]);
    // 2件目は15秒の間隔で断られ、購入に進む
    assert_eq!(status_of(&r, ActionKind::Buy), vec![OutcomeStatus::Done]);
    assert!(status_of(&r, ActionKind::Notify).is_empty());
    // all: 購入・コードは1回の実行で1つまで
    e.clock = Some(T0 + 300_000);
    let r = run(&mut e, RunMode::Live, json!({"type": "all", "items": [
        {"type": "applyCode", "tag": "b"},
        {"type": "buy", "sku": "MOCK_DATA_1GB_7D"},
        {"type": "notify", "title": "done"}
    ]}));
    assert_eq!(status_of(&r, ActionKind::ApplyCode), vec![OutcomeStatus::Refused], "使い放題中なので送らない");
    assert_eq!(status_of(&r, ActionKind::Buy), vec![OutcomeStatus::Done]);
    assert_eq!(status_of(&r, ActionKind::Notify), vec![OutcomeStatus::Notified]);
}

#[test]
fn codes_respect_unlimited_and_cooldown() {
    let (mut e, _) = engine("low");
    login(&mut e);
    set(&mut e, |s| s.code_mode = ActionMode::Auto);
    let added = e.add_codes("mockok1 1gb 7日\nMOCKOK2,unl\nbad!code\n# メモ\nMOCKOK1", None);
    assert_eq!(added.added, 2);
    assert_eq!(added.duplicates.len(), 1);
    assert_eq!(added.invalid.len(), 1);
    let r = run(&mut e, RunMode::Live, json!({"type": "applyCode", "tag": "1GB"}));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::Done, "{}", r.outcomes[0].message);
    assert_eq!(e.codes()[0].status, CodeStatus::Applied);
    // 15秒は空ける
    let r = run(&mut e, RunMode::Live, json!({"type": "applyCode"}));
    assert!(r.outcomes[0].message.contains("15秒"));
    // 使い放題中は送らない
    e.clock = Some(T0 + 20_000);
    e.order_manual("MOCK_UNLIMITED_1H", "購入する").unwrap();
    e.clock = Some(T0 + 40_000);
    let r = run(&mut e, RunMode::Live, json!({"type": "applyCode"}));
    assert!(r.outcomes[0].message.contains("使い放題"), "{}", r.outcomes[0].message);
    assert_eq!(e.codes()[1].status, CodeStatus::Pending);
    // 送ったコードは手動でも送り直さない
    assert!(e.apply_code_manual(None, Some("mockok1".into()), "利用する").unwrap_err().message.contains("すでに"));
    // 手動は確認語が要る
    assert!(e.apply_code_manual(None, Some("MOCKOK9".into()), "はい").is_err());
}

#[test]
fn dry_run_and_simulation_never_send() {
    let (mut e, _) = engine("low");
    login(&mut e);
    e.catalog(false).unwrap();
    e.add_codes("MOCKOK1", None);
    set(&mut e, |s| {
        s.purchase_mode = ActionMode::Auto;
        s.code_mode = ActionMode::Auto;
    });
    let r = run(&mut e, RunMode::Dry, json!({"type": "buy", "sku": "MOCK_UNLIMITED_1H"}));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::DryRun);
    set(&mut e, |s| s.dry_run = true);
    let r = run(&mut e, RunMode::Live, json!({"type": "applyCode"}));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::DryRun);
    assert!(e.ledger(10).is_empty());
    assert_eq!(e.codes()[0].status, CodeStatus::Pending);
    // シミュレーション: 仮の状態で判断し、記録も残さない
    let runs_before = e.runs(100).len();
    let sim = |unl: bool| RunInput {
        trigger: "sim".into(),
        mode: RunMode::Simulate,
        battery_level: Some(10),
        charging: false,
        network: "cellular".into(),
        plan_json: Some(json!({"type": "firstOf", "items": [{"type": "applyCode"}, {"type": "buy", "sku": "MOCK_UNLIMITED_1H"}]}).to_string()),
        error: None,
        script_logs: vec![],
        sim: Some(SimInput { left_kb: 0.1 * GB, unlimited: unl, unlimited_hours_left: None, hours_left: Some(1.0) }),
    };
    let r = e.execute_run(sim(false));
    assert_eq!(r.outcomes[0].status, OutcomeStatus::Simulated);
    assert_eq!(r.left_kb, Some(0.1 * GB));
    let r = e.execute_run(sim(true));
    assert_eq!(status_of(&r, ActionKind::ApplyCode), vec![OutcomeStatus::Refused]);
    assert_eq!(status_of(&r, ActionKind::Buy), vec![OutcomeStatus::Simulated]);
    assert_eq!(e.runs(100).len(), runs_before);
    assert!(e.ledger(10).is_empty());
}

#[test]
fn halt_stops_everything_and_persists() {
    let (mut e, dir) = engine("");
    login(&mut e);
    let err = e.order_manual("MOCK_FORBIDDEN", "購入する").unwrap_err();
    assert!(err.halt);
    assert!(e.snapshot(true).unwrap_err().halt);
    let r = run(&mut e, RunMode::Live, json!({"type": "firstOf", "items": [{"type": "buy", "sku": "MOCK_UNLIMITED_1H"}, {"type": "notify", "title": "止まっています"}]}));
    assert_eq!(status_of(&r, ActionKind::Buy), vec![OutcomeStatus::Refused]);
    assert_eq!(status_of(&r, ActionKind::Notify), vec![OutcomeStatus::Notified], "通知は povo に送らないので出せる");
    // 停止は保存され、次の起動(バックグラウンド)でも続く
    e.save();
    let mut e2 = Engine::open(&config(&dir, ""), Box::new(MemoryStore::default()));
    assert!(e2.snapshot(true).unwrap_err().halt);
    e2.unhalt();
    assert!(e2.snapshot(true).is_ok());
}

#[test]
fn rate_limit() {
    let (mut e, _) = engine("");
    login(&mut e);
    let mut t = T0;
    let mut failed = false;
    for _ in 0..30 {
        t += 6_000;
        e.clock = Some(t);
        if let Err(f) = e.snapshot(true) {
            assert!(f.message.contains("5分間"));
            failed = true;
            break;
        }
    }
    assert!(failed, "5分20回の上限で止まるはず");
}

#[test]
fn rule_context_shapes() {
    let (mut e, _) = engine("low");
    login(&mut e);
    e.add_codes("MOCKOK1 1gb", None);
    let ctx = e.rule_context(RunMode::Live, None).unwrap();
    assert!(ctx["data"]["leftGB"].as_f64().unwrap() < 0.26);
    assert_eq!(ctx["data"]["unlimited"]["active"], false);
    assert_eq!(ctx["codes"][0]["tag"], "1gb");
    assert_eq!(ctx["codes"][0]["masked"], mask("MOCKOK1"));
    assert!(ctx["codes"][0].get("code").is_none(), "ルールにはコードの中身を渡さない");
    assert_eq!(ctx["settings"]["purchaseMode"], "confirm");
    assert!(ctx["forecast"]["hoursLeft"].as_f64().is_some());
    let sim = e
        .rule_context(RunMode::Simulate, Some(SimInput { left_kb: 3.0 * GB, unlimited: true, unlimited_hours_left: Some(2.0), hours_left: None }))
        .unwrap();
    assert_eq!(sim["data"]["leftGB"], 3.0);
    assert_eq!(sim["data"]["unlimited"]["active"], true);
    assert_eq!(sim["data"]["unlimited"]["hoursLeft"], 2.0);
    assert!(sim["forecast"]["hoursLeft"].is_null());
    let cat = e.rule_catalog(RunMode::Live).unwrap();
    let h1 = cat.as_array().unwrap().iter().find(|p| p["sku"] == "MOCK_UNLIMITED_1H").unwrap();
    assert_eq!(h1["unlimited"], true);
    assert_eq!(h1["hours"], 1.0);
    assert_eq!(h1["price"], 110);
}

#[test]
fn script_bridge_is_read_only() {
    let (mut e, _) = engine("");
    login(&mut e);
    let v: Value = serde_json::from_str(&crate::script::script_call(&mut e, "catalog", r#"{"mode":"live"}"#)).unwrap();
    assert_eq!(v["ok"], true);
    let v: Value = serde_json::from_str(&crate::script::script_call(&mut e, "order", r#"{"sku":"MOCK_UNLIMITED_1H"}"#)).unwrap();
    assert_eq!(v["ok"], false);
    assert!(e.ledger(10).is_empty());
}

#[test]
fn adaptive_check_interval() {
    let (mut e, _) = engine("low");
    login(&mut e);
    e.snapshot(false).unwrap();
    // 残り 300MB → 30分以内
    assert!(e.next_check_delay_min() <= 30);
    let (mut e2, _) = engine("");
    login(&mut e2);
    e2.snapshot(false).unwrap();
    assert!(e2.next_check_delay_min() >= 30);
    // 使い放題中は終わる頃に(モックの使い放題は実時間で動くので、時計も実時間にする)
    e.clock = None;
    e.order_manual("MOCK_UNLIMITED_1H", "購入する").unwrap();
    e.snapshot(true).unwrap();
    let d = e.next_check_delay_min();
    assert!((15..=62).contains(&d), "{d}");
}

#[test]
fn ffi_object_and_dev_call() {
    let dir = tempdir();
    let eng = crate::PovoEngine::new(config(&dir, ""), Box::new(MemoryStore::default()));
    assert!(!eng.status().logged_in);
    eng.login_start(Some("a@b.c".into()), None).unwrap();
    eng.login_otp("000000".into()).unwrap();
    assert!(eng.snapshot(false).unwrap().left_kb.is_some());
    match eng.order("X".into(), "ちがう".into()) {
        Err(crate::PovoXError::Failure { message, halt, .. }) => {
            assert!(message.contains("購入する"));
            assert!(!halt);
        }
        other => panic!("{other:?}"),
    }
    let v: Value = serde_json::from_str(&eng.dev_call("status", &Value::Null)).unwrap();
    assert_eq!(v["result"]["logged_in"], true);
    let ctx: Value = serde_json::from_str(&eng.rule_context_json(RunMode::Live, None).unwrap()).unwrap();
    assert!(ctx["data"]["leftGB"].is_number());
}
