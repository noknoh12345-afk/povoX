import Darwin
import Foundation
import os
import UserNotifications

/// 端末の通信量カウンタ(起動してからの累計)を読む。公開 API の getifaddrs で、権限は要らない。
/// pdp_ip* = モバイル通信、en* = Wi-Fi(と有線)。カウンタは 32 ビットで 4GB ごとに一周する。
enum NetCounters {
    static func read(now: Date = Date()) -> NetSample? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var s = NetSample(cellIn: 0, cellOut: 0, wifiIn: 0, wifiOut: 0,
                          bootMs: Int64((now.timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime) * 1000))
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let raw = cur.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("pdp_ip") {
                s.cellIn += UInt64(data.ifi_ibytes)
                s.cellOut += UInt64(data.ifi_obytes)
            } else if name.hasPrefix("en") {
                s.wifiIn += UInt64(data.ifi_ibytes)
                s.wifiOut += UInt64(data.ifi_obytes)
            }
        }
        return s
    }
}

/// 起こされた・実行した・通知が届いた、を記録する(端末の中だけ。os_log にも出す)。
enum WakeRecorder {
    static let logger = Logger(subsystem: "jp.povox.app", category: "wake")
    /// 記録先(AppServices が設定する。UI テストでは設定しない)。
    static var log: WakeLog?

    static func record(_ kind: String, source: String? = nil, requested: Date? = nil, detail: String? = nil, at: Date = Date(), withNet: Bool = true) {
        let e = WakeEvent(kind: kind, tMs: ms(at), source: source, requestedMs: requested.map(ms), detail: detail,
                          net: withNet ? NetCounters.read(now: at) : nil)
        log?.append(e)
        logger.log("\(kind, privacy: .public) src=\(source ?? "-", privacy: .public) req=\(e.requestedMs ?? 0, privacy: .public) t=\(e.tMs, privacy: .public)")
    }

    /// 予約した通知を記録する(同じ ID・同じ時刻は1回だけ)。
    static func scheduled(id: String, fireAt: Date) {
        let e = WakeEvent(kind: "notif-scheduled", tMs: ms(Date()), source: id, requestedMs: ms(fireAt), detail: nil, net: nil)
        log?.appendOnce(e)
    }

    /// 予約を取り消した(入れ直しで外れた)通知。
    static func cancelled(id: String, at: Int64) {
        log?.appendOnce(WakeEvent(kind: "notif-cancelled", tMs: ms(Date()), source: id, requestedMs: at, detail: nil, net: nil))
    }

    /// 通知センターに残っている povoX の予約通知から、届いた時刻を拾う(同じものは1回だけ)。
    static func collectDelivered() async {
        guard let log else { return }
        let list = await UNUserNotificationCenter.current().deliveredNotifications()
        for n in list where n.request.identifier.hasPrefix(FlowScheduler.prefix) {
            let at = (n.request.content.userInfo["at"] as? NSNumber)?.int64Value
            let e = WakeEvent(kind: "notif-delivered", tMs: ms(n.date), source: n.request.identifier, requestedMs: at, detail: nil, net: nil)
            if log.appendOnce(e) {
                logger.log("notif-delivered id=\(n.request.identifier, privacy: .public) late=\((ms(n.date) - (at ?? ms(n.date))) / 1000, privacy: .public)s")
            }
        }
    }

    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
}
