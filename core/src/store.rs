//! セッション(端末ID+トークン)の保存先。本番ではアプリがキーチェーンで実装する
//! (Swift 側の `SessionStore` プロトコル)。テストと開発用 CLI はメモリ上の実装を使う。

use std::sync::Mutex;

use crate::model::StoredSession;

#[uniffi::export(callback_interface)]
pub trait SessionStore: Send + Sync {
    fn load(&self) -> Option<StoredSession>;
    fn save(&self, session: StoredSession);
    fn clear(&self);
}

#[derive(Default)]
pub struct MemoryStore(pub Mutex<Option<StoredSession>>);

impl SessionStore for MemoryStore {
    fn load(&self) -> Option<StoredSession> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    fn save(&self, session: StoredSession) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(session);
    }
    fn clear(&self) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}
