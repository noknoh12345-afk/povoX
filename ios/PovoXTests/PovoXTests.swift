import XCTest
@testable import PovoX

/// テスト用の保存先(キーチェーンを汚さない)。
final class MemoryStore: SessionStore {
    private let lock = NSLock()
    private var s: StoredSession?
    func load() -> StoredSession? { lock.lock(); defer { lock.unlock() }; return s }
    func save(session: StoredSession) { lock.lock(); s = session; lock.unlock() }
    func clear() { lock.lock(); s = nil; lock.unlock() }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("povox-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func mockClient(_ scenario: String = "") -> EngineClient {
    EngineClient(mock: true, scenario: scenario, directory: tempDir(), store: MemoryStore())
}

func login(_ c: EngineClient) async throws {
    _ = try await c.call { try $0.loginStart(email: "test@example.com", phone: nil) }
    let s = try await c.call { try $0.loginOtp(code: "000000") }
    XCTAssertTrue(s.done)
}

func testSettings() -> AppSettings {
    let suite = "povox-test-\(UUID().uuidString)"
    return AppSettings(defaults: UserDefaults(suiteName: suite)!)
}

final class EngineTests: XCTestCase {
    func testLoginSnapshotCatalog() async throws {
        let c = mockClient()
        try await login(c)
        let s = try await c.call { try $0.snapshot(force: false) }
        XCTAssertGreaterThan(s.leftKb ?? 0, 17 * Fmt.kbPerGB)
        XCTAssertEqual(s.unlimited.active, false)
        let cat = try await c.call { try $0.catalog(force: false) }
        XCTAssertEqual(cat.products.count, 4)
        XCTAssertTrue(cat.products.contains { $0.unlimited && $0.hours == 1 && $0.priceYen == 110 })
        let ins = await c.value { $0.insights() }
        XCTAssertNotNil(ins.kbPerHour)
    }

    func testTypedErrorAndHalt() async throws {
        let c = mockClient()
        try await login(c)
        do {
            _ = try await c.call { try $0.order(sku: "MOCK_FORBIDDEN", confirm: "購入する") }
            XCTFail("should throw")
        } catch let e as PovoXError {
            XCTAssertTrue(e.halted)
            XCTAssertEqual(e.povoStatus, 403)
        }
        let st = await c.value { $0.status() }
        XCTAssertNotNil(st.halted)
        await c.value { $0.unhalt() }
        let after = await c.value { $0.status() }
        XCTAssertNil(after.halted)
    }

    func testConfirmFlowThroughEngine() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let plan = #"{"type":"buy","sku":"MOCK_UNLIMITED_1H"}"#
        let rec = await c.value { $0.executeRun(input: RunInput(trigger: "t", mode: .live, batteryLevel: 50, charging: false, network: "cellular", planJson: plan, error: nil, scriptLogs: [], sim: nil)) }
        XCTAssertEqual(rec.outcomes.first?.status, .queued)
        let pid = try XCTUnwrap(rec.outcomes.first?.pendingId)
        let out = try await c.call { try $0.confirmPending(id: pid) }
        XCTAssertEqual(out.status, .done, out.message)
        let budget = await c.value { $0.budget() }
        XCTAssertEqual(budget.ruleSpentYen, 110)
    }
}

final class RuleEngineTests: XCTestCase {
    private func ctx(left: Double?, unlimited: Bool = false, battery: Int? = 80, charging: Bool = false, network: String = "cellular", hoursLeft: Double? = nil, mode: String = "live") -> String {
        let data: [String: Any] = [
            "leftGB": left as Any? ?? NSNull(), "leftMB": left.map { $0 * 1024 } as Any? ?? NSNull(),
            "unlimited": ["active": unlimited, "hoursLeft": unlimited ? 1.0 : NSNull()] as [String: Any],
            "toppings": [], "buckets": [],
        ]
        let c: [String: Any] = [
            "mode": mode, "data": data,
            "forecast": ["hoursLeft": hoursLeft as Any? ?? NSNull(), "mbPerHour": 30],
            "codes": [], "budget": ["capYen": 1000, "spentYen": 0], "settings": [:],
            "battery": ["level": battery as Any? ?? NSNull(), "charging": charging],
            "network": network, "now": ["hour": 12, "minute": 0, "weekday": 3], "trigger": "test",
        ]
        let d = try! JSONSerialization.data(withJSONObject: c)
        return String(data: d, encoding: .utf8)!
    }

    private func evaluate(_ rule: String, _ context: String, engine: PovoEngine? = nil) -> RuleEvaluation {
        RuleEngine.evaluate(rule: rule, contextJSON: context, prelude: RuleLibrary.prelude(), engine: engine, settings: testSettings())
    }

    private func plan(_ e: RuleEvaluation) -> [String: Any] {
        guard let p = e.planJSON, let o = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: Any] else {
            XCTFail("no plan: \(e.error ?? "")")
            return [:]
        }
        return o
    }

    func testResourcesAreBundled() {
        XCTAssertFalse(RuleLibrary.prelude().isEmpty)
        XCTAssertEqual(RuleLibrary.templates().count, RuleLibrary.templateIDs.count)
        for t in RuleLibrary.templates() {
            XCTAssertNil(RuleEngine.check(rule: t.source, prelude: RuleLibrary.prelude(), settings: testSettings()), t.id)
            XCTAssertFalse(t.summary.isEmpty, t.id)
        }
    }

    func testStandardTemplateDecisions() throws {
        let rule = try XCTUnwrap(RuleLibrary.template("standard")).source
        XCTAssertEqual(plan(evaluate(rule, ctx(left: 5)))["type"] as? String, "skip")
        XCTAssertEqual(plan(evaluate(rule, ctx(left: 0.2, network: "wifi")))["reason"] as? String, "Wi-Fi なので何もしない")
        XCTAssertEqual(plan(evaluate(rule, ctx(left: 0.2, unlimited: true)))["type"] as? String, "skip")
        // 残りわずか → firstOf(コード, 購入, 通知)。カタログはエンジン無しなので空 → 購入は skip
        let p = plan(evaluate(rule, ctx(left: 0.2)))
        XCTAssertEqual(p["type"] as? String, "firstOf")
        let items = try XCTUnwrap(p["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["type"] as? String }, ["applyCode", "skip", "notify"])
        // なくなりそう(予測)でも動く
        XCTAssertEqual(plan(evaluate(rule, ctx(left: 3, hoursLeft: 1)))["type"] as? String, "firstOf")
    }

    func testCatalogComesFromEngine() async throws {
        let c = mockClient("low")
        try await login(c)
        let rule = try XCTUnwrap(RuleLibrary.template("standard")).source
        let engineCtx = try await c.call { try $0.ruleContextJson(mode: .live, sim: nil) }
        let merged = RuleContextBuilder.merge(engineContextJSON: engineCtx, trigger: "test",
                                              device: DeviceState(batteryLevel: 10, charging: false, full: false, lowPower: true, network: "cellular"), now: Date())
        let e = evaluate(rule, merged, engine: c.engine)
        let items = try XCTUnwrap(plan(e)["items"] as? [[String: Any]])
        XCTAssertEqual(items[1]["sku"] as? String, "MOCK_UNLIMITED_1H", "電池が少ないので1時間")
        let merged2 = RuleContextBuilder.merge(engineContextJSON: engineCtx, trigger: "test",
                                               device: DeviceState(batteryLevel: 90, charging: false, full: false, lowPower: false, network: "cellular"), now: Date())
        let items2 = try XCTUnwrap(plan(evaluate(rule, merged2, engine: c.engine))["items"] as? [[String: Any]])
        XCTAssertEqual(items2[1]["sku"] as? String, "MOCK_UNLIMITED_24H")
    }

    func testErrorsAreReportedWithLines() {
        let e = evaluate("function decide(ctx) {\n  return ctx.nope.x;\n}", ctx(left: 1))
        XCTAssertNil(e.planJSON)
        XCTAssertTrue(e.error?.contains("2行目") == true, e.error ?? "")
        let syntax = RuleEngine.check(rule: "function decide( {", prelude: RuleLibrary.prelude(), settings: testSettings())
        XCTAssertNotNil(syntax)
        let missing = RuleEngine.check(rule: "function run(ctx) {}", prelude: RuleLibrary.prelude(), settings: testSettings())
        XCTAssertTrue(missing?.contains("decide") == true)
    }

    func testLogsStateAndShapes() {
        let s = testSettings()
        let rule = """
        function decide(ctx) {
          const n = state.get("n", 0) + 1;
          state.set("n", n);
          console.log("n", n, {a: 1});
          return [notify("t", "b"), "理由"];
        }
        """
        let e1 = RuleEngine.evaluate(rule: rule, contextJSON: ctx(left: 1), prelude: RuleLibrary.prelude(), engine: nil, settings: s)
        _ = RuleEngine.evaluate(rule: rule, contextJSON: ctx(left: 1), prelude: RuleLibrary.prelude(), engine: nil, settings: s)
        XCTAssertEqual(e1.logs, ["n 1 {\"a\":1}"])
        XCTAssertEqual(s.scriptState("n"), "2")
        let p = plan(e1)
        XCTAssertEqual(p["type"] as? String, "all")
    }

    func testInfiniteLoopIsStopped() throws {
        try XCTSkipUnless(RuleEngine.timeLimitSupported, "この OS では持ち時間の仕組みが見つからない")
        let done = expectation(description: "returns")
        var result: RuleEvaluation?
        DispatchQueue.global().async {
            result = RuleEngine.evaluate(rule: "function decide(){ while(true){} }", contextJSON: self.ctx(left: 1),
                                         prelude: RuleLibrary.prelude(), engine: nil, settings: testSettings())
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        XCTAssertNil(result?.planJSON)
        XCTAssertTrue(result?.error?.contains("秒") == true, result?.error ?? "")
    }
}

final class RecipeTests: XCTestCase {
    private func ctx(left: Double?, unlimited: Bool = false, unlHours: Double? = nil, battery: Int? = 80, charging: Bool = false,
                     network: String = "cellular", hoursLeft: Double? = 1, usedToday: Double = 100, hour: Int = 12, trigger: String = "manual") -> String {
        let data: [String: Any] = [
            "leftGB": left as Any? ?? NSNull(), "leftMB": left.map { $0 * 1024 } as Any? ?? NSNull(),
            "unlimited": ["active": unlimited, "hoursLeft": unlHours as Any? ?? NSNull()] as [String: Any],
            "toppings": [], "buckets": [],
        ]
        let c: [String: Any] = [
            "mode": "simulate", "data": data,
            "forecast": ["hoursLeft": hoursLeft as Any? ?? NSNull(), "mbPerHour": 200, "usedTodayMB": usedToday],
            "codes": [], "budget": ["capYen": 1000, "spentYen": 0], "settings": [:],
            "battery": ["level": battery as Any? ?? NSNull(), "charging": charging],
            "network": network, "now": ["hour": hour, "minute": 0, "weekday": 3], "trigger": trigger,
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: c), encoding: .utf8)!
    }

    func testCatalogLoadsAndIsLarge() {
        let all = RecipeLibrary.all()
        XCTAssertGreaterThanOrEqual(all.count, 250, "レシピは数百あるはず")
        XCTAssertEqual(Set(all.map { $0.id }).count, all.count, "ID は重複しない")
        XCTAssertFalse(RecipeLibrary.grouped().isEmpty)
        for r in all {
            XCTAssertFalse(r.title.isEmpty, r.id)
            XCTAssertFalse(r.summary.isEmpty, r.id)
        }
    }

    /// 全レシピが、構文として正しく decide を定義していること。
    func testEveryRecipeCompilesAndChecks() {
        let s = testSettings()
        for r in RecipeLibrary.all() {
            XCTAssertNil(RuleEngine.check(rule: r.rule, prelude: RuleLibrary.prelude(), settings: s), r.id)
        }
    }

    /// 全レシピが、代表的な場面で例外を出さず正しい形の計画を返すこと(エンジンのカタログつき)。
    func testEveryRecipeRunsWithoutError() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let s = testSettings()
        let scenarios = [
            ctx(left: 0.05), ctx(left: 5), ctx(left: 0.2, network: "wifi"),
            ctx(left: 0.2, unlimited: true, unlHours: 0.1), ctx(left: 0.2, hour: 3),
            ctx(left: 0.2, battery: 10), ctx(left: nil), ctx(left: 0.2, hoursLeft: 0.5),
            ctx(left: 0.2, usedToday: 5000), ctx(left: 0.2, trigger: "wifi-off"),
        ]
        for r in RecipeLibrary.all() {
            for sc in scenarios {
                let e = RuleEngine.evaluate(rule: r.rule, contextJSON: sc, prelude: RuleLibrary.prelude(), engine: c.engine, settings: s)
                XCTAssertNil(e.error, "\(r.id): \(e.error ?? "")")
                let node = try XCTUnwrap(e.planJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }, r.id)
                XCTAssertNotNil(node["type"] as? String, r.id)
            }
        }
    }

    /// いくつかのレシピが、意図どおりの判断をすること。
    func testRepresentativeRecipeDecisions() async throws {
        let c = mockClient("low")
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let s = testSettings()
        func decide(_ r: Recipe, _ context: String) -> [String: Any] {
            let e = RuleEngine.evaluate(rule: r.rule, contextJSON: context, prelude: RuleLibrary.prelude(), engine: c.engine, settings: s)
            return (e.planJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }) ?? [:]
        }
        // 残量ラインのレシピ: 十分あれば skip、少なければ firstOf
        let line = try XCTUnwrap(RecipeLibrary.all().first { $0.category == "残量ライン" && $0.params.low?.value == 0.5 })
        XCTAssertEqual(decide(line, ctx(left: 5))["type"] as? String, "skip")
        XCTAssertEqual(decide(line, ctx(left: 0.2))["type"] as? String, "firstOf")
        XCTAssertEqual(decide(line, ctx(left: 0.2, network: "wifi"))["type"] as? String, "skip", "wifiSkip")
        // 夜は買わない: 深夜は買い物が skip に変わる
        let night = try XCTUnwrap(RecipeLibrary.all().first { $0.category == "夜は買わない" })
        let nightPlan = decide(night, ctx(left: 0.05, hour: 3))
        if nightPlan["type"] as? String == "firstOf", let items = nightPlan["items"] as? [[String: Any]] {
            XCTAssertFalse(items.contains { $0["type"] as? String == "buy" }, "深夜は買わない")
        }
    }
}

final class AutomationTests: XCTestCase {
    private func service(_ client: EngineClient, settings: AppSettings, device: DeviceState, sink: @escaping ([PlannedNotification]) -> Void) -> AutomationService {
        AutomationService(.init(
            client: { client },
            device: { device },
            settings: { settings },
            notify: { sink($0) },
            afterRun: { _ in }
        ))
    }

    func testLiveRunQueuesConfirmationAndNotifies() async throws {
        let c = mockClient("low")
        try await login(c)
        let s = testSettings()
        var sent: [PlannedNotification] = []
        let svc = service(c, settings: s, device: DeviceState(batteryLevel: 12, charging: false, full: false, lowPower: true, network: "cellular")) { sent += $0 }
        let rec = try await XCTUnwrapAsync(await svc.run(trigger: "test"))
        XCTAssertNil(rec.error, rec.error ?? "")
        XCTAssertTrue(rec.outcomes.contains { $0.status == .queued && $0.label.contains("1時間") }, rec.summary)
        XCTAssertEqual(sent.first?.kind, .confirm)
        XCTAssertNotNil(s.lastRun)
        // Wi-Fi なら何もしない
        let svc2 = service(c, settings: s, device: DeviceState(batteryLevel: 80, charging: false, full: false, lowPower: false, network: "wifi")) { _ in }
        let rec2 = try await XCTUnwrapAsync(await svc2.run(trigger: "test"))
        XCTAssertEqual(rec2.summary, "Wi-Fi なので何もしない")
    }

    func testNotLoggedInOrHaltedDoesNothing() async throws {
        let c = mockClient()
        let svc = service(c, settings: testSettings(), device: .unknown) { _ in XCTFail("no notifications") }
        let r = await svc.run(trigger: "test")
        XCTAssertNil(r)
    }

    func testSimulationUsesSimulatedState() async throws {
        let c = mockClient()
        try await login(c)
        _ = try await c.call { try $0.catalog(force: false) }
        let s = testSettings()
        let svc = service(c, settings: s, device: .unknown) { _ in }
        let sim = SimInput(leftKb: 0.1 * Fmt.kbPerGB, unlimited: false, unlimitedHoursLeft: nil, hoursLeft: 1)
        let r = await svc.simulate(sim, device: DeviceState(batteryLevel: 10, charging: false, full: false, lowPower: true, network: "cellular"), trigger: "sim")
        XCTAssertTrue(r.outcomes.contains { $0.status == .simulated && $0.label.contains("1時間") }, r.summary)
        let runs = await c.value { $0.runs(limit: 10) }
        XCTAssertTrue(runs.isEmpty, "シミュレーションは記録しない")
    }
}

func XCTUnwrapAsync<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(v, file: file, line: line)
}

final class StorageTests: XCTestCase {
    func testKeychainRoundTrip() {
        let store = KeychainSessionStore(service: "povoX-test-\(UUID().uuidString)")
        XCTAssertNil(store.load())
        let s = StoredSession(deviceId: "d", authToken: "t", sin: "s", identifier: "me@example.com")
        store.save(session: s)
        XCTAssertEqual(store.load(), s)
        store.save(session: StoredSession(deviceId: "d", authToken: "t2", sin: nil, identifier: "me@example.com"))
        XCTAssertEqual(store.load()?.authToken, "t2")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testSharedSnapshotRoundTrip() {
        let dir = tempDir()
        let s = SharedSnapshot(updatedAt: Date(timeIntervalSince1970: 1_700_000_000), leftKB: 123, planKB: 456, unlimitedActive: true,
                               unlimitedUntil: Date(timeIntervalSince1970: 1_700_003_600), hoursLeft: 2, pendingCount: 1, mock: true, lastSummary: "x")
        XCTAssertTrue(s.save(to: dir))
        XCTAssertEqual(SharedSnapshot.load(from: dir), s)
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.data(kb: 256 * 1024), "256MB")
        XCTAssertEqual(Fmt.data(kb: 1.5 * Fmt.kbPerGB), "1.50GB")
        XCTAssertEqual(Fmt.duration(hours: 0.5), "約30分")
        XCTAssertEqual(Fmt.duration(hours: 50), "約2日2時間")
        XCTAssertEqual(Fmt.yen(2700), "2,700円")
    }
}

final class IntentTests: XCTestCase {
    func testShortcutIntentsRunInApp() async throws {
        let services = AppServices.shared
        services.setMock(true)
        let c = services.client
        if !(await c.value { $0.status() }.loggedIn) {
            try await login(c)
        }
        // 残量
        let remaining = RemainingDataIntent()
        _ = try await remaining.perform()
        // 自動チェック(きっかけの文字はルールの ctx.trigger に入る)
        var check = RunCheckIntent()
        check.trigger = "battery-low"
        _ = try await check.perform()
        let runs = await c.value { $0.runs(limit: 5) }
        XCTAssertEqual(runs.first?.trigger, "battery-low")
        // 購入のしかたを切り替える
        var mode = SetPurchaseModeIntent()
        mode.mode = .off
        _ = try await mode.perform()
        let after = await c.value { $0.settings() }
        XCTAssertEqual(after.purchaseMode, .off)
        mode.mode = .confirm
        _ = try await mode.perform()
    }
}
