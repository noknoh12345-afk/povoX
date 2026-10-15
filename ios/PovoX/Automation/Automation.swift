import BackgroundTasks
import Foundation
import Network
import UIKit
import UserNotifications

/// 自動チェック(スクリプト実行)の入口。きっかけはどれでもここを通る:
/// バックグラウンド更新 / ショートカット / アプリを開いている間のタイマー / 手動 / 試運転。
final class Automation {
    static let shared = Automation()
    static let refreshTaskID = "jp.povox.refresh"

    private let runLock = NSLock()
    private var running = false
    private let queue = DispatchQueue(label: "povox.script", qos: .utility)
    private let monitor = NWPathMonitor()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.path = p }
        monitor.start(queue: DispatchQueue(label: "povox.network"))
    }

    // MARK: - 設定(アプリ側)

    static var script: String {
        get { UserDefaults.standard.string(forKey: "script") ?? DefaultScript.text }
        set { UserDefaults.standard.set(newValue, forKey: "script") }
    }

    static var backgroundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "bgEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bgEnabled") }
    }

    /// バックグラウンド更新・画面表示中の自動チェックの間隔(分)。
    static var intervalMinutes: Int {
        get { max(15, UserDefaults.standard.object(forKey: "intervalMin") as? Int ?? 30) }
        set { UserDefaults.standard.set(max(15, newValue), forKey: "intervalMin") }
    }

    static var foregroundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "fgEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fgEnabled") }
    }

    static var notifyErrors: Bool {
        get { UserDefaults.standard.object(forKey: "notifyErrors") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyErrors") }
    }

    static var lastRun: Date? {
        get { UserDefaults.standard.object(forKey: "lastRun") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastRun") }
    }

    static var lastReportText: String? {
        get { UserDefaults.standard.string(forKey: "lastReport") }
        set { UserDefaults.standard.set(newValue, forKey: "lastReport") }
    }

    // MARK: - 実行

    /// スクリプトを1回動かす。同時には1つだけ(重なったら後のほうは何もしない)。
    func run(trigger: String, forceDryRun: Bool = false, args: [String: Any] = [:]) async -> RunReport {
        guard tryBegin() else {
            return RunReport(ok: false, summary: "前の自動チェックがまだ動いています", lines: [], startedAt: Date(), trigger: trigger)
        }
        defer { end() }

        let device = await MainActor.run { DeviceInfo.current() }
        let network = await currentNetwork()
        let context = makeContext(trigger: trigger, forceDryRun: forceDryRun, device: device, network: network, args: args)
        let script = Automation.script
        _ = Core.shared.call("log", ["level": "info", "message": "自動チェック開始(\(Automation.triggerLabel(trigger)))"])

        let report: RunReport = await withCheckedContinuation { cont in
            queue.async {
                let r = ScriptRunner.run(script: script, context: context, forceDryRun: forceDryRun, trigger: trigger) { title, body in
                    Automation.postNotification(title: title, body: body)
                }
                cont.resume(returning: r)
            }
        }
        if trigger != "test" {
            Automation.lastRun = report.startedAt
        }
        Automation.lastReportText = (report.ok ? "" : "⚠️ ") + report.summary
        if !report.ok && Automation.notifyErrors && trigger != "test" && trigger != "manual" {
            Automation.postNotification(title: "povoX: 自動チェックでエラー", body: report.summary)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .povoxDidRun, object: nil)
        }
        return report
    }

    private func tryBegin() -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func end() {
        runLock.lock()
        running = false
        runLock.unlock()
    }

    static func triggerLabel(_ t: String) -> String {
        switch t {
        case "background": return "バックグラウンド更新"
        case "shortcut": return "ショートカット"
        case "foreground": return "アプリ表示中"
        case "manual": return "手動"
        case "test": return "試運転"
        default: return t
        }
    }

    private func makeContext(trigger: String, forceDryRun: Bool, device: DeviceInfo, network: String, args: [String: Any]) -> [String: Any] {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let settingsDry: Bool = {
            if case .success(let s) = Core.shared.decode("settings", as: EngineSettings.self) { return s.dryRun }
            return true
        }()
        var battery: [String: Any] = ["charging": device.charging, "full": device.full, "lowPower": device.lowPower]
        battery["level"] = device.level.map { $0 as Any } ?? NSNull()
        return [
            "trigger": trigger,
            "battery": battery,
            "network": network,
            "now": ["hour": c.hour ?? 0, "minute": c.minute ?? 0, "weekday": (c.weekday ?? 1) - 1, "date": date,
                    "ms": Int64(now.timeIntervalSince1970 * 1000)],
            "lastRun": Automation.lastRun.map { Int64($0.timeIntervalSince1970 * 1000) as Any } ?? NSNull(),
            "dryRun": forceDryRun || settingsDry,
            "mock": Core.shared.mock,
            "args": args,
        ]
    }

    private func currentNetwork() async -> String {
        for _ in 0..<10 {
            if let p = path { return Automation.describe(p) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Automation.describe(monitor.currentPath)
    }

    private static func describe(_ p: NWPath) -> String {
        guard p.status == .satisfied else { return "none" }
        if p.usesInterfaceType(.wifi) { return "wifi" }
        if p.usesInterfaceType(.cellular) { return "cellular" }
        if p.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "unknown"
    }

    // MARK: - 通知

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - バックグラウンド更新

    /// アプリ起動の最初(App の init)で1回だけ呼ぶ。
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func scheduleBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
        guard backgroundEnabled else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(intervalMinutes * 60))
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            _ = Core.shared.call("log", ["level": "warn", "message": "バックグラウンド更新を予約できませんでした: \(error.localizedDescription)"])
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task {
            let report = await Automation.shared.run(trigger: "background")
            task.setTaskCompleted(success: report.ok)
        }
        task.expirationHandler = {
            // povo への通信は途中で切らない(Rust 側で1本ずつ・送信前に記録済み)。
            // 時間切れは iOS に伝えるだけにする。
            work.cancel()
            _ = Core.shared.call("log", ["level": "warn", "message": "バックグラウンドの持ち時間が切れました"])
        }
    }
}

extension Notification.Name {
    static let povoxDidRun = Notification.Name("povoxDidRun")
}

struct DeviceInfo {
    let level: Int?
    let charging: Bool
    let full: Bool
    let lowPower: Bool

    @MainActor
    static func current() -> DeviceInfo {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let raw = d.batteryLevel
        let level: Int? = raw < 0 ? nil : Int((raw * 100).rounded())
        return DeviceInfo(level: level,
                          charging: d.batteryState == .charging || d.batteryState == .full,
                          full: d.batteryState == .full,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
