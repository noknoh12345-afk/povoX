import Foundation
#if canImport(PovoX)
@testable import PovoX
#endif

/// 第1段の測定(起こされ方・通知の遅れ・通信量)の集計の検査。FlowLogicChecks と同じく iOS とパソコンの両方から呼ぶ。
enum WakeChecks {
    static func run(fail: (String) -> Void) {
        func expect(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { fail(msg()) } }
        let t0 = FlowLogicChecks.t0 // 2026-10-16 9:00 JST
        func ms(_ h: Double) -> Int64 { Int64((t0.timeIntervalSince1970 + h * 3600) * 1000) }
        let boot = ms(-100)
        func net(_ cell: UInt64, _ wifi: UInt64, boot b: Int64 = boot) -> NetSample {
            NetSample(cellIn: cell, cellOut: 0, wifiIn: wifi, wifiOut: 0, bootMs: b)
        }

        // 分位点・カウンタの一周
        expect(WakeStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5) == 5, "中央")
        expect(WakeStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9) == 9, "90%")
        expect(WakeStats.percentile([], 0.5) == nil, "空")
        expect(WakeStats.delta(4_294_967_000, 100) == 396, "32ビットの一周")
        expect(WakeStats.delta(100, 300) == 200, "ふつうの差")

        let MB: UInt64 = 1_048_576
        var ev: [WakeEvent] = [
            // 9時・10時・14時(昼に4時間あく)・14時半 に実行
            WakeEvent(kind: "run", tMs: ms(0), source: "background", requestedMs: nil, detail: nil, net: net(0, 0)),
            WakeEvent(kind: "run", tMs: ms(1), source: "foreground", requestedMs: nil, detail: nil, net: net(50 * MB, 10 * MB)),
            WakeEvent(kind: "run", tMs: ms(5), source: "flow:abc", requestedMs: nil, detail: nil, net: net(250 * MB, 10 * MB)),
            WakeEvent(kind: "run", tMs: ms(5.5), source: "wifi-off", requestedMs: nil, detail: nil, net: net(260 * MB, 10 * MB)),
            // 再起動(カウンタが 0 に戻る)→ その区間は数えない
            WakeEvent(kind: "app-active", tMs: ms(6), source: nil, requestedMs: nil, detail: nil, net: net(1 * MB, 0, boot: ms(5.8))),
            WakeEvent(kind: "app-active", tMs: ms(7), source: nil, requestedMs: nil, detail: nil, net: net(31 * MB, 0, boot: ms(5.8))),
            // バックグラウンド更新: 9:15 を頼んで 9:45 に起こされた
            WakeEvent(kind: "bg-launch", tMs: ms(0.75), source: "jp.povox.refresh", requestedMs: ms(0.25), detail: nil, net: nil),
            WakeEvent(kind: "bg-expired", tMs: ms(0.8), source: "jp.povox.refresh", requestedMs: nil, detail: nil, net: nil),
            // 通知: 2件予定・1件は入れ直しで外れた・1件は 30秒遅れで届いた
            WakeEvent(kind: "notif-scheduled", tMs: ms(0), source: "flow-sched-a-1", requestedMs: ms(3), detail: nil, net: nil),
            WakeEvent(kind: "notif-scheduled", tMs: ms(0), source: "flow-sched-b-1", requestedMs: ms(4), detail: nil, net: nil),
            WakeEvent(kind: "notif-cancelled", tMs: ms(2), source: "flow-sched-b-1", requestedMs: ms(4), detail: nil, net: nil),
            WakeEvent(kind: "notif-delivered", tMs: ms(3) + 30_000, source: "flow-sched-a-1", requestedMs: ms(3), detail: nil, net: nil),
        ]
        let r = WakeStats.report(ev, now: t0.addingTimeInterval(8 * 3600), days: 1)
        expect(r.runs == 4, "実行の回数: \(r.runs)")
        expect(r.runsBySource["オートメーション"] == 1 && r.runsBySource["ショートカット"] == 1, "きっかけ別: \(r.runsBySource)")
        expect(r.gapMaxMin == 240, "最長の間隔 240分: \(String(describing: r.gapMaxMin))")
        expect(r.daytimeGapsOver3h == 1, "昼の3時間以上の空き: \(r.daytimeGapsOver3h)")
        expect(r.bgLaunches == 1 && r.bgDelayP50Min == 30 && r.bgExpired == 1, "BG の遅れ 30分: \(String(describing: r.bgDelayP50Min))")
        expect(r.notifScheduled == 1 && r.notifDelivered == 1 && r.notifLateP50Sec == 30, "通知: 予定1(外れた1件は除く)・遅れ30秒: \(r.notifScheduled) \(String(describing: r.notifLateP50Sec))")
        let cell = r.cellularMBByDay["2026-10-16"] ?? -1
        expect(abs(cell - 290) < 0.01, "モバイル通信 260MB + 再起動後 30MB = 290MB(再起動をまたぐ区間は数えない): \(cell)")
        expect(abs((r.wifiMBByDay["2026-10-16"] ?? -1) - 10) < 0.01, "Wi-Fi 10MB")
        expect(WakeStats.lines(r).count >= 6, "報告の文")

        // 期間の外は数えない
        ev.append(WakeEvent(kind: "run", tMs: ms(-48), source: "background", requestedMs: nil, detail: nil, net: nil))
        expect(WakeStats.report(ev, now: t0.addingTimeInterval(8 * 3600), days: 1).runs == 4, "期間外")

        // 保存: 同じものは1回・上限
        let suite = "wakecheck-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        let log = WakeLog(defaults: ud)
        expect(log.appendOnce(ev[8]) && !log.appendOnce(ev[8]), "同じ予約は1回だけ")
        for i in 0..<(WakeLog.maxEvents + 5) { log.append(WakeEvent(kind: "run", tMs: Int64(i), source: nil, requestedMs: nil, detail: nil, net: nil)) }
        expect(log.events().count == WakeLog.maxEvents, "上限で古いものから捨てる")
        ud.removePersistentDomain(forName: suite)
    }
}
