import SwiftUI
import UIKit

@main
struct PovoXApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active:
                Task {
                    await store.reload()
                    await store.refresh(force: false)
                    store.startForeground()
                    await AppServices.shared.rescheduleFlows()
                }
            case .background:
                store.stopForeground()
                Task { await AppServices.shared.afterChange(summary: store.runs.first?.summary) }
            default:
                break
            }
        }
    }

    private var scheme: ColorScheme? {
        let l = AppServices.shared.launch
        if l.forceDark { return .dark }
        if l.forceLight { return .light }
        return nil
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let services = AppServices.shared
        // バックグラウンド更新の登録は起動処理の中で済ませる必要がある。
        if !services.launch.uiTest {
            BackgroundScheduler.register {
                await services.automation.run(trigger: "background") != nil
            }
        }
        services.notifications.register()
        if services.launch.uiTestNotifications {
            Task { _ = await services.notifications.requestAuthorization() }
        }
        return true
    }
}
