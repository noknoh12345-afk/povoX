import Foundation
import WidgetKit

/// ウィジェットへ残量を渡す(App Group の共有フォルダ)。署名の仕方によっては App Group が
/// 使えないことがあり、そのときはウィジェットに「アプリを開いて」と出るだけでアプリは普通に動く。
enum WidgetBridge {
    static var available: Bool { SharedSnapshot.containerURL != nil }

    static func update(client: EngineClient, lastSummary: String?) async {
        guard available else { return }
        let (snap, insights, status) = await client.value { e in (e.cachedSnapshot(), e.insights(), e.status()) }
        guard status.loggedIn else { return }
        let shared = SharedSnapshot(
            updatedAt: snap.map { Fmt.date(ms: $0.fetchedMs) } ?? Date(),
            leftKB: snap?.leftKb,
            planKB: snap?.planKb,
            unlimitedActive: snap?.unlimited.active == true,
            unlimitedUntil: snap?.unlimited.untilMs.map { Fmt.date(ms: $0) },
            hoursLeft: insights.hoursLeft,
            pendingCount: Int(status.pendingActions),
            mock: status.mock,
            lastSummary: lastSummary)
        if shared.save() {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
