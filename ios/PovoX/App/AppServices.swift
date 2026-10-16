import Foundation
import UIKit

/// 起動時の指定(UI テスト・デモ用)。
struct LaunchOptions {
    /// UI テスト: 専用の保存先・モック・通知の許可を求めない・表示中の自動チェックなし。
    var uiTest = false
    /// 保存データを消してから起動する。
    var reset = false
    var mockScenario = ""
    var forceDark = false
    var forceLight = false
    var skipOnboarding = false
    var tab: String?
    var device: DeviceState?
    /// UI テストでも通知を使う(通知のボタンの確認用)。
    var uiTestNotifications = false
    /// デモの予定を使う(カレンダーの代わり)。
    var demoCalendar = false

    static let current: LaunchOptions = {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        var o = LaunchOptions()
        o.uiTest = args.contains("-uitest")
        o.reset = args.contains("-reset")
        o.mockScenario = value("-mockScenario") ?? ""
        o.forceDark = args.contains("-forceDark")
        o.forceLight = args.contains("-forceLight")
        o.skipOnboarding = args.contains("-skipOnboarding")
        o.tab = value("-tab")
        o.uiTestNotifications = args.contains("-uitestNotifications")
        o.demoCalendar = args.contains("-demoCalendar")
        if let b = value("-deviceBattery") {
            o.device = DeviceState(batteryLevel: Int(b), charging: args.contains("-deviceCharging"), full: false, lowPower: false,
                                   network: value("-deviceNetwork") ?? "cellular")
        }
        return o
    }()
}

/// アプリ全体の部品をまとめる。エンジンはモックと本番の切り替えで作り直す。
final class AppServices {
    static let shared = AppServices()

    let launch: LaunchOptions
    let settings: AppSettings
    let notifications = NotificationService()
    let device = DeviceMonitor()
    let location = LocationMonitor()
    let calendar = CalendarService()
    /// オートメーション(内蔵のショートカット)。
    let flows: FlowStore
    /// 第1段の測定(起こされた時刻・通知の配信・通信量カウンタ)。
    let wakeLog: WakeLog
    /// 学習した使い方と、利用者の直し。
    let learning: LearningStore
    private(set) lazy var automation: AutomationService = makeAutomation()

    private let lock = NSLock()
    private var _client: EngineClient!

    var client: EngineClient {
        lock.lock(); defer { lock.unlock() }
        return _client
    }

    private init() {
        launch = LaunchOptions.current
        if launch.uiTest {
            let suite = "povox.uitest"
            if launch.reset { UserDefaults().removePersistentDomain(forName: suite) }
            settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
            settings.mockMode = true
            if launch.skipOnboarding { settings.onboardingDone = true }
            if launch.reset { try? FileManager.default.removeItem(at: AppServices.dataDirectory(uiTest: true)) }
            notifications.enabled = launch.uiTestNotifications
        } else {
            settings = AppSettings(defaults: .standard)
        }
        AppSettings.shared = settings
        flows = FlowStore(defaults: settings.defaults)
        wakeLog = WakeLog(defaults: settings.defaults)
        WakeRecorder.log = wakeLog
        learning = LearningStore(defaults: settings.defaults)
        flows.seedIfNeeded()
        if launch.demoCalendar { calendar.demoEvents = CalendarService.demo() }
        device.override = launch.device
        _client = makeClient(mock: settings.mockMode)
        wireNotifications()
        _ = automation
        wireLocation()
    }

    /// 位置の変化で起こされたら残量チェックを回す(設定でオンのときだけ)。
    private func wireLocation() {
        guard !launch.uiTest else { return }
        location.onWake = { [unowned self] trigger in
            guard self.settings.locationEnabled else { return }
            _ = await self.automation.run(trigger: trigger)
        }
        if settings.locationEnabled {
            location.setEnabled(true)
        }
    }

    /// 位置情報での起動を切り替える(権限も求める)。
    func setLocationEnabled(_ on: Bool) {
        settings.locationEnabled = on
        location.setEnabled(on)
    }

    static func dataDirectory(uiTest: Bool) -> URL {
        if uiTest {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("povox-uitest", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("povoX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir
    }

    private func makeClient(mock: Bool) -> EngineClient {
        let store = KeychainSessionStore(service: launch.uiTest ? "povoX-uitest" : "povoX")
        if launch.uiTest && launch.reset { store.clear() }
        return EngineClient(mock: mock, scenario: launch.mockScenario, directory: AppServices.dataDirectory(uiTest: launch.uiTest), store: store)
    }

    /// モックと本番を切り替える。
    func setMock(_ on: Bool) {
        settings.mockMode = on
        let c = makeClient(mock: on)
        lock.lock()
        _client = c
        lock.unlock()
    }

    private func makeAutomation() -> AutomationService {
        AutomationService(.init(
            client: { [unowned self] in self.client },
            device: { [unowned self] in await self.device.current() },
            settings: { [unowned self] in self.settings },
            notify: { [unowned self] list in await self.notifications.post(list) },
            afterRun: { [unowned self] record in
                WakeRecorder.record("run", source: record.trigger, at: Date(timeIntervalSince1970: Double(record.startedMs) / 1000))
                await self.afterChange(summary: record.summary)
            },
            flows: { [unowned self] in self.flows },
            calendar: { [unowned self] in
                let c = self.calendar
                return (c.events(), c.authorized)
            },
            applyEffects: { [unowned self] effects in await self.apply(effects) },
            flowsFired: { firings in
                for f in firings {
                    if let occ = f.occurrence { FlowScheduler.remove(flowID: f.flow.id, occurrence: occ) }
                }
            }
        ))
    }

    /// 学習し直す(端末の中だけ。30分に1回まで。force で今すぐ)。
    @discardableResult
    func learn(force: Bool = false) async -> LearnedModel? {
        let key = "learn.lastRun"
        if !force, let last = settings.defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 30 * 60 {
            return learning.model()
        }
        settings.defaults.set(Date(), forKey: key)
        let now = Date()
        let hist = await client.value { $0.history(hours: 120 * 24) }
        let net: [(t: Int64, s: NetSample)] = wakeLog.events().compactMap { e -> (t: Int64, s: NetSample)? in
            guard let n = e.net else { return nil }
            return (t: e.tMs, s: n)
        }
        let events = calendar.events(from: now.addingTimeInterval(-90 * 86_400), to: now)
        let input = UsageLearner.Input(samples: hist.map { (t: $0.tMs, leftKb: $0.leftKb, unlimited: $0.unlimited) }, net: net, events: events,
                                       overrides: learning.overrides(), now: now)
        let model = await Task.detached(priority: .utility) { UsageLearner.learn(input) }.value
        learning.save(model)
        return learning.model()
    }

    /// オートメーションの「設定を変える」アクション。
    func apply(_ effects: [FlowEffect]) async {
        let c = client
        for e in effects {
            switch e {
            case .purchaseMode(let m):
                let mode = ActionMode.named(m)
                _ = await c.value { e -> Settings in
                    var s = e.settings()
                    s.purchaseMode = mode
                    return e.updateSettings(settings: s)
                }
            case .codeMode(let m):
                let mode = ActionMode.named(m)
                _ = await c.value { e -> Settings in
                    var s = e.settings()
                    s.codeMode = mode
                    return e.updateSettings(settings: s)
                }
            case .flowEnabled(let id, let on):
                flows.setEnabled(id, on)
            }
        }
        await MainActor.run { NotificationCenter.default.post(name: .povoxFlowsChanged, object: nil) }
    }

    /// 時刻・予定のオートメーションの通知を入れ直し、次に動く時刻を返す(通信しない)。
    @discardableResult
    func rescheduleFlows() async -> Date? {
        let enabled = notifications.enabled
        let c = client
        guard let ctx = try? await c.call({ try $0.ruleContextJson(mode: .simulate, sim: nil) }) else {
            await FlowScheduler.apply([], enabled: false)
            return nil
        }
        let dev = await device.current()
        let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: "schedule", device: dev, now: Date())
        // 先8日の予定(「外出の予定がある日だけ」のアラームを前もって予約するため)
        let facts = AutomationService.makeFacts(contextJSON: merged, calendar: (calendar.events(days: 9), calendar.authorized), settings: settings)
        let list = flows.flows()
        let memory = flows.memory()
        await FlowScheduler.apply(FlowEngine.schedule(flows: list, facts: facts, memory: memory), enabled: enabled)
        return FlowEngine.nextDue(flows: list, facts: facts, memory: memory)
    }

    /// 実行・確認のあと: ウィジェットを更新し、次の自動チェックを予約し、画面に知らせる。
    func afterChange(summary: String?) async {
        let c = client
        await WidgetBridge.update(client: c, lastSummary: summary)
        var delay = await c.value { $0.nextCheckDelayMin() }
        await WakeRecorder.collectDelivered()
        let nextFlow = await rescheduleFlows()
        if let next = nextFlow {
            // 時刻・予定のオートメーションに間に合うよう、バックグラウンド更新を早める
            let minutes = max(15, Int(next.timeIntervalSinceNow / 60))
            delay = min(delay, UInt32(minutes))
        }
        if !launch.uiTest {
            BackgroundScheduler.schedule(afterMinutes: delay, enabled: settings.backgroundEnabled)
        }
        await MainActor.run { NotificationCenter.default.post(name: .povoxDidChange, object: nil) }
    }

    private func wireNotifications() {
        notifications.onConfirm = { [unowned self] id in
            let c = self.client
            let out = try? await c.call { try $0.confirmPending(id: id) }
            if out?.status == .done {
                _ = try? await c.call { try $0.snapshot(force: true) }
            }
            await self.afterChange(summary: out.map { "\($0.label): \($0.message)" })
            return out
        }
        notifications.onDismiss = { [unowned self] id in
            await self.client.value { $0.dismissPending(id: id) }
            await self.afterChange(summary: nil)
        }
        notifications.onLog = { [unowned self] text in
            self.client.engine.log(level: .info, message: text)
        }
        notifications.onRunFlow = { [unowned self] id, occ in
            var args: [String: String] = [:]
            if let occ { args["occ"] = occ }
            _ = await self.automation.run(trigger: "flow:\(id)", args: args)
        }
        notifications.onOpen = { info in
            NotificationCenter.default.post(name: .povoxOpenRoute, object: nil, userInfo: info)
        }
    }
}

extension Notification.Name {
    /// 通知をタップした(画面を切り替える合図)。
    static let povoxOpenRoute = Notification.Name("povoxOpenRoute")
    /// オートメーションが変わった(画面を読み直す合図)。
    static let povoxFlowsChanged = Notification.Name("povoxFlowsChanged")
}
