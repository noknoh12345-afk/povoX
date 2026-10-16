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
        /// オートメーションの保存先(既定は空。テストなどで省いたとき)。
        var flows: () -> FlowStore = { AutomationService.noFlows }
        /// 今日・明日の予定と、カレンダーを読めるか。
        var calendar: () async -> (events: [CalEvent], authorized: Bool) = { ([], false) }
        /// 端末側の操作(設定の切り替えなど)。
        var applyEffects: ([FlowEffect]) async -> Void = { _ in }
        /// オートメーションが動いたあと(予約した通知を片付ける)。
        var flowsFired: ([FlowFiring]) async -> Void = { _ in }
    }

    /// オートメーションの無い保存先。
    static let noFlows = FlowStore(defaults: UserDefaults(suiteName: "povox.noflows") ?? .standard)

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
    ///
    /// オートメーション(内蔵のショートカット)とルール(JavaScript)の両方を評価し、1つの計画にしてエンジンへ渡す。
    /// きっかけが "flow:<ID>" のときは、そのオートメーションだけを動かす(ボタン・通知の「実行する」・予約)。
    func run(trigger: String, mode: RunMode = .live, args: [String: String] = [:]) async -> RunRecord? {
        guard mode != .simulate, tryBegin() else { return nil }
        defer { end() }
        let client = deps.client()
        let status = await client.value { $0.status() }
        guard status.loggedIn, status.halted == nil else { return nil }
        let device = await deps.device()
        let settings = deps.settings()
        let store = deps.flows()
        var input = RunInput(trigger: trigger, mode: mode, batteryLevel: device.batteryLevel.map { UInt32(max(0, $0)) },
                             charging: device.charging, network: device.network, planJson: nil, error: nil, scriptLogs: [], sim: nil)
        var firings: [FlowFiring] = []
        var memory: FlowMemory?
        var effects: [FlowEffect] = []
        do {
            let ctx = try await client.call { try $0.ruleContextJson(mode: mode, sim: nil) }
            let calendar = await deps.calendar()
            var flows = store.flows()
            // その場だけのオートメーション(今日のプランの「今すぐ」など。保存しない)
            if let a = args["adhoc"], let fl = try? JSONDecoder().decode(Flow.self, from: Data(a.utf8)) {
                flows.removeAll { $0.id == fl.id }
                flows.append(fl)
            }
            var trig = trigger
            var forced = AutomationService.forcedFlowID(trig)
            var occurrence = args["occ"]
            func facts(_ t: String) -> FlowFacts {
                let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: t, device: device, now: Date(), args: args)
                return AutomationService.makeFacts(contextJSON: merged, calendar: calendar, settings: settings)
            }
            var f = facts(trig)
            var eval = FlowEngine.evaluate(flows: flows, facts: f, memory: store.memory(), forcedID: forced, occurrence: occurrence)
            // 予約は作ったときに実行を決めているので、その場で押した実行として動かす
            if forced == nil, let pre = eval.firings.first(where: { $0.flow.preconfirmed }) {
                trig = "flow:\(pre.flow.id)"
                forced = pre.flow.id
                occurrence = pre.occurrence
                input.trigger = trig
                f = facts(trig)
                eval = FlowEngine.evaluate(flows: flows, facts: f, memory: eval.memory, forcedID: forced, occurrence: occurrence)
            }
            if eval.firings.contains(where: { $0.flow.spends }) {
                f.products = await client.value { AutomationService.catalog(engine: $0, mode: mode) }
            }
            let built = FlowEngine.build(eval.firings, facts: f, userInitiated: forced != nil)
            var logs = eval.logs + built.logs
            var nodes = built.nodes
            var error: String?
            if !built.effects.isEmpty {
                nodes.insert(["type": "skip", "reason": "設定: " + built.effects.map(AutomationService.describe).joined(separator: "・")], at: 0)
            }
            // ルール(ボタンなどで決め打ちのときは動かさない)
            if forced == nil && settings.ruleEnabled {
                let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: trig, device: device, now: Date(), args: args)
                let ev = await AutomationService.evaluate(rule: RuleLibrary.currentSource(settings: settings), context: merged,
                                                          engine: client.engine, settings: settings)
                logs += ev.logs
                if let plan = ev.planJSON, let obj = (try? JSONSerialization.jsonObject(with: Data(plan.utf8))) as? [String: Any] {
                    nodes.append(obj)
                } else if let e = ev.error {
                    if nodes.isEmpty { error = e } else { logs.append("ルールのエラー(オートメーションは動かしました): \(e)") }
                }
            }
            if nodes.isEmpty && error == nil {
                let why = forced != nil ? (eval.logs.last ?? "実行しませんでした") : "条件に合うオートメーションはありません"
                nodes = [["type": "skip", "reason": why]]
            }
            let plan: [String: Any] = nodes.count == 1 ? nodes[0] : ["type": "all", "items": nodes]
            input.planJson = (try? JSONSerialization.data(withJSONObject: plan)).flatMap { String(data: $0, encoding: .utf8) }
            input.error = error
            input.scriptLogs = logs
            firings = eval.firings
            memory = eval.memory
            effects = built.effects
        } catch {
            input.error = "残量を取得できませんでした: \(AlertMessage(error).message)"
        }
        if !effects.isEmpty {
            if mode == .live && !status.settings.dryRun {
                await deps.applyEffects(effects)
            } else {
                input.scriptLogs.append("(試運転なので設定は変えていません)")
            }
        }
        let record = await client.value { $0.executeRun(input: input) }
        if mode == .live, var m = memory {
            FlowEngine.recordFired(firings, summary: record.summary, memory: &m, now: Date())
            store.saveMemory(m)
            // 予約は1回きり。済んだらオフにする
            for f in firings where f.flow.trigger.kind == .once { store.setEnabled(f.flow.id, false) }
            if !firings.isEmpty { await deps.flowsFired(firings) }
        }
        settings.lastRun = Date()
        let planned = NotificationPlanner.plan(for: record, notifyErrors: settings.notifyErrors,
                                               notifyActions: settings.notifyActions, confirmTtlMin: status.settings.confirmTtlMin)
        await deps.notify(throttleErrors(planned, settings: settings))
        await deps.afterRun(record)
        return record
    }

    /// "flow:<ID>" から ID を取り出す。
    static func forcedFlowID(_ trigger: String) -> String? {
        trigger.hasPrefix("flow:") ? String(trigger.dropFirst(5)) : nil
    }

    static func makeFacts(contextJSON: String, calendar: (events: [CalEvent], authorized: Bool), settings: AppSettings) -> FlowFacts {
        var f = FlowFacts(contextJSON: contextJSON)
        f.events = calendar.events
        f.calendarAuthorized = calendar.authorized
        f.intensity = settings.intensityFactor
        f.learned = LearningStore(defaults: settings.defaults).model()
        if f.learned == nil {
            let o = LearningStore(defaults: settings.defaults).overrides()
            if !o.isEmpty { var m = LearnedModel.empty; m.overrides = o; f.learned = m }
        }
        return f
    }

    /// トッピング一覧(ルールの ctx.catalog() と同じもの)。
    static func catalog(engine: PovoEngine, mode: RunMode) -> [FlowProduct] {
        let m = mode == .simulate ? "simulate" : (mode == .dry ? "dry" : "live")
        let resp = engine.scriptCall(op: "catalog", argsJson: "{\"mode\":\"\(m)\"}")
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(resp.utf8))) as? [String: Any], obj["ok"] as? Bool == true,
              let result = obj["result"], let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return FlowProduct.list(fromJSON: json)
    }

    static func describe(_ e: FlowEffect) -> String {
        switch e {
        case .purchaseMode(let m): return "購入を「\(FlowText.modeLabel(m))」に"
        case .codeMode(let m): return "コードを「\(FlowText.modeLabel(m))」に"
        case .flowEnabled(let id, let on): return "オートメーション(\(id.prefix(4)))を\(on ? "オン" : "オフ")に"
        }
    }

    /// シミュレーター: 仮の状態でルールを評価し、安全装置の判断まで見る。povo に通信せず、記録も残さない。
    /// rule を渡したとき(レシピの下見など)はそのルールだけ。渡さないときはオートメーションも一緒に見る。
    func simulate(_ sim: SimInput, device: DeviceState, trigger: String, rule: String? = nil) async -> RunRecord {
        let client = deps.client()
        let settings = deps.settings()
        var input = RunInput(trigger: trigger, mode: .simulate, batteryLevel: device.batteryLevel.map { UInt32(max(0, $0)) },
                             charging: device.charging, network: device.network, planJson: nil, error: nil, scriptLogs: [], sim: sim)
        do {
            let ctx = try await client.call { try $0.ruleContextJson(mode: .simulate, sim: sim) }
            let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: trigger, device: device, now: Date())
            var nodes: [[String: Any]] = []
            var logs: [String] = []
            if rule == nil {
                let cal = await deps.calendar()
                var f = AutomationService.makeFacts(contextJSON: merged, calendar: cal, settings: settings)
                let eval = FlowEngine.evaluate(flows: deps.flows().flows(), facts: f, memory: FlowMemory(), simulate: true)
                if eval.firings.contains(where: { $0.flow.spends }) {
                    f.products = await client.value { AutomationService.catalog(engine: $0, mode: .simulate) }
                }
                let built = FlowEngine.build(eval.firings, facts: f, userInitiated: false)
                nodes = built.nodes
                logs = eval.logs + built.logs
            }
            if rule != nil || settings.ruleEnabled {
                let eval = await AutomationService.evaluate(rule: rule ?? RuleLibrary.currentSource(settings: settings), context: merged,
                                                            engine: client.engine, settings: settings)
                logs += eval.logs
                if let p = eval.planJSON, let obj = (try? JSONSerialization.jsonObject(with: Data(p.utf8))) as? [String: Any] {
                    nodes.append(obj)
                } else if let e = eval.error, nodes.isEmpty {
                    input.error = e
                }
            }
            if nodes.isEmpty && input.error == nil { nodes = [["type": "skip", "reason": "条件に合うオートメーションはありません"]] }
            if input.error == nil {
                let plan: [String: Any] = nodes.count == 1 ? nodes[0] : ["type": "all", "items": nodes]
                input.planJson = (try? JSONSerialization.data(withJSONObject: plan)).flatMap { String(data: $0, encoding: .utf8) }
            }
            input.scriptLogs = logs
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
