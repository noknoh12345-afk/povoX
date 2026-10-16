import BackgroundTasks
import Foundation

/// バックグラウンド更新。iOS はアプリを常に動かせないので、iOS に「この時刻以降に起こして」と頼む。
/// 実際に起こされる時刻は iOS が決める(使い方によっては数時間空く)。
enum BackgroundScheduler {
    static let refreshID = "jp.povox.refresh"
    static let processingID = "jp.povox.check"

    /// アプリ起動の最初(didFinishLaunching)で1回だけ呼ぶ。
    /// バックグラウンド更新が使えない場所(Mac・LiveContainer)では何もしない。
    static func register(run: @escaping () async -> Bool) {
        guard Runtime.backgroundTasksAvailable else { return }
        for id in [refreshID, processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                // 第1段の測定: 頼んだ時刻(earliestBeginDate)に対して、実際にいつ起こされたか
                WakeRecorder.record("bg-launch", source: task.identifier, requested: nextScheduled)
                let work = Task {
                    let ok = await run()
                    task.setTaskCompleted(success: ok)
                }
                task.expirationHandler = {
                    WakeRecorder.record("bg-expired", source: task.identifier, withNet: false)
                    // povo への通信は途中で切らない(エンジンが1本ずつ・送る前に記録している)。
                    work.cancel()
                }
            }
        }
    }

    /// 次の自動チェックを予約する(前の予約は置き換える)。
    static func schedule(afterMinutes minutes: UInt32, enabled: Bool) {
        guard Runtime.backgroundTasksAvailable else { return }
        let s = BGTaskScheduler.shared
        s.cancel(taskRequestWithIdentifier: refreshID)
        s.cancel(taskRequestWithIdentifier: processingID)
        guard enabled else { return }
        let when = Date(timeIntervalSinceNow: TimeInterval(max(15, minutes)) * 60)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = when
        try? s.submit(refresh)
        // 充電中などに動く処理の枠でも頼んでおく(起こされる機会を増やす)
        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.earliestBeginDate = when
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? s.submit(processing)
        UserDefaults.standard.set(when, forKey: "bg.next")
    }

    static var nextScheduled: Date? {
        UserDefaults.standard.object(forKey: "bg.next") as? Date
    }
}
