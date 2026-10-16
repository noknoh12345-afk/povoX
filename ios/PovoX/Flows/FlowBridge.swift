import Foundation

extension FlowProduct {
    /// エンジンのトッピング(UniFFI)から。
    init(_ p: Product) {
        self.init(sku: p.sku, name: p.name, price: p.priceYen.map { Int($0) }, gb: p.dataGb, hours: p.hours,
                  unlimited: p.unlimited, requires3ds: p.requires3ds)
    }
}

extension AppServices {
    /// 画面・ショートカット用の「今の状態」(通信しない。手元の残量・一覧・予定から)。
    func planFacts(now: Date = Date()) async -> FlowFacts? {
        let c = client
        guard let ctx = try? await c.call({ try $0.ruleContextJson(mode: .simulate, sim: nil) }) else { return nil }
        let dev = await device.current()
        let merged = RuleContextBuilder.merge(engineContextJSON: ctx, trigger: "plan", device: dev, now: now)
        var f = AutomationService.makeFacts(contextJSON: merged, calendar: (calendar.events(now: now), calendar.authorized), settings: settings)
        let cat = await c.value { $0.cachedCatalog() }
        f.products = cat?.products.map(FlowProduct.init)
        return f
    }

    /// 今日と明日のプラン。
    func dayPlans() async -> (today: DayPlanner.Plan, tomorrow: DayPlanner.Plan)? {
        guard let f = await planFacts() else { return nil }
        return (DayPlanner.plan(day: "today", facts: f), DayPlanner.plan(day: "tomorrow", facts: f))
    }
}
