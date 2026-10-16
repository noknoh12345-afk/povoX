import Foundation

// 第1段「前提の測定」: povoX が実際にいつ起こされたか・予約した通知がいつ届いたか・
// 端末の通信量カウンタ(モバイル/Wi-Fi)を、端末の中に記録する。
//
// povoX の先回りは「バックグラウンド更新」と「時刻の通知」に乗っている。どちらも iOS 任せなので、
// 推測ではなく、実機で何が起きたかを数字で見る。
// 通信量カウンタは、povo の残量が減らない使い放題中の使用量も測れる、povo とは独立した物差し。
// Foundation だけを使う(集計はパソコン上でも検査できる)。

/// 通信量カウンタの読み(起動してからの累計バイト)。
struct NetSample: Codable, Equatable {
    var cellIn: UInt64
    var cellOut: UInt64
    var wifiIn: UInt64
    var wifiOut: UInt64
    /// 端末が起動した時刻(ミリ秒)。違えば再起動でカウンタが 0 に戻っている。
    var bootMs: Int64
}

struct WakeEvent: Codable, Equatable {
    /// "bg-launch" / "bg-expired" / "run" / "app-active" / "notif-scheduled" / "notif-cancelled" / "notif-delivered"
    var kind: String
    var tMs: Int64
    /// BGTask の識別子・実行のきっかけ・通知の ID。
    var source: String?
    /// 頼んだ時刻(BGTask の earliestBeginDate・通知の予定時刻)。
    var requestedMs: Int64?
    var detail: String?
    var net: NetSample?
}

/// 記録の保存(UserDefaults に JSON。古いものから捨てる)。
final class WakeLog {
    static let maxEvents = 6000
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let key = "wake.log.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func events() -> [WakeEvent] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func load() -> [WakeEvent] {
        guard let d = defaults.data(forKey: WakeLog.key), let v = try? JSONDecoder().decode([WakeEvent].self, from: d) else { return [] }
        return v
    }

    private func store(_ v: [WakeEvent]) {
        if let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: WakeLog.key) }
    }

    func append(_ e: WakeEvent) {
        lock.lock(); defer { lock.unlock() }
        var v = load()
        v.append(e)
        if v.count > WakeLog.maxEvents { v.removeFirst(v.count - WakeLog.maxEvents) }
        store(v)
    }

    /// まだ記録していなければ足す(同じ種類・同じ ID・同じ予定時刻は1回だけ)。足したら true。
    @discardableResult
    func appendOnce(_ e: WakeEvent) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var v = load()
        if v.contains(where: { $0.kind == e.kind && $0.source == e.source && $0.requestedMs == e.requestedMs }) { return false }
        v.append(e)
        if v.count > WakeLog.maxEvents { v.removeFirst(v.count - WakeLog.maxEvents) }
        store(v)
        return true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: WakeLog.key)
    }
}

/// 記録の集計(第1段の報告に使う数字)。
struct WakeReport: Codable, Equatable {
    var fromMs: Int64
    var toMs: Int64
    var days: Double
    /// 自動チェック(実行)の回数ときっかけ別の内訳。
    var runs: Int
    var runsBySource: [String: Int]
    /// 実行と実行のあいだ(分)。
    var gapP50Min: Double?
    var gapP90Min: Double?
    var gapMaxMin: Double?
    /// 昼(7〜23時)に3時間以上あいた回数。外出中に気づけない時間の目安。
    var daytimeGapsOver3h: Int
    /// 1時間ごとに区切って、1回以上チェックがあった割合(昼だけ)。
    var daytimeHourCoverage: Double?
    /// バックグラウンド更新: 起こされた回数と、頼んだ時刻からの遅れ(分)。
    var bgLaunches: Int
    var bgDelayP50Min: Double?
    var bgDelayP90Min: Double?
    var bgExpired: Int
    /// 予約した通知: 予定の数・届いたと記録できた数・予定時刻からの遅れ(秒)。
    var notifScheduled: Int
    var notifDelivered: Int
    var notifLateP50Sec: Double?
    var notifLateP90Sec: Double?
    var notifLateMaxSec: Double?
    /// 通信量カウンタ: 記録の数と、日ごとのモバイル通信(MB、JST の日付)。
    var netSamples: Int
    var cellularMBByDay: [String: Double]
    var wifiMBByDay: [String: Double]
}

enum WakeStats {
    /// 最も近い順位の分位点(p は 0〜1)。
    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up)) - 1
        return s[max(0, min(s.count - 1, rank))]
    }

    /// 32ビットのカウンタの差(一周したら 2^32 を足す。再起動したら数えない)。
    static func delta(_ a: UInt64, _ b: UInt64) -> UInt64 {
        if b >= a { return b - a }
        let wrap: UInt64 = 1 << 32
        return a < wrap && b < wrap ? b + wrap - a : 0
    }

    static func report(_ all: [WakeEvent], now: Date, days: Double = 7) -> WakeReport {
        let toMs = Int64(now.timeIntervalSince1970 * 1000)
        let fromMs = toMs - Int64(days * 86_400_000)
        let ev = all.filter { $0.tMs >= fromMs && $0.tMs <= toMs }.sorted { $0.tMs < $1.tMs }
        let runs = ev.filter { $0.kind == "run" }
        var bySource: [String: Int] = [:]
        for r in runs { bySource[category(r.source ?? ""), default: 0] += 1 }
        let gaps = zip(runs, runs.dropFirst()).map { Double($1.tMs - $0.tMs) / 60_000 }

        // 昼(7〜23時)の空き
        var dayGaps = 0
        for (a, b) in zip(runs, runs.dropFirst()) where b.tMs - a.tMs >= 3 * 3_600_000 {
            if overlapsDaytime(a.tMs, b.tMs) { dayGaps += 1 }
        }
        // 昼の1時間ごとの網羅
        var dayHours = 0, covered = 0
        var h = (fromMs / 3_600_000 + 1) * 3_600_000
        let runTimes = runs.map(\.tMs)
        while h + 3_600_000 <= toMs {
            if isDaytime(h) {
                dayHours += 1
                if runTimes.contains(where: { $0 >= h && $0 < h + 3_600_000 }) { covered += 1 }
            }
            h += 3_600_000
        }

        let bg = ev.filter { $0.kind == "bg-launch" }
        let bgDelays = bg.compactMap { e in e.requestedMs.map { Double(e.tMs - $0) / 60_000 } }
        func key(_ e: WakeEvent) -> String? { e.source.map { "\($0)@\(e.requestedMs ?? 0)" } }
        let cancelled = Set(all.filter { $0.kind == "notif-cancelled" }.compactMap(key))
        let sched = Set(ev.filter { $0.kind == "notif-scheduled" && ($0.requestedMs ?? Int64.max) <= toMs }.compactMap(key))
            .subtracting(cancelled)
        let delivered = ev.filter { $0.kind == "notif-delivered" }
        let late = delivered.compactMap { e in e.requestedMs.map { Double(e.tMs - $0) / 1000 } }

        // 通信量
        let nets = ev.compactMap { e in e.net.map { (e.tMs, $0) } }
        var cell: [String: Double] = [:], wifi: [String: Double] = [:]
        for (a, b) in zip(nets, nets.dropFirst()) where a.1.bootMs == b.1.bootMs || abs(a.1.bootMs - b.1.bootMs) < 5_000 {
            let day = dayKey(b.0)
            let c = delta(a.1.cellIn, b.1.cellIn) + delta(a.1.cellOut, b.1.cellOut)
            let w = delta(a.1.wifiIn, b.1.wifiIn) + delta(a.1.wifiOut, b.1.wifiOut)
            cell[day, default: 0] += Double(c) / 1_048_576
            wifi[day, default: 0] += Double(w) / 1_048_576
        }

        return WakeReport(
            fromMs: fromMs, toMs: toMs, days: days,
            runs: runs.count, runsBySource: bySource,
            gapP50Min: percentile(gaps, 0.5), gapP90Min: percentile(gaps, 0.9), gapMaxMin: gaps.max(),
            daytimeGapsOver3h: dayGaps, daytimeHourCoverage: dayHours > 0 ? Double(covered) / Double(dayHours) : nil,
            bgLaunches: bg.count, bgDelayP50Min: percentile(bgDelays, 0.5), bgDelayP90Min: percentile(bgDelays, 0.9),
            bgExpired: ev.filter { $0.kind == "bg-expired" }.count,
            notifScheduled: sched.count, notifDelivered: delivered.count,
            notifLateP50Sec: percentile(late, 0.5), notifLateP90Sec: percentile(late, 0.9), notifLateMaxSec: late.max(),
            netSamples: nets.count, cellularMBByDay: cell, wifiMBByDay: wifi)
    }

    /// 実行のきっかけを大まかに分ける。
    static func category(_ trigger: String) -> String {
        if trigger.hasPrefix("flow:") { return "オートメーション" }
        switch trigger {
        case "background": return "バックグラウンド更新"
        case "foreground": return "アプリ表示中"
        case "manual": return "手動"
        case "試運転": return "試運転"
        case "location", "location-arrive", "location-leave": return "位置情報"
        default: return "ショートカット"
        }
    }

    static func isDaytime(_ ms: Int64) -> Bool {
        let h = DayPlanner.tokyo.component(.hour, from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return h >= 7 && h < 23
    }

    static func overlapsDaytime(_ a: Int64, _ b: Int64) -> Bool {
        var t = a
        while t < b {
            if isDaytime(t) { return true }
            t += 1_800_000
        }
        return false
    }

    static func dayKey(_ ms: Int64) -> String {
        FlowEngine.dayKey(Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// 報告の文(画面と書き出しに使う)。数字が無いところは「まだ記録がない」と言う。
    static func lines(_ r: WakeReport) -> [String] {
        func m(_ x: Double?) -> String { x.map { $0 >= 120 ? String(format: "%.1f時間", $0 / 60) : "\(Int($0.rounded()))分" } ?? "—" }
        func s(_ x: Double?) -> String { x.map { $0 >= 120 ? "\(Int(($0 / 60).rounded()))分" : "\(Int($0.rounded()))秒" } ?? "—" }
        var out: [String] = []
        let perDay = r.days > 0 ? Double(r.runs) / r.days : 0
        out.append("自動チェック \(r.runs)回(1日あたり \(String(format: "%.1f", perDay))回)")
        if !r.runsBySource.isEmpty {
            out.append("内訳: " + r.runsBySource.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "・"))
        }
        out.append("間隔: 中央 \(m(r.gapP50Min))・90% \(m(r.gapP90Min))・最長 \(m(r.gapMaxMin))")
        out.append("昼(7〜23時)に3時間以上あいた: \(r.daytimeGapsOver3h)回" + (r.daytimeHourCoverage.map { "・昼の1時間ごとの網羅 \(Int(($0 * 100).rounded()))%" } ?? ""))
        out.append("バックグラウンド更新: \(r.bgLaunches)回・頼んだ時刻からの遅れ 中央 \(m(r.bgDelayP50Min))・90% \(m(r.bgDelayP90Min))・時間切れ \(r.bgExpired)回")
        out.append("予約した通知: 予定 \(r.notifScheduled)件・届いた記録 \(r.notifDelivered)件・遅れ 中央 \(s(r.notifLateP50Sec))・90% \(s(r.notifLateP90Sec))・最大 \(s(r.notifLateMaxSec))")
        if r.netSamples > 1 {
            let c = r.cellularMBByDay.values.reduce(0, +)
            out.append("通信量カウンタ \(r.netSamples)回分: モバイル通信 合計 \(Int(c.rounded()))MB(\(r.cellularMBByDay.count)日)")
        } else {
            out.append("通信量カウンタ: まだ記録がありません")
        }
        return out
    }
}
