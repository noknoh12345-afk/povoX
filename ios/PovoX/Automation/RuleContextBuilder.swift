import Foundation

/// 端末の状態(ルールの ctx.battery / ctx.network)。
struct DeviceState: Equatable {
    var batteryLevel: Int?
    var charging: Bool
    var full: Bool
    var lowPower: Bool
    /// "wifi" / "cellular" / "wired" / "none" / "unknown"
    var network: String

    static let unknown = DeviceState(batteryLevel: nil, charging: false, full: false, lowPower: false, network: "unknown")
}

/// エンジンが作った ctx(残量・予測・コード・予算)に、端末と時刻の情報を足す。
enum RuleContextBuilder {
    static func merge(engineContextJSON: String, trigger: String, device: DeviceState, now: Date, args: [String: String] = [:]) -> String {
        var ctx = (try? JSONSerialization.jsonObject(with: Data(engineContextJSON.utf8))) as? [String: Any] ?? [:]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        ctx["trigger"] = trigger
        ctx["battery"] = [
            "level": device.batteryLevel.map { $0 as Any } ?? NSNull(),
            "charging": device.charging,
            "full": device.full,
            "lowPower": device.lowPower,
        ] as [String: Any]
        ctx["network"] = device.network
        ctx["now"] = [
            "hour": c.hour ?? 0,
            "minute": c.minute ?? 0,
            "weekday": (c.weekday ?? 1) - 1,
            "date": String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
            "ms": Int64(now.timeIntervalSince1970 * 1000),
        ] as [String: Any]
        ctx["args"] = args
        guard let data = try? JSONSerialization.data(withJSONObject: ctx), let s = String(data: data, encoding: .utf8) else {
            return engineContextJSON
        }
        return s
    }
}
