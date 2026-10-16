import Foundation

/// オートメーションの記憶(前回の状態・いつ動いたか)。自動チェックのたびに更新する。
struct FlowMemory: Codable, Equatable {
    /// きっかけが「もう一度動ける」状態か(下回った → 戻った → また下回ったら動く)。
    var armed: [String: Bool] = [:]
    var lastFiredMs: [String: Int64] = [:]
    /// 1回きりのきっかけ(時刻・予定・予約)ですでに動いたもの。"flowID|回" → ミリ秒。
    var fired: [String: Int64] = [:]
    var count: [String: Int] = [:]
    var lastResult: [String: String] = [:]

    mutating func prune(now: Date) {
        let limit = Int64(now.timeIntervalSince1970 * 1000) - 4 * 86_400_000
        fired = fired.filter { $0.value >= limit }
    }

    func wasFired(_ flowID: String, _ occurrence: String) -> Bool {
        fired["\(flowID)|\(occurrence)"] != nil
    }
}

/// 動くことになったオートメーション。
struct FlowFiring {
    var flow: Flow
    /// なぜ動いたか(履歴に残す)。
    var reason: String
    /// 予定がきっかけのとき、その予定。
    var event: CalEvent?
    /// 1回きりのきっかけの「回」(日付・予定・予約)。
    var occurrence: String?
}

struct FlowEvaluation {
    var firings: [FlowFiring] = []
    var logs: [String] = []
    var memory: FlowMemory
}

/// 端末側で行うこと(設定の切り替えなど。povo には送らない)。
enum FlowEffect: Equatable {
    case purchaseMode(String)
    case codeMode(String)
    case flowEnabled(String, Bool)
}

/// 予約しておく通知(時刻・予定・予約のきっかけ)。
struct FlowScheduleItem: Equatable {
    var id: String
    var flowID: String
    var fireAt: Date
    var title: String
    var body: String
    /// 「実行する」ボタンで実行する(通知だけのオートメーションは通知そのものが実行)。
    var runnable: Bool
    var occurrence: String
}

enum FlowEngine {
    /// 時刻のきっかけを、遅れて起こされても動かしてよい長さ。
    static let graceMin = 90
    /// 予約を過ぎても動かしてよい長さ。
    static let onceGraceMin = 6 * 60

    static let wifiOffTriggers: Set<String> = ["wifi-off", "wifi_off", "wifi-disconnect", "leave-wifi"]
    static let wifiOnTriggers: Set<String> = ["wifi-on", "wifi_on", "wifi-connect", "join-wifi"]
    static let unplugTriggers: Set<String> = ["unplugged", "charger-off", "power-off", "unplug"]

    // MARK: - 評価

    /// どのオートメーションが今動くかを決める。
    /// - forcedID: ボタン・通知・Siri から決め打ちで動かすオートメーション(きっかけは見ない。条件は見る)。
    /// - simulate: シミュレーター(記憶を使わず、きっかけは「今そうなった」とみなす)。
    static func evaluate(flows: [Flow], facts: FlowFacts, memory: FlowMemory, forcedID: String? = nil,
                         occurrence: String? = nil, simulate: Bool = false) -> FlowEvaluation {
        var mem = memory
        mem.prune(now: facts.now)
        var out = FlowEvaluation(memory: mem)
        let nowMs = Int64(facts.now.timeIntervalSince1970 * 1000)

        if let forcedID {
            guard let flow = flows.first(where: { $0.id == forcedID }) else {
                out.logs.append("オートメーションが見つかりません(消された可能性)")
                return out
            }
            if let occ = occurrence, !simulate, mem.wasFired(flow.id, occ) {
                out.logs.append("「\(flow.name)」はこの回はもう実行しました")
                return out
            }
            let (ok, why) = conditionsHold(flow, facts: facts, at: facts.now)
            guard ok else {
                out.logs.append("「\(flow.name)」は条件に合わないので実行しませんでした(\(why))")
                return out
            }
            let event = occurrence.flatMap { occ in facts.events.first { occurrenceKey(event: $0) == occ } }
            out.firings.append(FlowFiring(flow: flow, reason: occurrence == nil ? "ボタンから実行" : "通知から実行", event: event, occurrence: occurrence))
            return out
        }

        for flow in flows where flow.enabled {
            guard let m = match(flow, facts: facts, memory: &out.memory, simulate: simulate) else { continue }
            // 間隔
            if !simulate, flow.cooldownMin > 0, let last = out.memory.lastFiredMs[flow.id],
               nowMs - last < Int64(flow.cooldownMin) * 60_000 {
                out.logs.append("「\(flow.name)」: \(m.reason)。ただし前回から\(flow.cooldownMin)分たっていないので待ちます")
                continue
            }
            let (ok, why) = conditionsHold(flow, facts: facts, at: facts.now)
            if FlowEngine.isEvent(flow.trigger.kind) || m.occurrence != nil {
                // 一瞬のきっかけ: 条件に合わなくても、この回はおしまい
                out.memory.armed[flow.id] = false
                if let occ = m.occurrence, !ok, !simulate { out.memory.fired["\(flow.id)|\(occ)"] = nowMs }
            }
            guard ok else {
                out.logs.append("「\(flow.name)」: \(m.reason)。ただし条件に合いません(\(why))")
                continue
            }
            if isLevel(flow.trigger.kind) { out.memory.armed[flow.id] = false }
            out.firings.append(FlowFiring(flow: flow, reason: m.reason, event: m.event, occurrence: m.occurrence))
        }
        return out
    }

    /// 動いたことを記憶に残す(本番の実行のあとだけ)。
    static func recordFired(_ firings: [FlowFiring], summary: String, memory: inout FlowMemory, now: Date) {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        for f in firings {
            memory.lastFiredMs[f.flow.id] = ms
            memory.count[f.flow.id, default: 0] += 1
            memory.lastResult[f.flow.id] = String(summary.prefix(120))
            if let occ = f.occurrence { memory.fired["\(f.flow.id)|\(occ)"] = ms }
            if isLevel(f.flow.trigger.kind) || isEvent(f.flow.trigger.kind) { memory.armed[f.flow.id] = false }
        }
    }

    /// 値の境目をまたいだときに動くきっかけ(戻ったらまた動けるようになる)。
    static func isLevel(_ k: FlowTriggerKind) -> Bool {
        [.dataBelow, .hoursLeftBelow, .unlimitedEnding, .batteryBelow, .usedTodayAbove].contains(k)
    }

    /// 状態が変わった瞬間のきっかけ。
    static func isEvent(_ k: FlowTriggerKind) -> Bool {
        [.unlimitedEnded, .leftWifi, .joinedWifi, .unplugged].contains(k)
    }

    private struct Match {
        var reason: String
        var event: CalEvent?
        var occurrence: String?
    }

    /// きっかけが成り立つか(記憶の「動ける」状態も更新する)。
    private static func match(_ flow: Flow, facts: FlowFacts, memory: inout FlowMemory, simulate: Bool) -> Match? {
        let t = flow.trigger
        let id = flow.id
        let tr = facts.trigger

        // 状態の変化を見るきっかけ: 「今の状態」と「動ける状態か」で決める
        func edge(_ state: Bool?, armWhenFalse: Bool = true, reason: String) -> Match? {
            guard let state else { return nil }
            let initial = isLevel(t.kind)  // 境目のきっかけは最初から動ける。変化のきっかけは一度逆の状態を見てから。
            let armed = simulate ? true : (memory.armed[id] ?? initial)
            if !state {
                if armWhenFalse { memory.armed[id] = true }
                return nil
            }
            return armed ? Match(reason: reason) : nil
        }

        switch t.kind {
        case .manual:
            return nil
        case .anyCheck:
            return Match(reason: "自動チェック(\(triggerName(tr)))")
        case .dataBelow:
            let gb = t.gb ?? 0.1
            guard facts.unlimitedActive != true else { memory.armed[id] = true; return nil }
            return edge(facts.leftGB.map { $0 < gb }, reason: "残り \(gbText(facts.leftGB)) が \(gbText(gb)) を下回りました")
        case .hoursLeftBelow:
            let h = t.hours ?? 3
            guard facts.unlimitedActive != true else { memory.armed[id] = true; return nil }
            return edge(facts.hoursLeft.map { $0 < h }, reason: "このペースで あと約\(hoursText(facts.hoursLeft))")
        case .unlimitedEnding:
            let m = Double(t.minutes ?? 10)
            let st: Bool? = facts.unlimitedActive == true ? facts.unlimitedHoursLeft.map { $0 * 60 <= m } : (facts.unlimitedActive == false ? false : nil)
            return edge(st, reason: "使い放題の残りが\(Int(m))分を切りました")
        case .unlimitedEnded:
            if facts.unlimitedActive == true { memory.armed[id] = true; return nil }
            return edge(facts.unlimitedActive.map { !$0 }, armWhenFalse: false, reason: "使い放題が終わりました")
        case .leftWifi:
            if wifiOffTriggers.contains(tr) { return Match(reason: "Wi-Fi から離れました(ショートカット)") }
            if facts.network == "wifi" { memory.armed[id] = true; return nil }
            return edge(facts.network == "cellular" ? true : nil, armWhenFalse: false, reason: "Wi-Fi から離れました")
        case .joinedWifi:
            if wifiOnTriggers.contains(tr) { return Match(reason: "Wi-Fi につながりました(ショートカット)") }
            if facts.network == "cellular" { memory.armed[id] = true; return nil }
            return edge(facts.network == "wifi" ? true : nil, armWhenFalse: false, reason: "Wi-Fi につながりました")
        case .batteryBelow:
            let p = t.percent ?? 20
            if tr == "battery-low" && !facts.charging { return Match(reason: "電池が少なくなりました(ショートカット)") }
            return edge(facts.battery.map { $0 <= p && !facts.charging }, reason: "電池が\(facts.battery ?? 0)%(\(p)%以下)")
        case .unplugged:
            if unplugTriggers.contains(tr) { return Match(reason: "充電器を外しました(ショートカット)") }
            if facts.charging { memory.armed[id] = true; return nil }
            return edge(true, armWhenFalse: false, reason: "充電器を外しました")
        case .usedTodayAbove:
            let mb = Double(t.mb ?? 1000)
            return edge(facts.usedTodayMB.map { $0 >= mb }, reason: "今日 \(Int(facts.usedTodayMB ?? 0))MB 使いました")
        case .arrive:
            return tr == "location-arrive" ? Match(reason: "どこかに着きました") : nil
        case .leave:
            return tr == "location-leave" || tr == "location" ? Match(reason: "移動しました") : nil
        case .shortcut:
            let name = (t.name ?? "").trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && tr == name ? Match(reason: "ショートカット「\(name)」から") : nil
        case .timeOfDay:
            // 通知だけのものは、予約した通知そのものが実行(ここでは動かさない)
            if flow.notifyOnly && !simulate { return nil }
            guard let at = todayTime(t, facts: facts) else { return nil }
            let occ = dayKey(facts.now)
            let late = facts.now.timeIntervalSince(at)
            guard simulate || (late >= 0 && late < Double(graceMin) * 60 && !memory.wasFired(id, occ)) else { return nil }
            return Match(reason: "\(DayPlanner.hm(at)) になりました", occurrence: occ)
        case .calendarEvent:
            if flow.notifyOnly && !simulate { return nil }
            let lead = Double(t.leadMin ?? 30) * 60
            for e in matchingEvents(t, facts: facts) {
                let fireAt = e.start.addingTimeInterval(-lead)
                let occ = occurrenceKey(event: e)
                let late = facts.now.timeIntervalSince(fireAt)
                if simulate ? (facts.now < e.end) : (late >= 0 && late < Double(graceMin) * 60 && facts.now < e.end && !memory.wasFired(id, occ)) {
                    return Match(reason: "予定「\(e.title)」(\(DayPlanner.hm(e.start)))の前です", event: e, occurrence: occ)
                }
            }
            return nil
        case .once:
            guard let ms = t.atMs else { return nil }
            let at = Date(timeIntervalSince1970: Double(ms) / 1000)
            let late = facts.now.timeIntervalSince(at)
            guard simulate || (late >= 0 && late < Double(onceGraceMin) * 60 && !memory.wasFired(id, "once")) else { return nil }
            return Match(reason: "予約の時刻(\(DayPlanner.hm(at)))です", occurrence: "once")
        }
    }

    /// 予定のきっかけに合う予定(外出だけ・言葉)。
    static func matchingEvents(_ t: FlowTrigger, facts: FlowFacts) -> [CalEvent] {
        let kw = (t.keyword ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return facts.events
            .filter { !$0.allDay || DayPlanner.isOuting($0) }
            .filter { t.outingOnly != true || DayPlanner.isOuting($0) }
            .filter { kw.isEmpty || ($0.title + " " + ($0.location ?? "")).lowercased().contains(kw) }
            .sorted { $0.startMs < $1.startMs }
    }

    // MARK: - 条件

    static func conditionsHold(_ flow: Flow, facts: FlowFacts, at: Date) -> (Bool, String) {
        guard !flow.conditions.isEmpty else { return (true, "") }
        var reasons: [String] = []
        var anyOK = false
        for c in flow.conditions {
            let (ok, why) = check(c, facts: facts, at: at)
            if ok { anyOK = true } else { reasons.append(why) }
            if flow.matchAll && !ok { return (false, why) }
        }
        return flow.matchAll ? (true, "") : (anyOK, reasons.joined(separator: "・"))
    }

    static func check(_ c: FlowCondition, facts: FlowFacts, at: Date) -> (Bool, String) {
        let hour = DayPlanner.tokyo.component(.hour, from: at)
        let weekday = DayPlanner.tokyo.component(.weekday, from: at) - 1
        switch c.kind {
        case .dataBelow:
            guard let l = facts.leftGB else { return (false, "残量が分からない") }
            return (l < (c.gb ?? 1) && facts.unlimitedActive != true, "残り \(gbText(l))")
        case .dataAbove:
            guard let l = facts.leftGB else { return (false, "残量が分からない") }
            return (l >= (c.gb ?? 1), "残り \(gbText(l))")
        case .hoursLeftBelow:
            guard let h = facts.hoursLeft else { return (false, "ペースが読めない") }
            return (h < (c.hours ?? 6) && facts.unlimitedActive != true, "あと約\(hoursText(h))")
        case .unlimitedActive:
            return (facts.unlimitedActive == true, "使い放題中ではない")
        case .unlimitedInactive:
            return (facts.unlimitedActive == false, facts.unlimitedActive == true ? "使い放題中" : "使い放題か分からない")
        case .onWifi:
            return (facts.network == "wifi", "Wi-Fi ではない")
        case .onCellular:
            return (facts.network == "cellular", facts.network == "wifi" ? "Wi-Fi 中" : "モバイル通信ではない")
        case .batteryBelow:
            guard let b = facts.battery else { return (false, "電池が分からない") }
            return (b <= (c.percent ?? 20), "電池 \(b)%")
        case .charging:
            return (facts.charging, "充電していない")
        case .notCharging:
            return (!facts.charging, "充電中")
        case .lowPower:
            return (facts.lowPower, "低電力モードではない")
        case .timeBetween:
            let f = c.from ?? 0, t = c.to ?? 24
            let ok = f <= t ? (hour >= f && hour < t) : (hour >= f || hour < t)
            return (ok, "\(f)時〜\(t)時の外(\(hour)時)")
        case .weekdays:
            let ds = c.weekdays ?? Array(0...6)
            return (ds.contains(weekday), "\(weekdayName(weekday))曜日")
        case .hasCodes:
            let tag = (c.tag ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let ok = tag.isEmpty ? !facts.codeTags.isEmpty : facts.codeTags.contains { $0.lowercased() == tag }
            return (ok, tag.isEmpty ? "未使用のコードがない" : "タグ「\(tag)」のコードがない")
        case .inOuting:
            guard facts.calendarAuthorized else { return (false, "カレンダーが許可されていない") }
            let ok = facts.events.contains { e in DayPlanner.outing(e, intensity: 1, on: at).map { $0.start <= at && at < $0.end } ?? false }
            return (ok, "外出の予定の最中ではない")
        case .outingWithin:
            guard facts.calendarAuthorized else { return (false, "カレンダーが許可されていない") }
            let limit = at.addingTimeInterval((c.hours ?? 3) * 3600)
            let ok = facts.events.contains { e in DayPlanner.isOuting(e) && e.start > at && e.start <= limit }
            return (ok, "\(hoursText(c.hours ?? 3))以内に外出の予定がない")
        case .dayShort:
            guard facts.calendarAuthorized else { return (false, "カレンダーが許可されていない") }
            var f = facts
            f.now = at
            let p = DayPlanner.plan(day: "today", facts: f)
            return (p.verdict == .short || p.verdict == .tight, "今日の予定に残量が足りている")
        case .usedTodayAbove:
            guard let u = facts.usedTodayMB else { return (false, "今日の使用量が分からない") }
            return (u >= Double(c.mb ?? 1000), "今日 \(Int(u))MB")
        }
    }

    // MARK: - 計画にする

    struct Built {
        /// エンジンへ渡す計画(オートメーションごと)。
        var nodes: [[String: Any]] = []
        var effects: [FlowEffect] = []
        var logs: [String] = []
    }

    /// 動くオートメーションのアクションを、エンジンの計画(JSON の形)と端末側の操作にする。
    /// povo への操作(コード・購入)は上から試し、できたところで止まる(1回の実行で1つまで)。
    static func build(_ firings: [FlowFiring], facts: FlowFacts, userInitiated: Bool) -> Built {
        var b = Built()
        for f in firings {
            b.logs.append("▶ オートメーション「\(f.flow.name)」: \(f.reason)")
            var povo: [[String: Any]] = []
            var rest: [[String: Any]] = []
            for a in f.flow.actions {
                // 実行前に確認 → 必ず確認 / その場で押した実行 → 確認済み / それ以外 → 設定どおり
                let confirm: Bool? = f.flow.ask ? true : (userInitiated ? false : nil)
                func withConfirm(_ n: [String: Any]) -> [String: Any] {
                    var n = n
                    if let confirm { n["confirm"] = confirm }
                    return n
                }
                switch a.kind {
                case .applyCode:
                    var n: [String: Any] = ["type": "applyCode"]
                    if let t = a.tag?.trimmingCharacters(in: .whitespaces), !t.isEmpty { n["tag"] = t }
                    povo.append(withConfirm(n))
                case .buyUnlimited:
                    if let p = pickUnlimited(hours: a.hours ?? 24, event: f.event, facts: facts) {
                        povo.append(withConfirm(["type": "buy", "sku": p.sku]))
                    } else {
                        let h = a.hours ?? 24
                        povo.append(["type": "skip", "reason": h == 0 ? "予定に合う使い放題が一覧にありません" : "\(DayPlanner.durationName(h))の使い放題が一覧にありません"])
                    }
                case .buyData:
                    if let p = pickData(gb: a.gb, facts: facts) {
                        povo.append(withConfirm(["type": "buy", "sku": p.sku]))
                    } else {
                        povo.append(["type": "skip", "reason": "データ追加が一覧にありません"])
                    }
                case .notify:
                    let title = render(a.title ?? f.flow.name, facts: facts, event: f.event)
                    let body = render(a.body ?? "", facts: facts, event: f.event)
                    rest.append(["type": "notify", "title": title.isEmpty ? "povoX" : title, "body": body])
                case .dayBrief:
                    if let br = DayPlanner.brief(day: a.day ?? "auto", facts: facts) {
                        rest.append(["type": "notify", "title": br.title, "body": br.body])
                    } else {
                        b.logs.append("カレンダーが許可されていないので、プランは出せません")
                    }
                case .setPurchaseMode:
                    if let m = a.mode { b.effects.append(.purchaseMode(m)) }
                case .setCodeMode:
                    if let m = a.mode { b.effects.append(.codeMode(m)) }
                case .setFlowEnabled:
                    if let id = a.flowID { b.effects.append(.flowEnabled(id, a.on ?? true)) }
                case .log:
                    b.logs.append("メモ: " + render(a.body ?? "", facts: facts, event: f.event))
                }
            }
            var items: [[String: Any]] = []
            if !povo.isEmpty { items.append(povo.count == 1 ? povo[0] : ["type": "firstOf", "items": povo]) }
            items.append(contentsOf: rest)
            if items.isEmpty { continue }
            b.nodes.append(items.count == 1 ? items[0] : ["type": "all", "items": items])
        }
        return b
    }

    /// 使い放題を選ぶ。hours == 0 は「予定の長さに合わせる」(外にいる時間を覆える一番短いもの)。
    static func pickUnlimited(hours: Int, event: CalEvent?, facts: FlowFacts) -> FlowProduct? {
        let list = (facts.products ?? []).filter { $0.unlimited && !$0.requires3ds && $0.price != nil && $0.hours != nil }
        if hours > 0 {
            return list.filter { Int(($0.hours ?? 0).rounded()) == hours }.min { ($0.price ?? 0) < ($1.price ?? 0) }
        }
        var need = 1.0
        if let e = event {
            let start = max(e.start, facts.now)
            need = max(0.5, e.end.timeIntervalSince(start) / 3600 + 0.5)
        } else {
            let p = DayPlanner.plan(day: "today", facts: facts)
            if let s = p.windowStart, let e = p.windowEnd { need = max(0.5, e.timeIntervalSince(max(s, facts.now)) / 3600) }
        }
        let sorted = list.sorted { ($0.hours ?? 0, $0.price ?? 0) < ($1.hours ?? 0, $1.price ?? 0) }
        return sorted.first { ($0.hours ?? 0) >= need } ?? sorted.last
    }

    static func pickData(gb: Double?, facts: FlowFacts) -> FlowProduct? {
        let list = (facts.products ?? []).filter { !$0.unlimited && !$0.requires3ds && $0.price != nil && $0.gb != nil }
        if let gb { return list.filter { abs(($0.gb ?? 0) - gb) < 0.01 }.min { ($0.price ?? 0) < ($1.price ?? 0) } }
        return list.min { ($0.gb ?? 0, $0.price ?? 0) < ($1.gb ?? 0, $1.price ?? 0) }
    }

    /// 通知の文面に差し込む: {残量} {あと} {今日} {時刻} {予定} {開始} {場所} {使い放題}
    static func render(_ text: String, facts: FlowFacts, event: CalEvent?) -> String {
        var s = text
        let unl: String
        if facts.unlimitedActive == true {
            unl = facts.unlimitedHoursLeft.map { "使い放題中(あと\(hoursText($0)))" } ?? "使い放題中"
        } else {
            unl = "使い放題ではありません"
        }
        let map: [String: String] = [
            "{残量}": facts.unlimitedActive == true ? "使い放題中" : gbText(facts.leftGB),
            "{あと}": facts.hoursLeft.map { "約\(hoursText($0))" } ?? "不明",
            "{今日}": facts.usedTodayMB.map { "\(Int($0))MB" } ?? "不明",
            "{時刻}": DayPlanner.hm(facts.now),
            "{予定}": event?.title ?? "予定",
            "{開始}": event.map { DayPlanner.hm($0.start) } ?? "",
            "{場所}": event?.location ?? "",
            "{使い放題}": unl,
        ]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    // MARK: - 予約の通知

    /// 時刻・予定・予約のきっかけについて、この先 horizon 時間に出す通知。
    /// 通知だけのオートメーションは、その通知が実行そのもの。povo やお金にかかわるものは「実行する」ボタン付き。
    static func schedule(flows: [Flow], facts: FlowFacts, memory: FlowMemory, horizonHours: Double = 36) -> [FlowScheduleItem] {
        let now = facts.now
        let limit = now.addingTimeInterval(horizonHours * 3600)
        var out: [FlowScheduleItem] = []
        for flow in flows where flow.enabled && flow.trigger.isScheduled {
            var times: [(Date, String, CalEvent?)] = []
            switch flow.trigger.kind {
            case .timeOfDay:
                for dayOffset in 0...2 {
                    guard let d = DayPlanner.tokyo.date(byAdding: .day, value: dayOffset, to: now),
                          let at = time(flow.trigger, on: d) else { continue }
                    let wd = DayPlanner.tokyo.component(.weekday, from: at) - 1
                    if let ws = flow.trigger.weekdays, !ws.contains(wd) { continue }
                    times.append((at, dayKey(at), nil))
                }
            case .calendarEvent:
                let lead = Double(flow.trigger.leadMin ?? 30) * 60
                for e in matchingEvents(flow.trigger, facts: facts) {
                    times.append((e.start.addingTimeInterval(-lead), occurrenceKey(event: e), e))
                }
            case .once:
                if let ms = flow.trigger.atMs { times.append((Date(timeIntervalSince1970: Double(ms) / 1000), "once", nil)) }
            default:
                break
            }
            for (at, occ, event) in times where at > now && at <= limit && !memory.wasFired(flow.id, occ) {
                var f = facts
                f.now = at
                guard conditionsHold(flow, facts: f, at: at).0 else { continue }
                let id = "flow-sched-\(flow.id)-\(occ)"
                if flow.notifyOnly {
                    // 中身を今のうちに作っておく(時刻にはアプリが動いていないことが多い)
                    guard let first = renderNotifyOnly(flow, facts: f, event: event) else { continue }
                    out.append(FlowScheduleItem(id: id, flowID: flow.id, fireAt: at, title: first.title, body: first.body, runnable: false, occurrence: occ))
                } else {
                    let what = flow.actions.map { FlowText.action($0) }.joined(separator: "→")
                    let when = event.map { "予定「\($0.title)」(\(DayPlanner.hm($0.start)))の前です。" } ?? (flow.trigger.kind == .once ? "予約した時刻です。" : "\(DayPlanner.hm(at)) になりました。")
                    out.append(FlowScheduleItem(id: id, flowID: flow.id, fireAt: at, title: "povoX: \(flow.name)",
                                                body: "\(when)「実行する」で \(what)", runnable: true, occurrence: occ))
                }
            }
        }
        return Array(out.sorted { $0.fireAt < $1.fireAt }.prefix(40))
    }

    static func renderNotifyOnly(_ flow: Flow, facts: FlowFacts, event: CalEvent?) -> (title: String, body: String)? {
        for a in flow.actions {
            switch a.kind {
            case .notify:
                return (render(a.title ?? flow.name, facts: facts, event: event), render(a.body ?? "", facts: facts, event: event))
            case .dayBrief:
                if let b = DayPlanner.brief(day: a.day ?? "auto", facts: facts) { return b }
            default:
                continue
            }
        }
        return nil
    }

    /// 次に時刻のオートメーションが動く時刻(バックグラウンド更新の予約を早めるため)。
    static func nextDue(flows: [Flow], facts: FlowFacts, memory: FlowMemory) -> Date? {
        schedule(flows: flows.filter { !$0.notifyOnly }, facts: facts, memory: memory, horizonHours: 24).first?.fireAt
    }

    // MARK: - 小物

    static func occurrenceKey(event e: CalEvent) -> String { "evt-\(e.id)-\(e.startMs)" }

    static func dayKey(_ d: Date) -> String {
        let c = DayPlanner.tokyo.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func time(_ t: FlowTrigger, on day: Date) -> Date? {
        var c = DayPlanner.tokyo.dateComponents([.year, .month, .day], from: day)
        c.hour = t.hour ?? 7
        c.minute = t.minute ?? 0
        return DayPlanner.tokyo.date(from: c)
    }

    static func todayTime(_ t: FlowTrigger, facts: FlowFacts) -> Date? {
        guard let at = time(t, on: facts.now) else { return nil }
        let wd = DayPlanner.tokyo.component(.weekday, from: at) - 1
        if let ws = t.weekdays, !ws.contains(wd) { return nil }
        return at
    }

    static func gbText(_ gb: Double?) -> String {
        guard let gb else { return "不明" }
        if gb < 1 { return "\(Int((gb * 1024).rounded()))MB" }
        return String(format: "%.2fGB", gb)
    }

    static func hoursText(_ h: Double?) -> String {
        guard let h else { return "不明" }
        if h < 1 { return "\(max(1, Int((h * 60).rounded())))分" }
        if h >= 48 { return "\(Int((h / 24).rounded()))日" }
        return h < 10 ? String(format: "%.1f時間", h) : "\(Int(h.rounded()))時間"
    }

    static func weekdayName(_ d: Int) -> String {
        ["日", "月", "火", "水", "木", "金", "土"][max(0, min(6, d))]
    }

    static func triggerName(_ t: String) -> String {
        switch t {
        case "background": return "バックグラウンド更新"
        case "foreground": return "アプリ表示中"
        case "manual": return "手動"
        case "shortcut": return "ショートカット"
        case "location", "location-arrive", "location-leave": return "位置情報"
        default: return t
        }
    }
}
