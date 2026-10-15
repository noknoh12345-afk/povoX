//! 開発用: `cargo run --example cli -- <dir> '<要求JSON>'`。モックで1要求だけ処理して応答を出す。
//! (スクリプトの API をパソコン上で試すため。アプリには入らない。)
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = args.get(1).expect("dir");
    let req = args.get(2).expect("request json");
    let init = serde_json::json!({"op": "init", "dir": dir, "mock": true}).to_string();
    let st: serde_json::Value = serde_json::from_str(&povo_auto::handle_json(&init)).unwrap();
    if st["result"]["logged_in"] != true {
        // ログイン手続きはプロセス内にしか残らないので、モックではここで済ませる。
        povo_auto::handle_json(r#"{"op":"login_start","email":"dev@example.com"}"#);
        povo_auto::handle_json(r#"{"op":"login_otp","code":"000000"}"#);
    }
    println!("{}", povo_auto::handle_json(req));
}
