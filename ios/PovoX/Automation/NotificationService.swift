import Foundation
import UserNotifications

/// 通知。確認待ちには「実行する / やめる」のボタンを付け、ロック画面から実行できるようにする。
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let confirmCategory = "POVOX_CONFIRM"
    static let threeDSCategory = "POVOX_3DS"
    static let executeAction = "POVOX_EXECUTE"
    static let dismissAction = "POVOX_DISMISS"

    /// 通知のボタン・タップを受けたときの処理(AppServices が設定する)。
    var onConfirm: ((String) async -> ActionOutcome?)?
    var onDismiss: ((String) async -> Void)?
    var onOpen: (([AnyHashable: Any]) -> Void)?
    /// 記録用(通知の操作を受け取ったことをログに残す)。
    var onLog: ((String) -> Void)?
    /// UI テストでは通知を出さない。
    var enabled = true

    private var center: UNUserNotificationCenter { .current() }

    func register() {
        center.delegate = self
        let execute = UNNotificationAction(identifier: NotificationService.executeAction, title: "実行する",
                                           options: [.authenticationRequired])
        let dismiss = UNNotificationAction(identifier: NotificationService.dismissAction, title: "やめる", options: [.destructive])
        let confirm = UNNotificationCategory(identifier: NotificationService.confirmCategory, actions: [execute, dismiss],
                                             intentIdentifiers: [], options: [])
        let open = UNNotificationAction(identifier: "POVOX_OPEN", title: "認証する", options: [.foreground])
        let threeDS = UNNotificationCategory(identifier: NotificationService.threeDSCategory, actions: [open],
                                             intentIdentifiers: [], options: [])
        center.setNotificationCategories([confirm, threeDS])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func post(_ list: [PlannedNotification]) async {
        guard enabled else { return }
        for n in list {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            var info: [String: String] = n.userInfo
            info["kind"] = n.kind.rawValue
            content.userInfo = info
            switch n.kind {
            case .confirm:
                content.categoryIdentifier = NotificationService.confirmCategory
                content.interruptionLevel = .timeSensitive
            case .threeDS:
                content.categoryIdentifier = NotificationService.threeDSCategory
            default:
                break
            }
            try? await center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
        }
    }

    func removeConfirmation(pendingID: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["pending-\(pendingID)"])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let pid = info["pending_id"] as? String
        onLog?("通知の操作を受け取りました: \(response.actionIdentifier)\(pid.map { "(\($0))" } ?? "")")
        switch response.actionIdentifier {
        case NotificationService.executeAction:
            guard let pid, let outcome = await onConfirm?(pid) else { return }
            await post([NotificationPlanner.plan(forConfirmed: outcome)])
        case NotificationService.dismissAction:
            if let pid { await onDismiss?(pid) }
        default:
            let handler = onOpen
            await MainActor.run { handler?(info) }
        }
    }
}
