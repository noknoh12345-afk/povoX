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
    /// 予約した通知の「実行する」(オートメーションの ID と、その回)。
    var onRunFlow: ((String, String?) async -> Void)?
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
        let run = UNNotificationAction(identifier: FlowScheduler.runAction, title: "実行する", options: [.authenticationRequired])
        let flow = UNNotificationCategory(identifier: FlowScheduler.category, actions: [run], intentIdentifiers: [], options: [])
        center.setNotificationCategories([confirm, threeDS, flow])
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
    //
    // async 版の delegate を使うと、システムの完了ハンドラが画面以外のスレッドから呼ばれ、
    // UIKit の「メインスレッドで呼ぶこと」の検査でアプリが落ちる(シミュレータの画面テストで見つけた)。
    // 完了ハンドラ版を使い、処理が終わってからメインスレッドで呼ぶ。

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let pid = info["pending_id"] as? String
        switch action {
        case NotificationService.executeAction: onLog?("通知の「実行する」が押されました")
        case NotificationService.dismissAction: onLog?("通知の「やめる」が押されました")
        case FlowScheduler.runAction: onLog?("オートメーションの通知の「実行する」が押されました")
        default: break
        }
        let done = { DispatchQueue.main.async { completionHandler() } }
        switch action {
        case NotificationService.executeAction:
            guard let pid, let confirm = onConfirm else { return done() }
            // 購入・適用が終わるまで完了ハンドラを呼ばない(その間 iOS がアプリを動かしておく)
            Task {
                if let outcome = await confirm(pid) {
                    await self.post([NotificationPlanner.plan(forConfirmed: outcome)])
                }
                done()
            }
        case FlowScheduler.runAction:
            guard let fid = info["flow_id"] as? String, let runFlow = onRunFlow else { return done() }
            let occ = info["occ"] as? String
            // 実行が終わるまで完了ハンドラを呼ばない(その間 iOS がアプリを動かしておく)
            Task {
                await runFlow(fid, occ)
                done()
            }
        case NotificationService.dismissAction:
            guard let pid, let dismiss = onDismiss else { return done() }
            Task {
                await dismiss(pid)
                done()
            }
        default:
            let handler = onOpen
            DispatchQueue.main.async {
                handler?(info)
                completionHandler()
            }
        }
    }
}
