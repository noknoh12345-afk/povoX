//! povo への送信値。
//!
//! ここに独自の値は置かない。すべて povo-android(実アカウントでログイン・購入が
//! 確認されているクライアント)の `PovoProtocol.kt` / `DeviceId` と同じにしている。
//! 値を変えるとサーバー側の見え方が変わるので、変えるときは povo-android 側の
//! 更新に合わせること。
#![allow(dead_code)]

use rand::RngCore;

/// `X-App-Version`。povo-android の `PovoProtocol.APP_VERSION` と同じ。
pub const APP_VERSION: &str = "1.69.0-JP";

/// `User-Agent`。povo-android は povo-core 既定の UA を上書きしてこれを送っている。
pub const USER_AGENT: &str = "okhttp/4.12.0";

/// SMS OTP 用の国番号。
pub const ISD_CODE_JP: &str = "81";

/// 3-D セキュア完了時の遷移先。povo-android と同じ値。
pub const ORDER_REDIRECT_URL: &str = "https://povo.jp/success";

/// 端末ID: 16バイトの乱数を小文字hex 32桁にしたもの(UUIDではない)。
/// アカウント追加時に1回だけ作り、以後ずっと同じ値を使う。
pub fn new_device_id() -> String {
    let mut bytes = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// JWT の `exp`(エポック秒)。読めなければ None。
pub fn jwt_exp(token: &str) -> Option<i64> {
    use base64::Engine;
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    value.get("exp")?.as_i64()
}

/// povo-android の `Jwt.isExpired` と同じ判定: exp が読めない、または過ぎていれば期限切れ。
/// サーバーは期限前に更新を頼むと同じトークンを返すので、期限前には更新しない。
pub fn is_expired(token: &str) -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    match jwt_exp(token) {
        Some(exp) => exp <= now,
        None => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_id_is_32_lower_hex() {
        let id = new_device_id();
        assert_eq!(id.len(), 32);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_ne!(id, new_device_id());
    }

    #[test]
    fn expiry() {
        use base64::Engine;
        let enc = |v: serde_json::Value| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string())
        };
        let past = format!("h.{}.s", enc(serde_json::json!({"exp": 1})));
        let future = format!("h.{}.s", enc(serde_json::json!({"exp": 9_999_999_999i64})));
        assert!(is_expired(&past));
        assert!(!is_expired(&future));
        assert!(is_expired("not-a-jwt"));
    }
}
