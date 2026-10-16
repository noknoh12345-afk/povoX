import Foundation
#if canImport(PovoX)
@testable import PovoX
#endif

/// オートメーションと今日のプランの中身の検査。iOS の単体テスト(FlowTests)と、
/// パソコン上の検査(tools/flow-check.sh。Swift があれば Linux でも動く)の両方から呼ぶ。
/// 失敗は `fail` に文を渡す。
enum FlowLogicChecks {
    static let t0: Date = {
        // 2026-10-16(金) 9:00 JST
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 16; c.hour = 9; c.minute = 0
        return DayPlanner.tokyo.date(from: c)!
    }()

    static func at(_ h: Int, _ m: Int = 0, day: Int = 0) -> Date {
        t0.addingTimeInterval(Double(day * 86400 + (h - 9) * 3600 + m * 60))
    }

    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    static let products: [FlowProduct] = [
        FlowProduct(sku: "U1", name: "使い放題1時間", price: 110, gb: nil, hours: 1, unlimited: true, requires3ds: false),
        FlowProduct(sku: "U24", name: "使い放題24時間", price: 330, gb: nil, hours: 24, unlimited: true, requires3ds: false),
        FlowProduct(sku: "D1", name: "データ1GB", price: 390, gb: 1, hours: nil, unlimited: false, requires3ds: false),
        FlowProduct(sku: "D20", name: "データ20GB", price: 2700, gb: 20, hours: nil, unlimited: false, requires3ds: true),
    ]

    static func facts(now: Date = t0, leftGB: Double? = 0.4, network: String = "cellular") -> FlowFacts {
        var f = FlowFacts()
        f.now = now
        f.leftGB = leftGB
        f.hoursLeft = 5
        f.mbPerHour = 80
        f.usedTodayMB = 120
        f.unlimitedActive = false
        f.battery = 60
        f.network = network
        f.calendarAuthorized = true
        f.products = products
        return f
    }

    static let live = CalEvent(id: "e1", title: "ライブ", location: "大阪城ホール", startMs: ms(at(13)), endMs: ms(at(21)), allDay: false, calendar: nil)
    static let zoom = CalEvent(id: "e2", title: "オンライン会議(Zoom)", location: "https://zoom.us/j/1", startMs: ms(at(10)), endMs: ms(at(11)), allDay: false, calendar: nil)
    static let deadline = CalEvent(id: "e3", title: "レポート締切", location: nil, startMs: ms(at(17)), endMs: ms(at(18)), allDay: false, calendar: nil)
    static let dentist = CalEvent(id: "e4", title: "歯医者", location: nil, startMs: ms(at(10, day: 1)), endMs: ms(at(11, day: 1)), allDay: false, calendar: nil)

    static func run(fail: (String) -> Void) {
        func expect(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { fail(msg()) } }

        // --- 予定の見分け ---
        expect(DayPlanner.isOuting(live), "場所のある予定は外出")
        expect(!DayPlanner.isOuting(zoom), "オンラインは外出ではない")
        expect(!DayPlanner.isOuting(deadline), "場所も外出の言葉もない予定は外出ではない")
        expect(DayPlanner.isOuting(dentist), "歯医者は外出")
        expect(DayPlanner.kind(of: live) == .live, "ライブの種類")

        // --- 今日のプラン ---
        var f = facts()
        f.events = [live, zoom, deadline, dentist]
        let p = DayPlanner.plan(day: "today", facts: f)
        expect(p.outings.count == 1, "今日の外出は1件: \(p.outings.count)")
        expect(p.verdict == .short, "0.4GB ではライブに足りない: \(p.verdict)")
        expect(p.suggestion?.action.kind == .buyUnlimited && p.suggestion?.action.hours == 24, "8時間超の外出 → 24時間: \(String(describing: p.suggestion))")
        expect(DayPlanner.hm(p.suggestion!.at) == "12:15", "予定(移動込み 12:30〜)の15分前: \(DayPlanner.hm(p.suggestion!.at))")
        // 残量が多ければ何もしない
        f.leftGB = 10
        expect(DayPlanner.plan(day: "today", facts: f).verdict == .enough, "10GB なら足りる")
        // 使い放題が予定の終わりまで
        f.leftGB = 0.1
        f.unlimitedActive = true
        f.unlimitedHoursLeft = 20
        expect(DayPlanner.plan(day: "today", facts: f).verdict == .covered, "使い放題が予定まで覆う")
        f.unlimitedActive = false
        // コードがあり不足が少ない(ライブは移動込みで約2.2GB、残り1.5GB)ならコード
        f.leftGB = 1.5
        f.codeTags = ["1gb"]
        let pc = DayPlanner.plan(day: "today", facts: f)
        expect(pc.suggestion?.action.kind == .applyCode, "コード優先: \(String(describing: pc.suggestion))")
        f.codeTags = []
        // 短い外出は1時間
        var f2 = facts(leftGB: 0.05)
        f2.events = [CalEvent(id: "x", title: "ランチ", location: "梅田", startMs: ms(at(12)), endMs: ms(at(12, 30)), allDay: false, calendar: nil)]
        let ps = DayPlanner.plan(day: "today", facts: f2)
        expect(ps.suggestion?.action.hours == 24 || ps.suggestion?.action.hours == 1, "ランチの提案")
        // 移動込みで1.5時間 → 1時間では覆えないので24時間
        expect(ps.suggestion?.action.hours == 24, "移動込み1.5時間 → 24時間: \(String(describing: ps.suggestion?.action.hours))")
        // 明日
        f.events = [dentist]
        let pt = DayPlanner.plan(day: "tomorrow", facts: f)
        expect(pt.outings.count == 1 && pt.dayLabel == "明日", "明日の歯医者")
        // 予定なし
        f.events = []
        expect(DayPlanner.plan(day: "today", facts: f).verdict == .noOutings, "予定なし")
        var noCal = facts()
        noCal.calendarAuthorized = false
        expect(DayPlanner.brief(day: "today", facts: noCal) == nil, "カレンダー未許可ならプランの通知は出さない")

        // --- きっかけ: 残量(境目) ---
        let low = Flow(id: "low", name: "残り100MB", trigger: .dataBelow(0.1), conditions: [.onCellular], actions: [.code(), .unlimited(1)], ask: true)
        var mem = FlowMemory()
        var fx = facts(leftGB: 0.5)
        var ev = FlowEngine.evaluate(flows: [low], facts: fx, memory: mem)
        expect(ev.firings.isEmpty, "0.5GB では動かない")
        fx.leftGB = 0.08
        ev = FlowEngine.evaluate(flows: [low], facts: fx, memory: ev.memory)
        expect(ev.firings.count == 1, "0.08GB で動く")
        FlowEngine.recordFired(ev.firings, summary: "ok", memory: &ev.memory, now: fx.now)
        mem = ev.memory
        fx.now = fx.now.addingTimeInterval(3600)
        ev = FlowEngine.evaluate(flows: [low], facts: fx, memory: mem)
        expect(ev.firings.isEmpty, "下回ったままなら2回目は動かない")
        fx.leftGB = 3
        ev = FlowEngine.evaluate(flows: [low], facts: fx, memory: ev.memory)
        fx.leftGB = 0.05
        fx.now = fx.now.addingTimeInterval(3600)
        ev = FlowEngine.evaluate(flows: [low], facts: fx, memory: ev.memory)
        expect(ev.firings.count == 1, "戻ってからまた下回ったら動く")
        // 条件(Wi-Fi では動かない)
        var wifi = facts(leftGB: 0.05, network: "wifi")
        wifi.now = at(9)
        expect(FlowEngine.evaluate(flows: [low], facts: wifi, memory: FlowMemory()).firings.isEmpty, "Wi-Fi では条件に合わない")

        // --- きっかけ: Wi-Fi から離れた(変化) ---
        let leave = Flow(id: "leave", name: "離れた", trigger: .leftWifi(), actions: [.notify("離れた", "{残量}")], ask: false)
        var lm = FlowMemory()
        var lf = facts(network: "cellular")
        var le = FlowEngine.evaluate(flows: [leave], facts: lf, memory: lm)
        expect(le.firings.isEmpty, "最初からモバイルなら動かない(変化を見ていない)")
        lf.network = "wifi"
        le = FlowEngine.evaluate(flows: [leave], facts: lf, memory: le.memory)
        lf.network = "cellular"
        le = FlowEngine.evaluate(flows: [leave], facts: lf, memory: le.memory)
        expect(le.firings.count == 1, "Wi-Fi → モバイルで動く")
        lm = le.memory
        le = FlowEngine.evaluate(flows: [leave], facts: lf, memory: lm)
        expect(le.firings.isEmpty, "モバイルのままなら動かない")
        var sc = facts(network: "unknown")
        sc.trigger = "wifi-off"
        expect(FlowEngine.evaluate(flows: [leave], facts: sc, memory: FlowMemory()).firings.count == 1, "ショートカットの wifi-off で動く")

        // --- 時刻 ---
        let night = Flow(id: "night", name: "21時", trigger: .time(21, 0), actions: [.unlimited(24)], ask: true)
        var tf = facts()
        tf.now = at(21, 10)
        var te = FlowEngine.evaluate(flows: [night], facts: tf, memory: FlowMemory())
        expect(te.firings.count == 1 && te.firings[0].occurrence == "2026-10-16", "21:10 に動く")
        FlowEngine.recordFired(te.firings, summary: "", memory: &te.memory, now: tf.now)
        tf.now = at(21, 40)
        expect(FlowEngine.evaluate(flows: [night], facts: tf, memory: te.memory).firings.isEmpty, "同じ日に2回は動かない")
        tf.now = at(23, 30)
        expect(FlowEngine.evaluate(flows: [night], facts: tf, memory: FlowMemory()).firings.isEmpty, "90分以上遅れたら動かない(通知に任せる)")
        // 通知だけの時刻のものは、自動チェックでは動かさない(予約した通知が実行)
        let brief = Flow(id: "brief", name: "明日", trigger: .time(21, 0), actions: [.brief("tomorrow")], ask: false)
        tf.now = at(21, 5)
        expect(FlowEngine.evaluate(flows: [brief], facts: tf, memory: FlowMemory()).firings.isEmpty, "通知だけの時刻は自動チェックで動かさない")

        // --- 予定の前 ---
        let cal = Flow(id: "cal", name: "出かける前", trigger: .calendar(lead: 30), conditions: [.dayShort], actions: [.code(), .unlimited(0)], ask: true)
        var cf = facts(leftGB: 0.3)
        cf.events = [live, zoom]
        cf.now = at(12, 35)
        let ce = FlowEngine.evaluate(flows: [cal], facts: cf, memory: FlowMemory())
        expect(ce.firings.count == 1 && ce.firings[0].event?.id == "e1", "ライブの30分前に動く")
        cf.now = at(9, 40)
        expect(FlowEngine.evaluate(flows: [cal], facts: cf, memory: FlowMemory()).firings.isEmpty, "オンライン会議では動かない")

        // --- 計画にする ---
        cf.now = at(12, 35)
        let built = FlowEngine.build(ce.firings, facts: cf, userInitiated: false)
        let json = String(data: try! JSONSerialization.data(withJSONObject: built.nodes[0]), encoding: .utf8)!
        expect(json.contains("\"firstOf\"") && json.contains("\"applyCode\"") && json.contains("\"U24\"") && json.contains("\"confirm\":true"),
               "コード → 予定に合わせた使い放題(13:00-21:00 → 24時間)・確認つき: \(json)")
        let tap = Flow(id: "tap", name: "1時間", trigger: .manual(), actions: [.unlimited(1)], ask: false, showOnHome: true)
        let te2 = FlowEngine.evaluate(flows: [tap], facts: facts(), memory: FlowMemory(), forcedID: "tap")
        expect(te2.firings.count == 1, "ボタンで動く")
        let tb = FlowEngine.build(te2.firings, facts: facts(), userInitiated: true)
        let tj = String(data: try! JSONSerialization.data(withJSONObject: tb.nodes[0]), encoding: .utf8)!
        expect(tj.contains("\"U1\"") && tj.contains("\"confirm\":false"), "ボタン = その場で確認済み: \(tj)")
        expect(FlowEngine.evaluate(flows: [tap], facts: facts(), memory: FlowMemory()).firings.isEmpty, "ボタンのものは自動では動かない")
        // 3DS は選ばない・無い長さはスキップ
        expect(FlowEngine.pickData(gb: 20, facts: facts()) == nil, "3DS のデータは選ばない")
        let miss = FlowEngine.build([FlowFiring(flow: Flow(name: "x", trigger: .manual(), actions: [.unlimited(72)]), reason: "", event: nil, occurrence: nil)],
                                    facts: facts(), userInitiated: true)
        let mj = String(data: try! JSONSerialization.data(withJSONObject: miss.nodes[0]), encoding: .utf8)!
        expect(mj.contains("skip") && mj.contains("3日間"), "無い長さはスキップ: \(mj)")
        // 端末側の操作
        let mode = FlowEngine.build([FlowFiring(flow: FlowGallery.template("g.mode.travel")!.make(), reason: "", event: nil, occurrence: nil)],
                                    facts: facts(), userInitiated: true)
        expect(mode.effects == [.purchaseMode("auto"), .codeMode("auto")], "モード切替: \(mode.effects)")
        // 差し込み
        var rf = facts(leftGB: 0.42)
        rf.now = at(12, 30)
        let r = FlowEngine.render("{予定}まで。残り {残量}・{あと}", facts: rf, event: live)
        expect(r == "ライブまで。残り 430MB・約5.0時間", "差し込み: \(r)")

        // --- 条件に合わなければボタンでも実行しない ---
        let codeTap = FlowGallery.template("g.tap.code")!.make()
        let nc = FlowEngine.evaluate(flows: [codeTap], facts: facts(), memory: FlowMemory(), forcedID: codeTap.id)
        expect(nc.firings.isEmpty && nc.logs.first?.contains("条件に合わない") == true, "コードが無いと実行しない: \(nc.logs)")

        // --- 予約の通知 ---
        var sf = facts(leftGB: 0.3)
        sf.events = [live]
        sf.now = at(9)
        let flows = FlowGallery.seeds()
        let items = FlowEngine.schedule(flows: flows, facts: sf, memory: FlowMemory())
        expect(items.contains { $0.runnable && $0.title.contains("出かける前に使い放題") && DayPlanner.hm($0.fireAt) == "12:30" },
               "ライブ30分前に「実行する」つき: \(items.map { "\($0.title)@\(DayPlanner.hm($0.fireAt))" })")
        expect(items.contains { !$0.runnable && $0.title.contains("明日のプラン") && DayPlanner.hm($0.fireAt) == "21:00" }, "21時の明日のプラン")
        expect(items.allSatisfy { $0.fireAt > sf.now }, "過去の通知は出さない")
        // 実行済みの回は出さない
        var fm = FlowMemory()
        let calFlow = flows.first { $0.galleryID == "g.calendar.unlimited" }!
        fm.fired["\(calFlow.id)|\(FlowEngine.occurrenceKey(event: live))"] = 1
        fm.fired["\(calFlow.id)|\(FlowEngine.occurrenceKey(event: live))"] = ms(sf.now)
        expect(!FlowEngine.schedule(flows: flows, facts: sf, memory: fm).contains { $0.flowID == calFlow.id }, "実行済みの予定は出さない")
        // 残量が十分なら「出かける前に使い放題」は予約しない(条件: 今日の予定に足りない)
        sf.leftGB = 20
        expect(!FlowEngine.schedule(flows: flows, facts: sf, memory: FlowMemory()).contains { $0.flowID == calFlow.id }, "足りるなら予約しない")

        // --- 予約(1回だけ) ---
        let once = Flow(id: "once", name: "予約", trigger: .once(at(12, 15)), actions: [.unlimited(24)], ask: false, preconfirmed: true)
        var of = facts()
        of.now = at(12, 20)
        var oe = FlowEngine.evaluate(flows: [once], facts: of, memory: FlowMemory())
        expect(oe.firings.count == 1, "予約の時刻に動く")
        FlowEngine.recordFired(oe.firings, summary: "", memory: &oe.memory, now: of.now)
        expect(FlowEngine.evaluate(flows: [once], facts: of, memory: oe.memory).firings.isEmpty, "予約は1回だけ")
        expect(FlowEngine.evaluate(flows: [once], facts: of, memory: oe.memory, forcedID: "once", occurrence: "once").firings.isEmpty,
               "通知から押しても、実行済みなら動かない")

        // --- 保存 ---
        let suite = "flowcheck-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        let store = FlowStore(defaults: ud)
        store.seedIfNeeded()
        expect(store.flows().count == FlowGallery.seedIDs.count, "最初のオートメーション")
        store.delete(store.flows()[0].id)
        store.seedIfNeeded()
        expect(store.flows().count == FlowGallery.seedIDs.count - 1, "2回目は入れ直さない")
        var m = FlowMemory()
        m.count["a"] = 3
        store.saveMemory(m)
        expect(store.memory().count["a"] == 3, "記憶の保存")
        ud.removePersistentDomain(forName: suite)

        // --- ギャラリーはすべて説明でき、計画にできる ---
        for t in FlowGallery.all {
            let fl = FlowGallery.instantiate(t)
            expect(!FlowText.summary(fl).isEmpty, "要約 \(t.id)")
            expect(fl.id != t.make().id, "新しい ID \(t.id)")
            let b = FlowEngine.build([FlowFiring(flow: fl, reason: "", event: live, occurrence: nil)], facts: facts(), userInitiated: true)
            expect(!b.nodes.isEmpty || !b.effects.isEmpty, "計画にできる \(t.id)")
            for n in b.nodes { expect(JSONSerialization.isValidJSONObject(n), "JSON にできる \(t.id)") }
        }
        // Codable の往復
        let enc = try! JSONEncoder().encode(FlowGallery.seeds())
        let dec = try! JSONDecoder().decode([Flow].self, from: enc)
        expect(dec == FlowGallery.seeds().enumerated().map { i, _ in dec[i] } && dec.count == FlowGallery.seedIDs.count, "保存形式の往復")
    }
}
