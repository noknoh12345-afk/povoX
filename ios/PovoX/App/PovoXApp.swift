import SwiftUI
import UIKit
import UserNotifications

@main
struct PovoXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: phase) { p in
            switch p {
            case .active:
                Task {
                    await model.reloadLocal()
                    await model.refresh(force: false)
                    model.startForegroundTimer()
                }
            case .background:
                model.stopForegroundTimer()
                Automation.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // バックグラウンド更新の登録は起動処理の中で済ませる必要がある。
        Automation.registerBackgroundTask()
        _ = Core.shared
        UNUserNotificationCenter.current().delegate = self
        Automation.requestNotificationPermission()
        Automation.scheduleBackgroundRefresh()
        return true
    }

    // アプリを開いているときも通知を出す。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

enum Theme {
    /// povo の黄色(公式アプリの値)。
    static let yellow = Color(red: 1.0, green: 0.961, blue: 0.0)
    static let ink = Color.primary
    static let groove = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : UIColor(red: 0.925, green: 0.941, blue: 0.957, alpha: 1) })
    static let danger = Color(red: 0.86, green: 0.18, blue: 0.2)
}
