import Foundation
import JavaScriptCore

/// ルールの評価結果。計画(JSON)かエラーのどちらか。
struct RuleEvaluation {
    var planJSON: String?
    var error: String?
    var logs: [String]
}

/// 利用者のルール(JavaScript)を JavaScriptCore で評価する。
/// ルールは「何をするか」を返すだけで、povo へ送れない(ネイティブ側は読み取りとログだけ)。
enum RuleEngine {
    /// 1回の評価の持ち時間。無限ループでバックグラウンド実行が止まらないようにする。
    static let timeLimitSeconds: Double = 3

    private final class Box {
        private let lock = NSLock()
        private var lines: [String] = []
        private var exception: String?

        func log(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            if lines.count < 50 { lines.append(String(s.prefix(300))) }
        }

        var logs: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }

        func setException(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            if exception == nil { exception = s }
        }

        func takeException() -> String? {
            lock.lock(); defer { lock.unlock() }
            let e = exception
            exception = nil
            return e
        }
    }

    // JSContextGroupSetExecutionTimeLimit は JavaScriptCore にあるが公開ヘッダーに無いので、実行時に探す。
    // 見つからなければ持ち時間なしで動く。
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    private static let setTimeLimit: SetTimeLimit? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(sym, to: SetTimeLimit.self)
    }()

    static var timeLimitSupported: Bool { setTimeLimit != nil }

    private static func describe(_ value: JSValue?) -> String {
        guard let value else { return "不明なエラー" }
        var msg = value.toString() ?? "不明なエラー"
        if msg.contains("terminated") || msg.contains("Terminated") {
            return "ルールの実行が\(Int(timeLimitSeconds))秒を超えたので止めました(繰り返しが終わらない可能性)"
        }
        if let line = value.objectForKeyedSubscript("line"), line.isNumber {
            let src = value.objectForKeyedSubscript("sourceURL")?.toString() ?? ""
            let file = src.contains("prelude") ? "下ごしらえ" : "ルール"
            msg += "(\(file)の\(line.toInt32())行目)"
        }
        return msg
    }

    private static func makeContext(prelude: String, box: Box, engine: PovoEngine?, settings: AppSettings) -> JSContext? {
        guard let ctx = JSContext() else { return nil }
        ctx.name = "povoX rule"
        ctx.exceptionHandler = { _, value in box.setException(describe(value)) }
        if let f = setTimeLimit, let global = ctx.jsGlobalContextRef {
            f(JSContextGetGroup(global), timeLimitSeconds, { _, _ in true }, nil)
        }
        let call: @convention(block) (String, String) -> String = { op, args in
            guard let engine else { return #"{"ok":false,"error":{"message":"エンジンがありません","halt":false}}"# }
            return engine.scriptCall(op: op, argsJson: args)
        }
        let log: @convention(block) (String) -> Void = { box.log($0) }
        let stateGet: @convention(block) (String) -> String = { settings.scriptState($0) ?? "" }
        let stateSet: @convention(block) (String, String) -> Void = { settings.setScriptState($0, $1) }
        ctx.setObject(call, forKeyedSubscript: "__native_call" as NSString)
        ctx.setObject(log, forKeyedSubscript: "__native_log" as NSString)
        ctx.setObject(stateGet, forKeyedSubscript: "__native_state_get" as NSString)
        ctx.setObject(stateSet, forKeyedSubscript: "__native_state_set" as NSString)
        ctx.evaluateScript(prelude, withSourceURL: URL(string: "povox://rule-prelude.js"))
        return ctx
    }

    /// ルールを評価して計画(JSON)を返す。画面以外のスレッドから呼ぶ。
    static func evaluate(rule: String, contextJSON: String, prelude: String, engine: PovoEngine?, settings: AppSettings) -> RuleEvaluation {
        let box = Box()
        guard let ctx = makeContext(prelude: prelude, box: box, engine: engine, settings: settings) else {
            return RuleEvaluation(planJSON: nil, error: "JavaScript を起動できませんでした", logs: [])
        }
        if let e = box.takeException() {
            return RuleEvaluation(planJSON: nil, error: "下ごしらえのエラー: \(e)", logs: box.logs)
        }
        ctx.evaluateScript(rule, withSourceURL: URL(string: "povox://rule.js"))
        if let e = box.takeException() {
            return RuleEvaluation(planJSON: nil, error: "ルールの読み込みエラー: \(e)", logs: box.logs)
        }
        let result = ctx.objectForKeyedSubscript("__povox_run")?.call(withArguments: [contextJSON])
        if let e = box.takeException() {
            return RuleEvaluation(planJSON: nil, error: e, logs: box.logs)
        }
        guard let r = result, r.isString, let plan = r.toString() else {
            return RuleEvaluation(planJSON: nil, error: "ルールの結果を読めませんでした", logs: box.logs)
        }
        return RuleEvaluation(planJSON: plan, error: nil, logs: box.logs)
    }

    /// 文法と decide(ctx) の有無だけ確かめる(エディタで保存するとき)。問題なければ nil。
    static func check(rule: String, prelude: String, settings: AppSettings) -> String? {
        let box = Box()
        guard let ctx = makeContext(prelude: prelude, box: box, engine: nil, settings: settings) else {
            return "JavaScript を起動できませんでした"
        }
        _ = box.takeException()
        ctx.evaluateScript(rule, withSourceURL: URL(string: "povox://rule.js"))
        if let e = box.takeException() { return e }
        _ = ctx.objectForKeyedSubscript("__povox_check")?.call(withArguments: [])
        return box.takeException()
    }
}
