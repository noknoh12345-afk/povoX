import Foundation

/// 自動チェック(ルールの評価 → 計画の実行)の入口。きっかけはどれでもここを通る:
/// バックグラウンド更新 / ショートカット / アプリ表示中のタイマー / 手動 / 試運転 / シミュレーター。
///
/// 流れ: エンジンが材料(残量・予測・コード・予算)を用意 → 端末の情報を足す →
///       ルールが計画を返す → エンジンが安全装置にかけて実行 → 通知・ウィジェット・次回の予約。
final class AutomationService {
    struct Dependencies {
        var client: () -> EngineClient
        var device: () async -> DeviceState
        var settings: () -> AppSettings
        var notify: ([PlannedNotification]) async -> Void
        /// 実行のあと(ウィジェットの更新・次回の予約・画面への知らせ)。
        var afterRun: (RunRecord) async -> Void
    }

    private let deps: Dependencies
    private let lock = NSLock()
    private var running = false

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    private func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func end() {
        lock.lock(); defer { lock.unlock() }
        running = false
    }

    /// 本番・試運転の自動チェック。ログインしていない・通信停止中・別の実行中なら何もせず nil。
    func run(trigger: String, mode: RunMode = .live, args: [String: String] = [:]) async -> RunRecord? {
        guard mode != .simulate, tryBegin() else { return nil }
        defer { end() }
        let client = deps.client()
        let status = await client.value { $0.status() }
        guard status.loggedIn, status.halted == nil else { return nil }
        let device = await deps.device()
        let settings = deps.settings()
        var input = RunInput(trigger: trigger, mode: mode, batteryLevel: device.batteryLevel.map { UInt32(max(0, $0)) },
                             charging: device.charging, network: device.network, planJson: nil, error: nil, scriptLogs: [], sim: nil)
        do {
            let ctx = try await client.call { try $0.ruleContextJson(mode: mode, sim: nil) }
            let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: trigger, device: device, now: Date(), args: args)
            let eval = await AutomationService.evaluate(rule: RuleLibrary.currentSource(settings: settings), context: merged,
                                                        engine: client.engine, settings: settings)
            input.planJson = eval.planJSON
            input.error = eval.error
            input.scriptLogs = eval.logs
        } catch {
            input.error = "残量を取得できませんでした: \(AlertMessage(error).message)"
        }
        let record = await client.value { $0.executeRun(input: input) }
        settings.lastRun = Date()
        let planned = NotificationPlanner.plan(for: record, notifyErrors: settings.notifyErrors,
                                               notifyActions: settings.notifyActions, confirmTtlMin: status.settings.confirmTtlMin)
        await deps.notify(throttleErrors(planned, settings: settings))
        await deps.afterRun(record)
        return record
    }

    /// シミュレーター: 仮の状態でルールを評価し、安全装置の判断まで見る。povo に通信せず、記録も残さない。
    func simulate(_ sim: SimInput, device: DeviceState, trigger: String, rule: String? = nil) async -> RunRecord {
        let client = deps.client()
        let settings = deps.settings()
        var input = RunInput(trigger: trigger, mode: .simulate, batteryLevel: device.batteryLevel.map { UInt32(max(0, $0)) },
                             charging: device.charging, network: device.network, planJson: nil, error: nil, scriptLogs: [], sim: sim)
        do {
            let ctx = try await client.call { try $0.ruleContextJson(mode: .simulate, sim: sim) }
            let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: trigger, device: device, now: Date())
            let eval = await AutomationService.evaluate(rule: rule ?? RuleLibrary.currentSource(settings: settings), context: merged,
                                                        engine: client.engine, settings: settings)
            input.planJson = eval.planJSON
            input.error = eval.error
            input.scriptLogs = eval.logs
        } catch {
            input.error = AlertMessage(error).message
        }
        return await client.value { $0.executeRun(input: input) }
    }

    static func evaluate(rule: String, context: String, engine: PovoEngine?, settings: AppSettings) async -> RuleEvaluation {
        let prelude = RuleLibrary.prelude()
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: RuleEngine.evaluate(rule: rule, contextJSON: context, prelude: prelude, engine: engine, settings: settings))
            }
        }
    }

    /// 同じエラーの通知は6時間に1回まで(電波の悪い所で通知が続かないように)。
    private func throttleErrors(_ list: [PlannedNotification], settings: AppSettings) -> [PlannedNotification] {
        list.filter { n in
            guard n.kind == .error, n.userInfo["pending_id"] == nil, n.id.hasSuffix("-error") else { return true }
            let key = "notify.lastError"
            let last = settings.defaults.dictionary(forKey: key)
            if let text = last?["text"] as? String, let at = last?["at"] as? Date, text == n.body, Date().timeIntervalSince(at) < 6 * 3600 {
                return false
            }
            settings.defaults.set(["text": n.body, "at": Date()], forKey: key)
            return true
        }
    }
}

extension Notification.Name {
    /// 自動チェック・確認の実行が終わった(画面を読み直す合図)。
    static let povoxDidChange = Notification.Name("povoxDidChange")
}
