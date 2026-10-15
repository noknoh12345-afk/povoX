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
        device.override = launch.device
        _client = makeClient(mock: settings.mockMode)
        wireNotifications()
        _ = automation
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
            afterRun: { [unowned self] record in await self.afterChange(summary: record.summary) }
        ))
    }

    /// 実行・確認のあと: ウィジェットを更新し、次の自動チェックを予約し、画面に知らせる。
    func afterChange(summary: String?) async {
        let c = client
        await WidgetBridge.update(client: c, lastSummary: summary)
        let delay = await c.value { $0.nextCheckDelayMin() }
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
        notifications.onOpen = { info in
            NotificationCenter.default.post(name: .povoxOpenRoute, object: nil, userInfo: info)
        }
    }
}

extension Notification.Name {
    /// 通知をタップした(画面を切り替える合図)。
    static let povoxOpenRoute = Notification.Name("povoxOpenRoute")
}
