import Foundation

/// Rust のエンジン(`PovoEngine`、UniFFI で作られた型)を使う窓口。
/// エンジンは中で povo への通信を1本ずつにしているので、どのスレッドから呼んでもよい。
/// ここでは画面のスレッドを止めないよう、別スレッドで呼ぶ async の入口を用意する。
final class EngineClient {
    let engine: PovoEngine
    let mock: Bool

    private static let queue = DispatchQueue(label: "povox.engine", qos: .userInitiated, attributes: .concurrent)

    init(mock: Bool, scenario: String, directory: URL, store: SessionStore) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = PovoEngine(config: EngineConfig(dir: directory.path, mock: mock, mockScenario: scenario), store: store)
        self.mock = mock
    }

    /// 失敗しうる操作。
    func call<T>(_ body: @escaping (PovoEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            EngineClient.queue.async {
                do {
                    cont.resume(returning: try body(self.engine))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// 失敗しない操作。
    func value<T>(_ body: @escaping (PovoEngine) -> T) async -> T {
        await withCheckedContinuation { cont in
            EngineClient.queue.async {
                cont.resume(returning: body(self.engine))
            }
        }
    }
}

extension PovoXError {
    var message: String {
        switch self {
        case let .Failure(message, _, _, _, _, _): return message
        }
    }

    var hint: String? {
        switch self {
        case let .Failure(_, _, _, hint, _, _): return hint
        }
    }

    var povoStatus: UInt16? {
        switch self {
        case let .Failure(_, status, _, _, _, _): return status
        }
    }

    var povoCode: Int64? {
        switch self {
        case let .Failure(_, _, code, _, _, _): return code
        }
    }

    var halted: Bool {
        switch self {
        case let .Failure(_, _, _, _, _, halt): return halt
        }
    }

    /// 画面に出す文。povo のステータスとコードはそのまま見せる。
    var display: String {
        var s = message
        if let st = povoStatus {
            s += "(HTTP \(st)\(povoCode.map { " / \($0)" } ?? ""))"
        }
        if let h = hint, !h.isEmpty {
            s += "\n" + h
        }
        return s
    }
}

/// 画面のアラート用。
struct AlertMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ error: Error, title: String = "エラー") {
        if let e = error as? PovoXError {
            self.title = e.halted ? "通信を止めました" : title
            self.message = e.display
        } else {
            self.title = title
            self.message = error.localizedDescription
        }
    }
}
