import Foundation

/// ギャラリー: すぐ使える、よく練ったオートメーション。選ぶと自分のオートメーションにコピーされる。
struct FlowTemplate: Identifiable {
    let id: String
    let category: String
    let blurb: String
    let make: () -> Flow
}

enum FlowGallery {
    static let categories = ["予定に合わせる", "ワンタップ", "使い放題", "残量の見張り", "つながり・電池", "モード", "お知らせ"]

    static let all: [FlowTemplate] = [
        // 予定に合わせる
        FlowTemplate(id: "g.calendar.unlimited", category: "予定に合わせる",
                     blurb: "外出の予定の30分前、今日の予定に残量が足りないときだけ、予定の長さに合った使い放題を「実行する」ボタンつきで知らせます。") {
            Flow(name: "出かける前に使い放題", symbol: "figure.walk.departure", color: "orange",
                 trigger: .calendar(lead: 30, outingOnly: true),
                 conditions: [.dayShort, .unlimitedInactive],
                 actions: [.code(), .unlimited(0)], ask: true, galleryID: "g.calendar.unlimited")
        },
        FlowTemplate(id: "g.calendar.tomorrow", category: "予定に合わせる",
                     blurb: "毎晩21時に、明日の予定と残量から「明日は何をしておくと楽か」を知らせます。") {
            Flow(name: "明日のプラン", symbol: "moon.stars.fill", color: "purple",
                 trigger: .time(21, 0), actions: [.brief("tomorrow")], ask: false, galleryID: "g.calendar.tomorrow")
        },
        FlowTemplate(id: "g.calendar.morning", category: "予定に合わせる",
                     blurb: "朝7時半に、今日の外出と残量のまとめを知らせます(平日)。") {
            Flow(name: "朝のプラン", symbol: "sun.max.fill", color: "yellow",
                 trigger: .time(7, 30, weekdays: [1, 2, 3, 4, 5]), actions: [.brief("today")], ask: false, galleryID: "g.calendar.morning")
        },
        FlowTemplate(id: "g.calendar.heads-up", category: "予定に合わせる",
                     blurb: "外出の予定の1時間前に、残量と予定を知らせます。") {
            Flow(name: "出発1時間前のおしらせ", symbol: "bell.badge.fill", color: "blue",
                 trigger: .calendar(lead: 60, outingOnly: true),
                 actions: [.notify("{予定}まであと1時間", "{開始} {場所}\n残り {残量}(このペースで{あと})")], ask: false,
                 galleryID: "g.calendar.heads-up")
        },
        FlowTemplate(id: "g.calendar.travel", category: "予定に合わせる",
                     blurb: "「旅行」「出張」などの予定の朝、購入とコードを「自動」に切り替え、旅先で残量を気にしなくて済むようにします。") {
            Flow(name: "旅行の日は自動に", symbol: "airplane", color: "teal",
                 trigger: .calendar(lead: 120, outingOnly: true, keyword: "旅行"),
                 actions: [.purchaseMode("auto"), .codeMode("auto"), .notify("旅行モード", "{予定}のあいだ、購入とコードを自動にしました")],
                 ask: false, galleryID: "g.calendar.travel")
        },

        // ワンタップ(ホームに置く)
        FlowTemplate(id: "g.tap.1h", category: "ワンタップ", blurb: "ホームのボタン1つで、1時間使い放題を入れます。") {
            Flow(name: "1時間使い放題", symbol: "infinity", color: "yellow", trigger: .manual(),
                 actions: [.unlimited(1)], ask: false, showOnHome: true, galleryID: "g.tap.1h")
        },
        FlowTemplate(id: "g.tap.24h", category: "ワンタップ", blurb: "ホームのボタン1つで、24時間使い放題を入れます。") {
            Flow(name: "24時間使い放題", symbol: "sun.max.fill", color: "orange", trigger: .manual(),
                 actions: [.unlimited(24)], ask: false, showOnHome: true, galleryID: "g.tap.24h")
        },
        FlowTemplate(id: "g.tap.code", category: "ワンタップ", blurb: "手持ちのコードを1枚使います(なければ何もしません)。") {
            Flow(name: "コードを1枚", symbol: "ticket.fill", color: "green", trigger: .manual(),
                 conditions: [.hasCodes()], actions: [.code()], ask: false, showOnHome: true, galleryID: "g.tap.code")
        },
        FlowTemplate(id: "g.tap.plan", category: "ワンタップ", blurb: "今日(夕方からは明日)のプランを通知で受け取ります。") {
            Flow(name: "プランを確認", symbol: "calendar.badge.checkmark", color: "blue", trigger: .manual(),
                 actions: [.brief("auto")], ask: false, showOnHome: true, galleryID: "g.tap.plan")
        },
        FlowTemplate(id: "g.tap.go", category: "ワンタップ",
                     blurb: "出かけるときに押す: コードがあればコード、なければ予定の長さに合った使い放題。") {
            Flow(name: "いってきます", symbol: "figure.walk", color: "pink", trigger: .manual(),
                 conditions: [.unlimitedInactive], actions: [.code(), .unlimited(0)], ask: false, showOnHome: true, galleryID: "g.tap.go")
        },

        // 使い放題
        FlowTemplate(id: "g.unl.ending", category: "使い放題", blurb: "使い放題が終わる10分前に知らせます。") {
            Flow(name: "使い放題が終わる前に", symbol: "timer", color: "orange", trigger: .unlimitedEnding(10),
                 actions: [.notify("使い放題がもうすぐ終わります", "{使い放題}")], ask: false, galleryID: "g.unl.ending")
        },
        FlowTemplate(id: "g.unl.extend", category: "使い放題",
                     blurb: "外出の予定の最中に使い放題が切れたら、同じように続けます(確認つき)。") {
            Flow(name: "外出中は使い放題を継ぐ", symbol: "arrow.clockwise.circle.fill", color: "orange", trigger: .unlimitedEnded(),
                 conditions: [.inOuting, .onCellular], actions: [.code(), .unlimited(0)], ask: true, galleryID: "g.unl.extend")
        },

        // 残量の見張り
        FlowTemplate(id: "g.low.100", category: "残量の見張り",
                     blurb: "モバイル通信で残り100MBを切ったら、コード → 1時間使い放題の順で手を打ちます(確認つき)。") {
            Flow(name: "残り100MBで手を打つ", symbol: "exclamationmark.triangle.fill", color: "red", trigger: .dataBelow(0.1),
                 conditions: [.onCellular], actions: [.code(), .unlimited(1)], ask: true, galleryID: "g.low.100")
        },
        FlowTemplate(id: "g.low.pace", category: "残量の見張り", blurb: "このペースだと3時間以内になくなりそうなら知らせます。") {
            Flow(name: "なくなりそうなら知らせる", symbol: "hourglass.bottomhalf.filled", color: "orange", trigger: .hoursLeftBelow(3),
                 actions: [.notify("povo: このペースだと{あと}でなくなります", "残り {残量}")], ask: false, galleryID: "g.low.pace")
        },
        FlowTemplate(id: "g.low.heavy", category: "残量の見張り", blurb: "今日1GB以上使ったら知らせます(動画の見すぎに)。") {
            Flow(name: "今日の使いすぎ", symbol: "chart.bar.fill", color: "pink", trigger: .usedToday(1000),
                 actions: [.notify("今日はもう{今日}使いました", "残り {残量}")], ask: false, galleryID: "g.low.heavy")
        },

        // つながり・電池
        FlowTemplate(id: "g.net.leave", category: "つながり・電池",
                     blurb: "Wi-Fi から離れたとき、残りが500MB未満ならコードを使います(確認つき)。") {
            Flow(name: "Wi-Fiを離れたら補充", symbol: "wifi.slash", color: "blue", trigger: .leftWifi(),
                 conditions: [.dataBelow(0.5)], actions: [.code(), .notify("Wi-Fi を離れました", "残り {残量}")], ask: true,
                 galleryID: "g.net.leave")
        },
        FlowTemplate(id: "g.batt.low", category: "つながり・電池",
                     blurb: "電池が20%以下で残量も少ないときは、長い使い放題ではなく1時間だけ入れます(確認つき)。") {
            Flow(name: "電池が少ないときは1時間", symbol: "battery.25percent", color: "green", trigger: .batteryBelow(20),
                 conditions: [.dataBelow(0.3), .onCellular], actions: [.unlimited(1)], ask: true, galleryID: "g.batt.low")
        },
        FlowTemplate(id: "g.batt.unplug", category: "つながり・電池", blurb: "充電器を外したとき、残りが少なければ知らせます。") {
            Flow(name: "充電器を外したら確認", symbol: "powerplug", color: "gray", trigger: .unplugged(),
                 conditions: [.dataBelow(0.5)], actions: [.notify("出かける前に", "残り {残量}。必要なら使い放題を")], ask: false,
                 galleryID: "g.batt.unplug")
        },

        // モード
        FlowTemplate(id: "g.mode.travel", category: "モード", blurb: "押すと、購入とコードを「自動」にします(旅行・遠出の日に)。") {
            Flow(name: "おまかせモード", symbol: "wand.and.stars", color: "purple", trigger: .manual(),
                 actions: [.purchaseMode("auto"), .codeMode("auto"), .notify("おまかせモード", "購入とコードを自動にしました(上限は今のまま)")],
                 ask: false, showOnHome: true, galleryID: "g.mode.travel")
        },
        FlowTemplate(id: "g.mode.normal", category: "モード", blurb: "押すと、購入とコードを「通知で確認」に戻します。") {
            Flow(name: "いつものモード", symbol: "hand.raised.fill", color: "gray", trigger: .manual(),
                 actions: [.purchaseMode("confirm"), .codeMode("confirm"), .notify("いつものモード", "購入とコードを「通知で確認」に戻しました")],
                 ask: false, showOnHome: true, galleryID: "g.mode.normal")
        },
        FlowTemplate(id: "g.mode.home", category: "モード", blurb: "Wi-Fi につながったら(家に帰ったら)、購入を「通知で確認」に戻します。") {
            Flow(name: "帰ったら確認に戻す", symbol: "house.fill", color: "green", trigger: .joinedWifi(),
                 actions: [.purchaseMode("confirm"), .codeMode("confirm")], ask: false, galleryID: "g.mode.home")
        },

        // お知らせ
        FlowTemplate(id: "g.info.shortcut", category: "お知らせ",
                     blurb: "ショートカット App のオートメーション(例: 駅に着いたら)から「出発」の名前で呼ぶと、使い放題を入れます。") {
            Flow(name: "ショートカット「出発」", symbol: "square.2.layers.3d.top.filled", color: "teal", trigger: .shortcut("出発"),
                 actions: [.unlimited(24)], ask: true, galleryID: "g.info.shortcut")
        },
    ]

    static func template(_ id: String) -> FlowTemplate? { all.first { $0.id == id } }

    /// 初めて開いたときに入れておくもの。お金が動くものは「ボタンで実行」か「確認つき」だけ。
    /// 何もしなくても、予定の前・使い放題の終わり・前の晩に役立つ。
    static let seedIDs = ["g.calendar.unlimited", "g.calendar.tomorrow", "g.unl.ending", "g.tap.1h", "g.tap.24h", "g.tap.go", "g.tap.plan"]

    static func seeds() -> [Flow] {
        seedIDs.compactMap { template($0)?.make() }
    }

    /// ギャラリーから自分のオートメーションへ(新しい ID で)。
    static func instantiate(_ t: FlowTemplate) -> Flow {
        var f = t.make()
        f.id = UUID().uuidString
        f.createdMs = Int64(Date().timeIntervalSince1970 * 1000)
        f.conditions = f.conditions.map { var c = $0; c.id = UUID().uuidString; return c }
        f.actions = f.actions.map { var a = $0; a.id = UUID().uuidString; return a }
        return f
    }
}

/// オートメーションの保存(UserDefaults に JSON)。自動チェック(別スレッド)と画面の両方から使う。
final class FlowStore {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let flowsKey = "flows.v1"
    private static let memoryKey = "flows.memory.v1"
    private static let seededKey = "flows.seeded"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func flows() -> [Flow] {
        lock.lock(); defer { lock.unlock() }
        return loadFlows()
    }

    private func loadFlows() -> [Flow] {
        guard let data = defaults.data(forKey: FlowStore.flowsKey),
              let list = try? JSONDecoder().decode([Flow].self, from: data) else { return [] }
        return list
    }

    private func storeFlows(_ list: [Flow]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: FlowStore.flowsKey) }
    }

    func flow(_ id: String) -> Flow? { flows().first { $0.id == id } }

    func save(_ list: [Flow]) {
        lock.lock(); defer { lock.unlock() }
        storeFlows(list)
    }

    /// 1つ保存する(無ければ足す)。
    func upsert(_ f: Flow) {
        lock.lock(); defer { lock.unlock() }
        var list = loadFlows()
        if let i = list.firstIndex(where: { $0.id == f.id }) { list[i] = f } else { list.append(f) }
        storeFlows(list)
    }

    func delete(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        storeFlows(loadFlows().filter { $0.id != id })
    }

    func setEnabled(_ id: String, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        var list = loadFlows()
        if let i = list.firstIndex(where: { $0.id == id }) { list[i].enabled = on }
        storeFlows(list)
    }

    func memory() -> FlowMemory {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: FlowStore.memoryKey),
              let m = try? JSONDecoder().decode(FlowMemory.self, from: data) else { return FlowMemory() }
        return m
    }

    func saveMemory(_ m: FlowMemory) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(m) { defaults.set(data, forKey: FlowStore.memoryKey) }
    }

    /// 初めてのときだけ、すぐ役立つオートメーションを入れておく。
    func seedIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !defaults.bool(forKey: FlowStore.seededKey) else { return }
        defaults.set(true, forKey: FlowStore.seededKey)
        if loadFlows().isEmpty { storeFlows(FlowGallery.seeds()) }
    }
}
