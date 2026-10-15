import Foundation
import Security

/// セッション(端末ID・トークン・回線番号)の保存先。エンジンが変化のたびに呼ぶ。
/// バックグラウンド実行や通知のボタンは画面ロック中にも動くので、
/// 「最初のロック解除後はいつでも読める・この端末だけ」にしている。
final class KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "session"

    init(service: String = "povoX") {
        self.service = service
    }

    private struct Blob: Codable {
        let deviceId: String
        let authToken: String
        let sin: String?
        let identifier: String
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> StoredSession? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let b = try? JSONDecoder().decode(Blob.self, from: data) else { return nil }
        return StoredSession(deviceId: b.deviceId, authToken: b.authToken, sin: b.sin, identifier: b.identifier)
    }

    func save(session: StoredSession) {
        let blob = Blob(deviceId: session.deviceId, authToken: session.authToken, sin: session.sin, identifier: session.identifier)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = baseQuery
            q.merge(attrs) { $1 }
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
