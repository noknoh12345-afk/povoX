import Foundation

// オートメーション(povoX に内蔵した「ショートカット」)。
//
// 1つのオートメーション = 「いつ(きっかけ)」+「もし(条件)」+「すること(アクション)」。
// iOS のショートカット App の「オートメーション」と同じ形で、povoX の自動チェックのたびに評価する。
// povo へ送る操作(コード・購入)は計画(JSON)にしてエンジンへ渡し、エンジンの安全装置
// (上限・回数・間隔・3DS 除外・確認・1回1つ)を必ず通る。
//
// このファイルは Foundation だけを使う(パソコン上でもテストできるように)。

// MARK: - きっかけ

enum FlowTriggerKind: String, Codable, CaseIterable {
    /// ボタンで実行(ホームのタイル・Siri・ショートカット App)。自動では動かない。
    case manual
    /// 自動チェックのたび(間隔をあけて)。
    case anyCheck
    /// 残量が X GB を下回ったとき。
    case dataBelow
    /// このペースで あと X 時間を切ったとき。
    case hoursLeftBelow
    /// 使い放題の残りが X 分を切ったとき。
    case unlimitedEnding
    /// 使い放題が終わったとき。
    case unlimitedEnded
    /// Wi-Fi から離れたとき(モバイル通信になった)。
    case leftWifi
    /// Wi-Fi につながったとき。
    case joinedWifi
    /// 電池が X% を下回ったとき(充電していない)。
    case batteryBelow
    /// 充電器を外したとき。
    case unplugged
    /// 毎日(または指定の曜日)の決まった時刻。
    case timeOfDay
    /// カレンダーの予定が始まる N 分前。
    case calendarEvent
    /// 今日 X MB 以上使ったとき。
    case usedTodayAbove
    /// どこかに着いたとき(位置情報)。
    case arrive
    /// どこかを出たとき(位置情報)。
    case leave
    /// ショートカット App のオートメーションから、決めた名前で呼ばれたとき。
    case shortcut
    /// 予約(決めた日時に1回だけ)。
    case once
}

struct FlowTrigger: Codable, Equatable {
    var kind: FlowTriggerKind
    var gb: Double?
    var hours: Double?
    var minutes: Int?
    var percent: Int?
    var mb: Int?
    var hour: Int?
    var minute: Int?
    /// 0=日 … 6=土。nil は毎日。
    var weekdays: [Int]?
    /// 予定の何分前か。
    var leadMin: Int?
    /// 予定のタイトル・場所に含む言葉(空なら全部)。
    var keyword: String?
    /// 外出の予定だけ(場所がある・旅行やライブなど)。
    var outingOnly: Bool?
    /// ショートカットから呼ぶときの名前。
    var name: String?
    /// 予約の日時(ミリ秒)。
    var atMs: Int64?

    init(_ kind: FlowTriggerKind) { self.kind = kind }

    static func manual() -> FlowTrigger { FlowTrigger(.manual) }
    static func anyCheck() -> FlowTrigger { FlowTrigger(.anyCheck) }
    static func dataBelow(_ gb: Double) -> FlowTrigger { var t = FlowTrigger(.dataBelow); t.gb = gb; return t }
    static func hoursLeftBelow(_ h: Double) -> FlowTrigger { var t = FlowTrigger(.hoursLeftBelow); t.hours = h; return t }
    static func unlimitedEnding(_ min: Int) -> FlowTrigger { var t = FlowTrigger(.unlimitedEnding); t.minutes = min; return t }
    static func unlimitedEnded() -> FlowTrigger { FlowTrigger(.unlimitedEnded) }
    static func leftWifi() -> FlowTrigger { FlowTrigger(.leftWifi) }
    static func joinedWifi() -> FlowTrigger { FlowTrigger(.joinedWifi) }
    static func batteryBelow(_ p: Int) -> FlowTrigger { var t = FlowTrigger(.batteryBelow); t.percent = p; return t }
    static func unplugged() -> FlowTrigger { FlowTrigger(.unplugged) }
    static func time(_ hour: Int, _ minute: Int, weekdays: [Int]? = nil) -> FlowTrigger {
        var t = FlowTrigger(.timeOfDay); t.hour = hour; t.minute = minute; t.weekdays = weekdays; return t
    }
    static func calendar(lead: Int, outingOnly: Bool = true, keyword: String? = nil) -> FlowTrigger {
        var t = FlowTrigger(.calendarEvent); t.leadMin = lead; t.outingOnly = outingOnly; t.keyword = keyword; return t
    }
    static func usedToday(_ mb: Int) -> FlowTrigger { var t = FlowTrigger(.usedTodayAbove); t.mb = mb; return t }
    static func arrive() -> FlowTrigger { FlowTrigger(.arrive) }
    static func leave() -> FlowTrigger { FlowTrigger(.leave) }
    static func shortcut(_ name: String) -> FlowTrigger { var t = FlowTrigger(.shortcut); t.name = name; return t }
    static func once(_ at: Date) -> FlowTrigger { var t = FlowTrigger(.once); t.atMs = Int64(at.timeIntervalSince1970 * 1000); return t }

    /// 時刻に結びついたきっかけ(予約の通知を出す)。
    var isScheduled: Bool { kind == .timeOfDay || kind == .calendarEvent || kind == .once }
}

// MARK: - 条件

enum FlowConditionKind: String, Codable, CaseIterable {
    case dataBelow, dataAbove, hoursLeftBelow
    case unlimitedActive, unlimitedInactive
    case onWifi, onCellular
    case batteryBelow, charging, notCharging, lowPower
    case timeBetween, weekdays
    case hasCodes
    /// 今、外出の予定の最中。
    case inOuting
    /// N 時間以内に外出の予定がある。
    case outingWithin
    /// 今日の予定に対して残量が足りない(今日のプランが「足りない」「ぎりぎり」)。
    case dayShort
    case usedTodayAbove
}

struct FlowCondition: Codable, Equatable, Identifiable {
    var id: String
    var kind: FlowConditionKind
    var gb: Double?
    var hours: Double?
    var percent: Int?
    var mb: Int?
    var from: Int?
    var to: Int?
    var weekdays: [Int]?
    var tag: String?

    init(_ kind: FlowConditionKind, id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
    }

    static func dataBelow(_ gb: Double) -> FlowCondition { var c = FlowCondition(.dataBelow); c.gb = gb; return c }
    static func dataAbove(_ gb: Double) -> FlowCondition { var c = FlowCondition(.dataAbove); c.gb = gb; return c }
    static func hoursLeftBelow(_ h: Double) -> FlowCondition { var c = FlowCondition(.hoursLeftBelow); c.hours = h; return c }
    static func batteryBelow(_ p: Int) -> FlowCondition { var c = FlowCondition(.batteryBelow); c.percent = p; return c }
    static func between(_ from: Int, _ to: Int) -> FlowCondition { var c = FlowCondition(.timeBetween); c.from = from; c.to = to; return c }
    static func weekdays(_ d: [Int]) -> FlowCondition { var c = FlowCondition(.weekdays); c.weekdays = d; return c }
    static func outingWithin(_ h: Double) -> FlowCondition { var c = FlowCondition(.outingWithin); c.hours = h; return c }
    static func usedTodayAbove(_ mb: Int) -> FlowCondition { var c = FlowCondition(.usedTodayAbove); c.mb = mb; return c }
    static func hasCodes(tag: String? = nil) -> FlowCondition { var c = FlowCondition(.hasCodes); c.tag = tag; return c }
    static var onWifi: FlowCondition { FlowCondition(.onWifi) }
    static var onCellular: FlowCondition { FlowCondition(.onCellular) }
    static var unlimitedActive: FlowCondition { FlowCondition(.unlimitedActive) }
    static var unlimitedInactive: FlowCondition { FlowCondition(.unlimitedInactive) }
    static var dayShort: FlowCondition { FlowCondition(.dayShort) }
    static var inOuting: FlowCondition { FlowCondition(.inOuting) }
}

// MARK: - アクション

enum FlowActionKind: String, Codable, CaseIterable {
    /// 手持ちのコードを1枚使う(タグ指定可)。
    case applyCode
    /// 使い放題を入れる(hours: 1 / 24 / … / 0 = 予定の長さに合わせる)。
    case buyUnlimited
    /// データ追加を買う(gb 指定。nil は一番小さいもの)。
    case buyData
    /// 通知を出す(本文に {残量} などを差し込める)。
    case notify
    /// 今日/明日のプラン(予定と残量)を通知する。
    case dayBrief
    /// ルールによる購入のしかたを変える。
    case setPurchaseMode
    /// ルールによるコードのしかたを変える。
    case setCodeMode
    /// ほかのオートメーションをオン/オフ。
    case setFlowEnabled
    /// 履歴にメモを残す。
    case log
}

struct FlowAction: Codable, Equatable, Identifiable {
    var id: String
    var kind: FlowActionKind
    var tag: String?
    var hours: Int?
    var gb: Double?
    var title: String?
    var body: String?
    /// "off" / "confirm" / "auto"
    var mode: String?
    var flowID: String?
    var on: Bool?
    /// "today" / "tomorrow" / "auto"(18時以降は明日)
    var day: String?

    init(_ kind: FlowActionKind, id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
    }

    static func code(tag: String? = nil) -> FlowAction { var a = FlowAction(.applyCode); a.tag = tag; return a }
    static func unlimited(_ hours: Int) -> FlowAction { var a = FlowAction(.buyUnlimited); a.hours = hours; return a }
    static func data(_ gb: Double? = nil) -> FlowAction { var a = FlowAction(.buyData); a.gb = gb; return a }
    static func notify(_ title: String, _ body: String) -> FlowAction { var a = FlowAction(.notify); a.title = title; a.body = body; return a }
    static func brief(_ day: String = "auto") -> FlowAction { var a = FlowAction(.dayBrief); a.day = day; return a }
    static func purchaseMode(_ m: String) -> FlowAction { var a = FlowAction(.setPurchaseMode); a.mode = m; return a }
    static func codeMode(_ m: String) -> FlowAction { var a = FlowAction(.setCodeMode); a.mode = m; return a }
    static func flowEnabled(_ id: String, _ on: Bool) -> FlowAction { var a = FlowAction(.setFlowEnabled); a.flowID = id; a.on = on; return a }
    static func log(_ text: String) -> FlowAction { var a = FlowAction(.log); a.body = text; return a }

    /// povo に送る操作(コード・購入)。
    var touchesPovo: Bool { kind == .applyCode || kind == .buyUnlimited || kind == .buyData }
    /// お金が動く操作。
    var spends: Bool { kind == .buyUnlimited || kind == .buyData }
}

// MARK: - オートメーション

struct Flow: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// SF Symbols の名前。
    var symbol: String
    /// 色の名前(FlowPalette)。
    var color: String
    var enabled: Bool
    var trigger: FlowTrigger
    var conditions: [FlowCondition]
    /// true = すべての条件 / false = どれかの条件。
    var matchAll: Bool
    var actions: [FlowAction]
    /// 実行前に確認する(購入・コードは設定が「自動」でも通知で確認)。
    var ask: Bool
    /// 予約など、作ったときに利用者が実行を決めたもの(確認を飛ばす。設定の「しない」と上限は守る)。
    var preconfirmed: Bool
    /// 一度動いたら、次に動けるまでの分。
    var cooldownMin: Int
    /// ホームに「ショートカット」として置く。
    var showOnHome: Bool
    /// ギャラリーから入れたときの元。
    var galleryID: String?
    var createdMs: Int64

    init(id: String = UUID().uuidString, name: String, symbol: String = "bolt.fill", color: String = "yellow",
         enabled: Bool = true, trigger: FlowTrigger, conditions: [FlowCondition] = [], matchAll: Bool = true,
         actions: [FlowAction], ask: Bool = true, preconfirmed: Bool = false, cooldownMin: Int? = nil,
         showOnHome: Bool = false, galleryID: String? = nil, createdMs: Int64? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.enabled = enabled
        self.trigger = trigger
        self.conditions = conditions
        self.matchAll = matchAll
        self.actions = actions
        self.ask = ask
        self.preconfirmed = preconfirmed
        self.cooldownMin = cooldownMin ?? Flow.defaultCooldown(for: trigger.kind)
        self.showOnHome = showOnHome
        self.galleryID = galleryID
        self.createdMs = createdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func defaultCooldown(for kind: FlowTriggerKind) -> Int {
        switch kind {
        case .anyCheck: return 60
        case .manual, .shortcut, .once, .timeOfDay, .calendarEvent: return 0
        default: return 30
        }
    }

    var touchesPovo: Bool { actions.contains { $0.touchesPovo } }
    var spends: Bool { actions.contains { $0.spends } }
    /// 通知だけのオートメーション(時刻のものは通知そのものが実行になる)。
    var notifyOnly: Bool { !actions.isEmpty && actions.allSatisfy { $0.kind == .notify || $0.kind == .dayBrief || $0.kind == .log } }
}

// MARK: - 評価に使う材料

/// 予定(カレンダー)。
struct CalEvent: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var location: String?
    var startMs: Int64
    var endMs: Int64
    var allDay: Bool
    var calendar: String?

    var start: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    var end: Date { Date(timeIntervalSince1970: Double(endMs) / 1000) }
}

/// トッピング(評価用の軽い形)。
struct FlowProduct: Equatable {
    var sku: String
    var name: String
    var price: Int?
    var gb: Double?
    var hours: Double?
    var unlimited: Bool
    var requires3ds: Bool

    /// ルールの ctx.catalog() と同じ JSON の配列から。
    static func list(fromJSON json: String) -> [FlowProduct] {
        guard let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let sku = d["sku"] as? String else { return nil }
            return FlowProduct(sku: sku, name: d["name"] as? String ?? sku, price: (d["price"] as? NSNumber)?.intValue,
                               gb: (d["gb"] as? NSNumber)?.doubleValue, hours: (d["hours"] as? NSNumber)?.doubleValue,
                               unlimited: d["unlimited"] as? Bool ?? false, requires3ds: d["requires3ds"] as? Bool ?? false)
        }
    }
}

/// 自動チェック1回分の「今の状態」。ルールの ctx(エンジン + 端末)から作る。
struct FlowFacts {
    var trigger = ""
    var mode = "live"
    var now = Date()
    var leftGB: Double?
    var hoursLeft: Double?
    var mbPerHour: Double?
    var usedTodayMB: Double?
    var unlimitedActive: Bool?
    var unlimitedHoursLeft: Double?
    var battery: Int?
    var charging = false
    var lowPower = false
    var network = "unknown"
    /// 未使用コードのタグ(タグなしは "")。
    var codeTags: [String] = []
    /// 今日と明日の予定。
    var events: [CalEvent] = []
    /// カレンダーを読めるか。
    var calendarAuthorized = false
    /// 予定から見積もる使い方の濃さ(0.5 / 1 / 1.8)。
    var intensity = 1.0
    /// 手元のトッピング一覧(必要になったときだけ読む)。
    var products: [FlowProduct]?

    init() {}

    init(contextJSON: String) {
        let ctx = (try? JSONSerialization.jsonObject(with: Data(contextJSON.utf8))) as? [String: Any] ?? [:]
        func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        trigger = ctx["trigger"] as? String ?? ""
        mode = ctx["mode"] as? String ?? "live"
        if let now = ctx["now"] as? [String: Any], let ms = num(now["ms"]) { self.now = Date(timeIntervalSince1970: ms / 1000) }
        if let d = ctx["data"] as? [String: Any] {
            leftGB = num(d["leftGB"])
            if let u = d["unlimited"] as? [String: Any] {
                unlimitedActive = u["active"] as? Bool
                unlimitedHoursLeft = num(u["hoursLeft"])
            }
        }
        if let f = ctx["forecast"] as? [String: Any] {
            hoursLeft = num(f["hoursLeft"])
            mbPerHour = num(f["mbPerHour"])
            usedTodayMB = num(f["usedTodayMB"])
        }
        if let b = ctx["battery"] as? [String: Any] {
            battery = (b["level"] as? NSNumber)?.intValue
            charging = b["charging"] as? Bool ?? false
            lowPower = b["lowPower"] as? Bool ?? false
        }
        network = ctx["network"] as? String ?? "unknown"
        codeTags = (ctx["codes"] as? [[String: Any]] ?? []).map { $0["tag"] as? String ?? "" }
    }

    var leftMB: Double? { leftGB.map { $0 * 1024 } }
}

/// 色(画面で使う名前)。
enum FlowPalette {
    static let names = ["yellow", "orange", "red", "pink", "purple", "blue", "teal", "green", "gray"]
}
