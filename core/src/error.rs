//! アプリに返すエラー。povo 側のステータスとコードはそのまま見せる。

use crate::backend::Failure;

#[derive(Debug, Clone, PartialEq, thiserror::Error, uniffi::Error)]
pub enum PovoXError {
    #[error("{message}")]
    Failure {
        message: String,
        povo_status: Option<u16>,
        povo_code: Option<i64>,
        hint: Option<String>,
        /// povo が「この時刻まで再試行するな」と返したときのエポックミリ秒。
        block_until_ms: Option<i64>,
        /// これ以上 povo に送るのを止めたか(403、PIN 要求など)。
        halt: bool,
    },
}

impl From<Failure> for PovoXError {
    fn from(f: Failure) -> Self {
        PovoXError::Failure {
            message: f.message,
            povo_status: f.povo_status,
            povo_code: f.povo_code,
            hint: f.hint,
            block_until_ms: f.block_until_ms,
            halt: f.halt,
        }
    }
}
