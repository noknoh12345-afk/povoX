import XCTest
@testable import PovoX

/// オートメーション(内蔵のショートカット)と今日のプラン。
final class FlowTests: XCTestCase {
    /// 中身の検査(パソコン上の tools/flow-check.sh と同じもの)。
    func testFlowLogic() {
        FlowLogicChecks.run { XCTFail($0) }
    }

    private func store(_ flows: [Flow]) -> FlowStore {
        let s = FlowStore(defaults: UserDefaults(suiteName: "povox-flowtest-\(UUID().uuidString)")!)
        s.save(flows)
        return s
    }

    private func service(_ client: EngineClient, settings: AppSettings, flows: FlowStore, device: DeviceState,
                         calendar: [CalEvent] = [], effects: @escaping ([FlowEffect]) async -> Void = { _ in }) -> AutomationService {
        AutomationService(.init(
            client: { client },
            device: { device },
            settings: { settings },
            notify: { _ in },
            afterRun: { _ in },
            flows: { flows },
            calendar: { (calendar, !calendar.isEmpty) },
            applyEffects: effects
        ))
    }

    private let cellular = DeviceState(batteryLevel: 80, charging: false, full: false, lowPower: false, network: "cellular")

    /// ボタン(flow:)で押したショートカットは、「通知で確認」の設定でもその場で実行する(押したことが確認)。
    func testTappedShortcutBuysThroughEngine() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let tile = Flow(name: "1時間使い放題", trigger: .manual(), actions: [.unlimited(1)], ask: false, showOnHome: true)
        let svc = service(c, settings: testSettings(), flows: store([tile]), device: cellular)
        let rec = try XCTUnwrapAsync(await svc.run(trigger: "flow:\(tile.id)"))
        XCTAssertNil(rec.error, rec.error ?? "")
        XCTAssertTrue(rec.outcomes.contains { $0.kind == .buy && $0.status == .done && $0.label.contains("1時間") }, rec.summary)
        XCTAssertTrue(rec.logs.contains { $0.contains("1時間使い放題") }, "\(rec.logs)")
        // ボタンで実行したときはルールを動かさない(ルールの購入と重ならない)
        XCTAssertEqual(rec.outcomes.filter { $0.kind == .buy }.count, 1)
    }

    /// 「実行前に確認」のオートメーションは、きっかけで動いても確認待ちにする。
    func testAskingAutomationQueuesConfirmation() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let s = testSettings()
        s.ruleEnabled = false
        let low = Flow(name: "残りわずか", trigger: .dataBelow(5), conditions: [.onCellular], actions: [.code(), .unlimited(24)], ask: true)
        let fs = store([low])
        let svc = service(c, settings: s, flows: fs, device: cellular)
        let rec = try XCTUnwrapAsync(await svc.run(trigger: "background"))
        XCTAssertTrue(rec.outcomes.contains { $0.kind == .buy && $0.status == .queued && $0.label.contains("24時間") }, rec.summary)
        // 2回目は動かない(下回ったまま)
        let pending = await c.value { $0.pendingActions() }
        for p in pending { await c.value { $0.dismissPending(id: p.id) } }
        let rec2 = try XCTUnwrapAsync(await svc.run(trigger: "background"))
        XCTAssertFalse(rec2.outcomes.contains { $0.kind == .buy }, rec2.summary)
        XCTAssertEqual(fs.memory().count[low.id], 1)
    }

    /// ルールを止め、合うオートメーションも無ければ何もしない。
    func testNothingMatches() async throws {
        let c = mockClient()
        try await login(c)
        let s = testSettings()
        s.ruleEnabled = false
        let svc = service(c, settings: s, flows: store([]), device: cellular)
        let rec = try XCTUnwrapAsync(await svc.run(trigger: "background"))
        XCTAssertEqual(rec.summary, "条件に合うオートメーションはありません")
    }

    /// 設定を変えるアクション(モード)は、端末側の操作として渡す。
    func testModeShortcutAppliesEffects() async throws {
        let c = mockClient()
        try await login(c)
        let mode = FlowGallery.instantiate(FlowGallery.template("g.mode.travel")!)
        var got: [FlowEffect] = []
        let svc = service(c, settings: testSettings(), flows: store([mode]), device: cellular) { got += $0 }
        let rec = try XCTUnwrapAsync(await svc.run(trigger: "flow:\(mode.id)"))
        XCTAssertEqual(got, [.purchaseMode("auto"), .codeMode("auto")])
        XCTAssertTrue(rec.outcomes.contains { $0.status == .notified }, rec.summary)
    }

    /// 予定の前のオートメーションと、予約(1回きり・確認済み)。
    func testCalendarAndReservation() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let now = Date()
        let event = CalEvent(id: "e", title: "ライブ", location: "大阪城ホール",
                             startMs: Int64((now.timeIntervalSince1970 + 20 * 60) * 1000), endMs: Int64((now.timeIntervalSince1970 + 5 * 3600) * 1000),
                             allDay: false, calendar: nil)
        let s = testSettings()
        s.ruleEnabled = false
        // 予約: 時刻を過ぎたら、確認なしで(その場で押した実行として)入れる。1回だけ。
        let once = Flow(name: "予約", trigger: .once(now.addingTimeInterval(-60)), actions: [.unlimited(24)], ask: false, preconfirmed: true)
        let fs = store([once])
        let svc = service(c, settings: s, flows: fs, device: cellular, calendar: [event])
        let rec = try XCTUnwrapAsync(await svc.run(trigger: "background"))
        XCTAssertTrue(rec.trigger.hasPrefix("flow:"), rec.trigger)
        XCTAssertTrue(rec.outcomes.contains { $0.kind == .buy && $0.status == .done && $0.label.contains("24時間") }, rec.summary)
        XCTAssertEqual(fs.flow(once.id)?.enabled, false, "予約は済んだらオフ")

        // 予定の前(30分前の範囲)で、予定に合わせた使い放題を確認つきで
        let c2 = mockClient("low")
        try await login(c2)
        _ = try await c2.call { try $0.catalog(force: false) }
        let cal = Flow(name: "出かける前", trigger: .calendar(lead: 30, outingOnly: true), actions: [.unlimited(0)], ask: true)
        let svc2 = service(c2, settings: s, flows: store([cal]), device: cellular, calendar: [event])
        let rec2 = try XCTUnwrapAsync(await svc2.run(trigger: "background"))
        XCTAssertTrue(rec2.outcomes.contains { $0.kind == .buy && $0.status == .queued && $0.label.contains("24時間") }, rec2.summary)
    }

    /// シミュレーターでもオートメーションが見える。
    func testSimulationIncludesFlows() async throws {
        let c = mockClient()
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let s = testSettings()
        s.ruleEnabled = false
        let low = Flow(name: "残りわずか", trigger: .dataBelow(0.2), actions: [.unlimited(1)], ask: true)
        let svc = service(c, settings: s, flows: store([low]), device: cellular)
        let sim = SimInput(leftKb: 0.1 * Fmt.kbPerGB, unlimited: false, unlimitedHoursLeft: nil, hoursLeft: 1)
        let r = await svc.simulate(sim, device: cellular, trigger: "sim")
        XCTAssertTrue(r.outcomes.contains { $0.status == .simulated && $0.label.contains("1時間") }, r.summary)
    }

    /// 今日のプラン(エンジンの残量 + 予定)。
    func testDayPlanFromEngine() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.snapshot(force: false) }
        let ctx = try await c.call { try $0.ruleContextJson(mode: .simulate, sim: nil) }
        let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: "plan", device: cellular, now: Date())
        let f = AutomationService.makeFacts(contextJSON: merged, calendar: (CalendarService.demo(), true), settings: testSettings())
        XCTAssertNotNil(f.leftGB)
        let p = DayPlanner.plan(day: "today", facts: f)
        XCTAssertEqual(p.outings.count, 1, "デモ: ライブだけが外出(Zoom は外出ではない)")
        XCTAssertTrue([.short, .tight].contains(p.verdict), "\(p.verdict)")
        XCTAssertNotNil(p.suggestion)
    }
}
