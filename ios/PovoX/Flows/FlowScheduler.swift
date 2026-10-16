import Foundation
import UserNotifications

/// 時刻・予定・予約のオートメーションを、ローカル通知として予約する。
///
/// 無料の Apple ID ではサーバーからのプッシュが使えず、バックグラウンド更新の時刻も iOS 任せ。
/// 「決めた時刻に確実に知らせる」ことができるのはローカル通知だけなので、時刻のきっかけはここで予約する。
/// - 通知だけのオートメーション: 通知そのものが実行(中身は予約するときに作る)。
/// - povo・設定にかかわるもの: 「実行する」ボタン付き。押すとその場で実行(安全装置は通る)。
///   その前に自動チェックで実行できたときは、予約した通知を取り消す。
enum FlowScheduler {
    static let category = "POVOX_FLOW"
    static let runAction = "POVOX_FLOW_RUN"
    static let prefix = "flow-sched-"

    static func identifier(flowID: String, occurrence: String) -> String {
        "\(prefix)\(flowID)-\(occurrence)"
    }

    /// 予約を入れ直す(前の予約はすべて消す)。
    static func apply(_ items: [FlowScheduleItem], enabled: Bool, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let old = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        // 測定: 予約したのに入れ直しで外れた回(届かなくて当然のもの)を、届かなかった数に入れないため
        let keep = enabled ? Set(items.map { "\($0.id)@\(Int64($0.fireAt.timeIntervalSince1970 * 1000))" }) : []
        for r in pending where r.identifier.hasPrefix(prefix) {
            guard let at = (r.content.userInfo["at"] as? NSNumber)?.int64Value, !keep.contains("\(r.identifier)@\(at)") else { continue }
            WakeRecorder.cancelled(id: r.identifier, at: at)
        }
        guard enabled else { return }
        for it in items {
            let interval = it.fireAt.timeIntervalSince(now)
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = it.title
            content.body = it.body
            content.sound = .default
            content.userInfo = ["kind": "flow", "flow_id": it.flowID, "occ": it.occurrence, "route": "home",
                                "at": NSNumber(value: Int64(it.fireAt.timeIntervalSince1970 * 1000))]
            if it.runnable {
                content.categoryIdentifier = category
                content.interruptionLevel = .timeSensitive
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: it.id, content: content, trigger: trigger))
            WakeRecorder.scheduled(id: it.id, fireAt: it.fireAt)
        }
    }

    /// 自動チェックで実行できたら、その回の通知(予約・表示済み)を片付ける。
    static func remove(flowID: String, occurrence: String) {
        let id = identifier(flowID: flowID, occurrence: occurrence)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
