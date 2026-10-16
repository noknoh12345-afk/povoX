import Foundation
#if canImport(PovoX)
@testable import PovoX
#endif

/// 祝日・学習・目覚まし時計のような予約の検査(iOS とパソコンの両方から呼ぶ)。
enum LearnChecks {
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
        return DayPlanner.tokyo.date(from: c)!
    }

    static func run(fail: (String) -> Void) {
        func expect(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { fail(msg()) } }

        // --- 祝日 ---
        expect(JapaneseHolidays.weekday(2026, 10, 16) == 5, "2026-10-16 は金曜")
        let h2026: [(Int, Int, String)] = [(1, 1, "元日"), (1, 12, "成人の日"), (2, 11, "建国記念の日"), (2, 23, "天皇誕生日"),
                                           (3, 20, "春分の日"), (4, 29, "昭和の日"), (5, 3, "憲法記念日"), (5, 4, "みどりの日"),
                                           (5, 5, "こどもの日"), (5, 6, "振替休日"), (7, 20, "海の日"), (8, 11, "山の日"),
                                           (9, 21, "敬老の日"), (9, 22, "国民の休日"), (9, 23, "秋分の日"), (10, 12, "スポーツの日"),
                                           (11, 3, "文化の日"), (11, 23, "勤労感謝の日")]
        for (m, d, n) in h2026 {
            expect(JapaneseHolidays.name(date(2026, m, d)) == n, "2026-\(m)-\(d) \(n): \(String(describing: JapaneseHolidays.name(date(2026, m, d))))")
        }
        expect(JapaneseHolidays.table(2026).count == h2026.count, "2026年の祝日の数: \(JapaneseHolidays.table(2026).count)")
        expect(JapaneseHolidays.name(date(2025, 11, 24)) == "振替休日", "2025-11-24 振替")
        expect(JapaneseHolidays.name(date(2027, 3, 21)) == "春分の日", "2027 春分")
        expect(!JapaneseHolidays.isHoliday(date(2026, 10, 16)) && !JapaneseHolidays.isDayOff(date(2026, 10, 16)), "2026-10-16 は平日")
        expect(JapaneseHolidays.isDayOff(date(2026, 10, 17)), "土曜は休み")

        // --- 学習(本当の使い方が分かっている作り物のデータ)---
        // 60日間: ふだんは 1時間 5MB。3日ごとにライブ(18〜21時・大阪城ホール)で 1時間 400MB(±20%)。
        // 2日ごとに会議(10〜11時・本社)で 1時間 20MB。povo の数え方 = カウンタの 1.1 倍。
        let now = date(2026, 10, 16, 9)
        let start = now.addingTimeInterval(-60 * 86_400)
        var events: [CalEvent] = []
        var liveRate: [Int: Double] = [:]
        for day in 0..<60 {
            let d0 = DayPlanner.tokyo.startOfDay(for: start.addingTimeInterval(Double(day) * 86_400))
            func ms(_ h: Double) -> Int64 { Int64((d0.timeIntervalSince1970 + h * 3600) * 1000) }
            if day % 3 == 0 {
                events.append(CalEvent(id: "live\(day)", title: "ライブ", location: "大阪城ホール", startMs: ms(18), endMs: ms(21), allDay: false, calendar: nil))
                liveRate[day] = 400 * (0.8 + 0.4 * Double((day * 7) % 10) / 10)
            }
            if day % 2 == 0 {
                events.append(CalEvent(id: "mtg\(day)", title: "第\(day)回 会議", location: "本社", startMs: ms(10), endMs: ms(11), allDay: false, calendar: nil))
            }
        }
        func rate(at t: Date) -> Double {
            for e in events where e.start <= t && t < e.end {
                let day = Int(DayPlanner.tokyo.startOfDay(for: e.start).timeIntervalSince(DayPlanner.tokyo.startOfDay(for: start)) / 86_400)
                return e.title == "ライブ" ? (liveRate[day] ?? 400) : 20
            }
            return 5
        }
        var samples: [(t: Int64, leftKb: Double, unlimited: Bool)] = []
        var net: [(t: Int64, s: NetSample)] = []
        var cellMB = 0.0, left = 200_000.0 * 1024
        var t = start
        let step: TimeInterval = 15 * 60
        while t < now {
            let ms = Int64(t.timeIntervalSince1970 * 1000)
            net.append((ms, NetSample(cellIn: UInt64(cellMB * 1_048_576), cellOut: 0, wifiIn: 0, wifiOut: 0, bootMs: 0)))
            samples.append((ms, left, false))
            let used = rate(at: t) * step / 3600
            cellMB += used
            left -= used * 1.1 * 1024
            t = t.addingTimeInterval(step)
        }
        let m = UsageLearner.learn(UsageLearner.Input(samples: samples, net: net, events: events, overrides: [:], now: now))
        expect(abs((m.povoPerCell ?? 0) - 1.1) < 0.02, "povo ÷ カウンタ ≈ 1.1: \(String(describing: m.povoPerCell))")
        let live = m.kinds["live"]
        expect(live?.events == 20, "ライブ20件: \(String(describing: live?.events))")
        // 本当の量(移動の前後30分を含む4時間): 3時間 × 400 × 1.1 + 1時間 × 5 × 1.1 ≈ 1325MB → 1時間あたり約331(90%はもう少し上)
        expect((300...420).contains(live?.mbPerHourP90 ?? 0), "ライブの1時間あたり(90%)が実際に近い: \(String(describing: live?.mbPerHourP90))")
        let work = m.kinds["work"]
        expect((work?.mbPerHourP90 ?? 999) < 50, "会議は少ない: \(String(describing: work?.mbPerHourP90))")
        if let a = m.accuracy {
            expect(a.testEvents >= 10, "確かめの件数: \(a.testEvents)")
            expect(a.learnedPinball < a.priorPinball, "学習のほうが外れにくい: \(a.priorPinball) → \(a.learnedPinball)")
            expect(a.learnedExceed <= a.priorExceed, "見積もりを超える割合が減る: \(a.priorExceed) → \(a.learnedExceed)")
        } else {
            expect(false, "確かめができていない")
        }
        expect(m.weekdayP50.count == 24 && m.weekdayP50[3] > 4 && m.weekdayP50[3] < 7, "夜中(3時)は 1時間 約5.5MB: \(m.weekdayP50.isEmpty ? -1 : m.weekdayP50[3])")
        expect(!UsageLearner.lines(m).isEmpty, "報告の文")

        // 学習した量が今日のプランに使われる
        var f = FlowLogicChecks.facts(leftGB: 0.5)
        f.now = now
        let tonight = CalEvent(id: "x", title: "ライブ", location: "大阪城ホール", startMs: Int64(date(2026, 10, 16, 18).timeIntervalSince1970 * 1000),
                               endMs: Int64(date(2026, 10, 16, 21).timeIntervalSince1970 * 1000), allDay: false, calendar: nil)
        f.events = [tonight]
        let prior = DayPlanner.plan(day: "today", facts: f).needMB
        f.learned = m
        let mine = DayPlanner.plan(day: "today", facts: f).needMB
        expect(abs(mine - 4 * (live?.mbPerHourP90 ?? 0)) < 1, "学習の量 × 4時間: \(mine)")
        expect(abs(prior - 950) < 1, "最初の目安 3×250+200: \(prior)")

        // 利用者の直し: 「会議」は家(オンライン)だった → 外出に数えない(回が違っても同じ)
        var o = m
        o.overrides[LearnedModel.key("第3回 会議")] = false
        expect(LearnedModel.key("第3回 会議") == LearnedModel.key("第12回 会議"), "回の数字は無視")
        let mtg = CalEvent(id: "m", title: "第99回 会議", location: "本社", startMs: 0, endMs: 1, allDay: false, calendar: nil)
        expect(DayPlanner.isOuting(mtg) && !DayPlanner.isOuting(mtg, overrides: o.overrides), "直した予定は外出に数えない")
        let suite = "learncheck-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        let ls = LearningStore(defaults: ud)
        ls.save(m)
        ls.setOverride("第3回 会議", outing: false)
        expect(ls.model()?.overrides[LearnedModel.key("第7回 会議")] == false, "直しの保存(別の回でも同じ鍵)")
        ls.setOverride("第3回 会議", outing: nil)
        expect(ls.overrides().isEmpty, "直しを元に戻す")
        ud.removePersistentDomain(forName: suite)

        // --- 目覚まし時計のような予約 ---
        // 平日(祝日を除く)7:00・スヌーズ5分・中身は時刻だけで決まる → 8日先まで、祝日の日は鳴らさない
        var alarm = Flow(id: "alarm", name: "朝のアラーム", trigger: .time(7, 0), conditions: [FlowCondition(.workday)],
                         actions: [.notify("おはよう", "出かける前に残量を確認")], ask: false)
        alarm.trigger.snoozeMin = 5
        expect(alarm.isStatic, "曜日・祝日だけの条件 + 固定の文 = 時刻だけで決まる")
        var af = FlowLogicChecks.facts()
        af.now = date(2026, 9, 18, 9) // 金曜。9/21〜23 は祝日
        let items = FlowEngine.schedule(flows: [alarm], facts: af, memory: FlowMemory())
        let days = Set(items.filter { !$0.id.hasSuffix("-snooze") }.map { FlowEngine.dayKey($0.fireAt) })
        expect(days == ["2026-09-24", "2026-09-25"], "平日だけ・祝日(9/21〜23)と土日は鳴らさない: \(days.sorted())")
        expect(items.filter { $0.id.hasSuffix("-snooze") }.count == 2, "スヌーズも予約")
        if let a = items.first(where: { !$0.id.hasSuffix("-snooze") }), let b = items.first(where: { $0.id == a.id + "-snooze" }) {
            expect(b.fireAt.timeIntervalSince(a.fireAt) == 300 && DayPlanner.hm(a.fireAt) == "7:00", "7:00 と 7:05")
        } else {
            expect(false, "スヌーズの組が無い")
        }
        // 次に鳴る時刻と一覧の文
        let next = FlowEngine.nextRing(alarm, facts: af)
        expect(next.map { FlowEngine.dayKey($0) } == "2026-09-24" && next.map(DayPlanner.hm) == "7:00", "次に鳴るのは連休明けの木曜 7:00: \(String(describing: next))")
        expect(FlowText.alarmRepeat(alarm) == "平日(祝日を除く)・スヌーズ5分", FlowText.alarmRepeat(alarm))
        // 中身が残量で変わるもの: 36時間以内は中身を作る、その先は「タップで最新」で鳴らすことだけ予約
        let brief = Flow(id: "b", name: "夜のプラン", trigger: .time(21, 0), actions: [.brief("tomorrow")], ask: false)
        expect(!brief.isStatic, "プランは中身が変わる")
        var bf = FlowLogicChecks.facts()
        bf.now = date(2026, 10, 16, 9)
        let bi = FlowEngine.schedule(flows: [brief], facts: bf, memory: FlowMemory())
        expect(bi.count == 8, "今日〜8日先(今から192時間以内)の21時: \(bi.count)")
        expect(bi.first.map { $0.title.contains("明日のプラン") } == true, "近い日は中身を作る: \(bi.first?.title ?? "")")
        expect(bi.last.map { $0.body.contains("タップすると") } == true, "先の日は鳴らすことだけ: \(bi.last?.body ?? "")")
        // 1回だけ(予約)
        let once = Flow(id: "o", name: "1回", trigger: .once(date(2026, 10, 20, 8)), actions: [.unlimited(24)], ask: false, preconfirmed: true)
        expect(FlowEngine.schedule(flows: [once], facts: bf, memory: FlowMemory()).count == 1, "1回だけの予約")
        // 外出の予定がある日だけ
        var outDay = Flow(id: "od", name: "外出の日", trigger: .time(8, 0), conditions: [FlowCondition(.dayHasOuting)],
                          actions: [.notify("外出の日", "{残量}")], ask: false)
        outDay.trigger.snoozeMin = nil
        var of = FlowLogicChecks.facts()
        of.now = date(2026, 10, 16, 7)
        of.events = [FlowLogicChecks.live]
        let oi = FlowEngine.schedule(flows: [outDay], facts: of, memory: FlowMemory())
        expect(oi.count == 1 && FlowEngine.dayKey(oi[0].fireAt) == "2026-10-16", "外出の予定がある今日だけ: \(oi.map { FlowEngine.dayKey($0.fireAt) })")
    }
}
