import Foundation

/// Rust のエンジン(core/)への入口。要求・応答は JSON。
/// povo への通信の直列化・安全装置・保存はすべて Rust 側にある。ここは受け渡しと
/// セッション(端末ID+トークン)のキーチェーン保存だけを受け持つ。
final class Core {
    static let shared = Core()

    private let modeLock = NSLock()
    private(set) var mock: Bool

    private init() {
        mock = UserDefaults.standard.bool(forKey: "mockMode")
        start()
    }

    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("povoX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir
    }

    private func start() {
        var req: [String: Any] = ["op": "init", "dir": Core.dataDirectory.path, "mock": mock]
        if !mock, let data = Keychain.load(),
           let session = try? JSONSerialization.jsonObject(with: data) {
            req["session"] = session
        }
        _ = send(req)
    }

    /// モックと本番を切り替える(エンジンを作り直す)。
    func setMock(_ on: Bool) {
        modeLock.lock()
        defer { modeLock.unlock() }
        mock = on
        UserDefaults.standard.set(on, forKey: "mockMode")
        start()
    }

    /// JSON 文字列のまま送受信する(スクリプトから使う)。
    func callRaw(op: String, argsJSON: String) -> String {
        var req: [String: Any] = [:]
        if let data = argsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            req = obj
        }
        req["op"] = op
        return send(req)
    }

    private func send(_ req: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":{"message":"要求を作れませんでした","halt":false}}"#
        }
        let out: String = text.withCString { ptr in
            guard let res = povo_auto_call(ptr) else {
                return #"{"ok":false,"error":{"message":"応答がありません","halt":false}}"#
            }
            defer { povo_auto_free(res) }
            return String(cString: res)
        }
        applySessionEvent(out)
        return out
    }

    /// 本番でセッションが変わったら、端末IDとトークンを組でキーチェーンに保存する。
    private func applySessionEvent(_ out: String) {
        guard out.contains("\"session\""),
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = obj["session"] as? [String: Any] else { return }
        if let save = session["save"], let blob = try? JSONSerialization.data(withJSONObject: save) {
            Keychain.save(blob)
        } else if session["clear"] as? Bool == true {
            Keychain.delete()
        }
    }

    // MARK: - Swift から使う形

    func call(_ op: String, _ args: [String: Any] = [:]) -> Result<Any, CoreError> {
        var req = args
        req["op"] = op
        let out = send(req)
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(CoreError(message: "応答を読めませんでした"))
        }
        if obj["ok"] as? Bool == true {
            return .success(obj["result"] ?? NSNull())
        }
        if let e = obj["error"], let ed = try? JSONSerialization.data(withJSONObject: e),
           let err = try? Core.decoder.decode(CoreError.self, from: ed) {
            return .failure(err)
        }
        return .failure(CoreError(message: "不明なエラー"))
    }

    func decode<T: Decodable>(_ op: String, _ args: [String: Any] = [:], as type: T.Type) -> Result<T, CoreError> {
        switch call(op, args) {
        case .failure(let e):
            return .failure(e)
        case .success(let value):
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                return .success(try Core.decoder.decode(T.self, from: data))
            } catch {
                return .failure(CoreError(message: "応答の形が想定と違います: \(error.localizedDescription)"))
            }
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// Rust 側の Failure と同じ形。
struct CoreError: Error, Decodable, Identifiable {
    var id: String { message + (hint ?? "") }
    let message: String
    var povoStatus: Int? = nil
    var povoCode: Int? = nil
    var hint: String? = nil
    var blockUntilMs: Int64? = nil
    var halt: Bool = false

    init(message: String) {
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case message, povoStatus, povoCode, hint, blockUntilMs, halt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        povoStatus = try c.decodeIfPresent(Int.self, forKey: .povoStatus)
        povoCode = try c.decodeIfPresent(Int.self, forKey: .povoCode)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        blockUntilMs = try c.decodeIfPresent(Int64.self, forKey: .blockUntilMs)
        halt = try c.decodeIfPresent(Bool.self, forKey: .halt) ?? false
    }

    /// 画面に出す1〜2行。
    var display: String {
        var s = message
        if let st = povoStatus { s += "(HTTP \(st)\(povoCode.map { " / \($0)" } ?? ""))" }
        if let h = hint, !h.isEmpty { s += "\n" + h }
        return s
    }
}
