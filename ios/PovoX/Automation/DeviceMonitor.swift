import Foundation
import Network
import UIKit

/// 電池とネットワークの状態(ルールの ctx.battery / ctx.network)。
final class DeviceMonitor {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    /// UI テスト・デモ用の固定値。
    var override: DeviceState?

    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock()
            self.path = p
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "povox.network"))
    }

    private var currentPath: NWPath? {
        lock.lock(); defer { lock.unlock() }
        return path
    }

    private static func describe(_ p: NWPath) -> String {
        guard p.status == .satisfied else { return "none" }
        if p.usesInterfaceType(.wifi) { return "wifi" }
        if p.usesInterfaceType(.cellular) { return "cellular" }
        if p.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "unknown"
    }

    @MainActor
    private static func battery() -> (Int?, Bool, Bool, Bool) {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        let raw = d.batteryLevel
        let level: Int? = raw < 0 ? nil : Int((raw * 100).rounded())
        return (level, d.batteryState == .charging || d.batteryState == .full, d.batteryState == .full,
                ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func current() async -> DeviceState {
        if let o = override { return o }
        let (level, charging, full, low) = await MainActor.run { DeviceMonitor.battery() }
        var net = "unknown"
        for _ in 0..<10 {
            if let p = currentPath {
                net = DeviceMonitor.describe(p)
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return DeviceState(batteryLevel: level, charging: charging, full: full, lowPower: low, network: net)
    }
}
