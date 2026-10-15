//! 開発用: `cargo run --example cli -- <dir> <op> '<引数JSON>'`。
//! モックのエンジンで1つの操作を JSON で処理して応答を出す(ルールをパソコン上で試すため)。
//! ログイン手続きはプロセスの中にしか残らないので、未ログインならここで済ませる。
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = args.get(1).expect("dir").clone();
    let op = args.get(2).expect("op").clone();
    let a: serde_json::Value = args.get(3).map(|s| serde_json::from_str(s).expect("json")).unwrap_or(serde_json::Value::Null);
    let scenario = std::env::var("MOCK_SCENARIO").unwrap_or_default();
    let eng = povo_auto::PovoEngine::new(
        povo_auto::EngineConfig { dir, mock: true, mock_scenario: scenario },
        Box::new(povo_auto::MemoryStore::default()),
    );
    if !eng.status().logged_in {
        eng.login_start(Some("dev@example.com".into()), None).expect("login_start");
        eng.login_otp("000000".into()).expect("login_otp");
    }
    println!("{}", eng.dev_call(&op, &a));
}
