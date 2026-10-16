import Foundation

/// オートメーションの部品を、人が読める短い文にする(エディタ・一覧・通知・履歴で使う)。
enum FlowText {
    // MARK: - きっかけ

    static func triggerTitle(_ k: FlowTriggerKind) -> String {
        switch k {
        case .manual: return "ボタンで実行"
        case .anyCheck: return "自動チェックのたび"
        case .dataBelow: return "残量が少なくなったら"
        case .hoursLeftBelow: return "このペースでなくなりそうなら"
        case .unlimitedEnding: return "使い放題が終わる前"
        case .unlimitedEnded: return "使い放題が終わったら"
        case .leftWifi: return "Wi-Fi から離れたら"
        case .joinedWifi: return "Wi-Fi につながったら"
        case .batteryBelow: return "電池が少なくなったら"
        case .unplugged: return "充電器を外したら"
        case .timeOfDay: return "決まった時刻"
        case .calendarEvent: return "予定の前"
        case .usedTodayAbove: return "今日たくさん使ったら"
        case .arrive: return "どこかに着いたら"
        case .leave: return "出かけたら(移動したら)"
        case .shortcut: return "ショートカット App から"
        case .once: return "予約(1回だけ)"
        }
    }

    static func triggerSymbol(_ k: FlowTriggerKind) -> String {
        switch k {
        case .manual: return "hand.tap.fill"
        case .anyCheck: return "arrow.triangle.2.circlepath"
        case .dataBelow: return "gauge.with.dots.needle.0percent"
        case .hoursLeftBelow: return "hourglass.bottomhalf.filled"
        case .unlimitedEnding: return "timer"
        case .unlimitedEnded: return "infinity.circle"
        case .leftWifi: return "wifi.slash"
        case .joinedWifi: return "wifi"
        case .batteryBelow: return "battery.25percent"
        case .unplugged: return "powerplug"
        case .timeOfDay: return "clock.fill"
        case .calendarEvent: return "calendar"
        case .usedTodayAbove: return "chart.bar.fill"
        case .arrive: return "mappin.and.ellipse"
        case .leave: return "figure.walk.departure"
        case .shortcut: return "square.2.layers.3d.top.filled"
        case .once: return "calendar.badge.clock"
        }
    }

    /// 選ぶ画面での並び(よく使う順)。
    static let triggerGroups: [(String, [FlowTriggerKind])] = [
        ("よく使う", [.manual, .calendarEvent, .timeOfDay, .dataBelow, .unlimitedEnding]),
        ("残量・使い放題", [.hoursLeftBelow, .unlimitedEnded, .usedTodayAbove, .anyCheck]),
        ("場所・つながり", [.leftWifi, .joinedWifi, .leave, .arrive]),
        ("電池", [.batteryBelow, .unplugged]),
        ("ほか", [.shortcut, .once]),
    ]

    static func trigger(_ t: FlowTrigger) -> String {
        switch t.kind {
        case .manual: return "ボタンを押したとき"
        case .anyCheck: return "自動チェックのたび"
        case .dataBelow: return "残量が \(FlowEngine.gbText(t.gb ?? 0.1)) を下回ったとき"
        case .hoursLeftBelow: return "このペースで あと\(FlowEngine.hoursText(t.hours ?? 3))を切ったとき"
        case .unlimitedEnding: return "使い放題の残りが\(t.minutes ?? 10)分を切ったとき"
        case .unlimitedEnded: return "使い放題が終わったとき"
        case .leftWifi: return "Wi-Fi から離れたとき"
        case .joinedWifi: return "Wi-Fi につながったとき"
        case .batteryBelow: return "電池が\(t.percent ?? 20)%以下になったとき"
        case .unplugged: return "充電器を外したとき"
        case .timeOfDay:
            let hm = String(format: "%d:%02d", t.hour ?? 7, t.minute ?? 0)
            return "\(weekdays(t.weekdays)) \(hm)"
        case .calendarEvent:
            var s = "予定の\(t.leadMin ?? 30)分前"
            if t.outingOnly == true { s += "(外出の予定)" }
            if let k = t.keyword, !k.isEmpty { s += "・「\(k)」を含む" }
            return s
        case .usedTodayAbove: return "今日 \(t.mb ?? 1000)MB 以上使ったとき"
        case .arrive: return "どこかに着いたとき"
        case .leave: return "出かけたとき(移動したとき)"
        case .shortcut: return "ショートカット「\(t.name ?? "")」から呼ばれたとき"
        case .once:
            guard let ms = t.atMs else { return "予約" }
            let d = Date(timeIntervalSince1970: Double(ms) / 1000)
            let c = DayPlanner.tokyo.dateComponents([.month, .day], from: d)
            return "\(c.month ?? 0)/\(c.day ?? 0) \(DayPlanner.hm(d)) に1回"
        }
    }

    static func weekdays(_ ws: [Int]?) -> String {
        guard let ws, !ws.isEmpty, ws.count < 7 else { return "毎日" }
        let s = Set(ws)
        if s == [1, 2, 3, 4, 5] { return "平日" }
        if s == [0, 6] { return "土日" }
        return ws.sorted().map { FlowEngine.weekdayName($0) }.joined(separator: "・")
    }

    // MARK: - 条件

    static func conditionTitle(_ k: FlowConditionKind) -> String {
        switch k {
        case .dataBelow: return "残量が少ない"
        case .dataAbove: return "残量がある"
        case .hoursLeftBelow: return "なくなりそう"
        case .unlimitedActive: return "使い放題中"
        case .unlimitedInactive: return "使い放題ではない"
        case .onWifi: return "Wi-Fi のとき"
        case .onCellular: return "モバイル通信のとき"
        case .batteryBelow: return "電池が少ない"
        case .charging: return "充電中"
        case .notCharging: return "充電していない"
        case .lowPower: return "低電力モード"
        case .timeBetween: return "時間帯"
        case .weekdays: return "曜日"
        case .hasCodes: return "コードを持っている"
        case .inOuting: return "外出の予定の最中"
        case .outingWithin: return "もうすぐ外出の予定"
        case .dayShort: return "今日の予定に残量が足りない"
        case .usedTodayAbove: return "今日たくさん使った"
        case .workday: return "平日(祝日を除く)"
        case .dayOff: return "休みの日(土日祝)"
        case .notHoliday: return "祝日は休む"
        case .dayHasOuting: return "外出の予定がある日"
        case .dayNoOuting: return "外出の予定がない日"
        }
    }

    static func conditionSymbol(_ k: FlowConditionKind) -> String {
        switch k {
        case .dataBelow, .dataAbove: return "gauge.with.dots.needle.33percent"
        case .hoursLeftBelow: return "hourglass"
        case .unlimitedActive, .unlimitedInactive: return "infinity"
        case .onWifi: return "wifi"
        case .onCellular: return "antenna.radiowaves.left.and.right"
        case .batteryBelow: return "battery.25percent"
        case .charging, .notCharging: return "bolt.batteryblock"
        case .lowPower: return "leaf"
        case .timeBetween: return "clock"
        case .weekdays: return "calendar.day.timeline.left"
        case .hasCodes: return "ticket"
        case .inOuting, .outingWithin: return "figure.walk"
        case .dayShort: return "calendar.badge.exclamationmark"
        case .usedTodayAbove: return "chart.bar"
        case .workday: return "briefcase"
        case .dayOff, .notHoliday: return "flag"
        case .dayHasOuting: return "figure.walk.departure"
        case .dayNoOuting: return "house"
        }
    }

    static let conditionGroups: [(String, [FlowConditionKind])] = [
        ("残量", [.dataBelow, .dataAbove, .hoursLeftBelow, .usedTodayAbove, .unlimitedActive, .unlimitedInactive]),
        ("予定", [.dayShort, .dayHasOuting, .dayNoOuting, .outingWithin, .inOuting]),
        ("つながり・電池", [.onCellular, .onWifi, .batteryBelow, .notCharging, .charging, .lowPower]),
        ("日・時間", [.workday, .dayOff, .notHoliday, .timeBetween, .weekdays]),
        ("コード", [.hasCodes]),
    ]

    static func condition(_ c: FlowCondition) -> String {
        switch c.kind {
        case .dataBelow: return "残量が \(FlowEngine.gbText(c.gb ?? 1)) 未満"
        case .dataAbove: return "残量が \(FlowEngine.gbText(c.gb ?? 1)) 以上"
        case .hoursLeftBelow: return "あと\(FlowEngine.hoursText(c.hours ?? 6))以内になくなりそう"
        case .unlimitedActive: return "使い放題中"
        case .unlimitedInactive: return "使い放題ではない"
        case .onWifi: return "Wi-Fi につながっている"
        case .onCellular: return "モバイル通信を使っている"
        case .batteryBelow: return "電池が\(c.percent ?? 20)%以下"
        case .charging: return "充電中"
        case .notCharging: return "充電していない"
        case .lowPower: return "低電力モード"
        case .timeBetween: return "\(c.from ?? 0)時〜\(c.to ?? 24)時"
        case .weekdays: return weekdays(c.weekdays)
        case .hasCodes: return (c.tag ?? "").isEmpty ? "未使用のコードがある" : "タグ「\(c.tag ?? "")」のコードがある"
        case .inOuting: return "外出の予定の最中"
        case .outingWithin: return "\(FlowEngine.hoursText(c.hours ?? 3))以内に外出の予定"
        case .dayShort: return "今日の予定に残量が足りない"
        case .usedTodayAbove: return "今日 \(c.mb ?? 1000)MB 以上使った"
        case .workday: return "平日(祝日を除く)"
        case .dayOff: return "土日・祝日"
        case .notHoliday: return "祝日でない日"
        case .dayHasOuting: return "その日に外出の予定がある"
        case .dayNoOuting: return "その日に外出の予定がない"
        }
    }

    // MARK: - アクション

    static func actionTitle(_ k: FlowActionKind) -> String {
        switch k {
        case .applyCode: return "コードを使う"
        case .buyUnlimited: return "使い放題を入れる"
        case .buyData: return "データを追加"
        case .notify: return "通知する"
        case .dayBrief: return "今日/明日のプランを通知"
        case .setPurchaseMode: return "購入のしかたを変える"
        case .setCodeMode: return "コードのしかたを変える"
        case .setFlowEnabled: return "オートメーションをオン/オフ"
        case .log: return "履歴にメモ"
        }
    }

    static func actionSymbol(_ k: FlowActionKind) -> String {
        switch k {
        case .applyCode: return "ticket.fill"
        case .buyUnlimited: return "infinity"
        case .buyData: return "plus.circle.fill"
        case .notify: return "bell.fill"
        case .dayBrief: return "calendar.badge.checkmark"
        case .setPurchaseMode: return "cart.fill"
        case .setCodeMode: return "ticket"
        case .setFlowEnabled: return "switch.2"
        case .log: return "note.text"
        }
    }

    static let actionGroups: [(String, [FlowActionKind])] = [
        ("povo", [.buyUnlimited, .applyCode, .buyData]),
        ("お知らせ", [.notify, .dayBrief, .log]),
        ("povoX の設定", [.setPurchaseMode, .setCodeMode, .setFlowEnabled]),
    ]

    static func action(_ a: FlowAction, flowName: (String) -> String? = { _ in nil }) -> String {
        switch a.kind {
        case .applyCode: return (a.tag ?? "").isEmpty ? "手持ちのコードを使う" : "コード(\(a.tag ?? ""))を使う"
        case .buyUnlimited:
            let h = a.hours ?? 24
            return h == 0 ? "予定に合わせた使い放題を入れる" : "\(DayPlanner.durationName(h))使い放題を入れる"
        case .buyData: return a.gb.map { "データ\(FlowEngine.gbText($0))を追加" } ?? "データを追加(一番小さいもの)"
        case .notify: return "通知「\(a.title ?? "")」"
        case .dayBrief:
            switch a.day ?? "auto" {
            case "today": return "今日のプランを通知"
            case "tomorrow": return "明日のプランを通知"
            default: return "プランを通知(夕方からは明日)"
            }
        case .setPurchaseMode: return "購入を「\(modeLabel(a.mode))」に"
        case .setCodeMode: return "コードを「\(modeLabel(a.mode))」に"
        case .setFlowEnabled:
            let name = a.flowID.flatMap(flowName) ?? "オートメーション"
            return "「\(name)」を\((a.on ?? true) ? "オン" : "オフ")に"
        case .log: return "メモ「\(a.body ?? "")」"
        }
    }

    static func modeLabel(_ m: String?) -> String {
        switch m {
        case "off": return "しない"
        case "auto": return "自動"
        default: return "通知で確認"
        }
    }

    /// 目覚まし時計の一覧に出す「いつ鳴るか」(繰り返し・祝日・どんな日・スヌーズ)。
    static func alarmRepeat(_ f: Flow) -> String {
        var parts: [String] = []
        if f.trigger.kind == .once, let ms = f.trigger.atMs {
            let d = Date(timeIntervalSince1970: Double(ms) / 1000)
            let c = DayPlanner.tokyo.dateComponents([.month, .day, .weekday], from: d)
            parts.append("\(c.month ?? 0)/\(c.day ?? 0)(\(FlowEngine.weekdayName((c.weekday ?? 1) - 1)))だけ")
        } else if f.conditions.contains(where: { $0.kind == .workday }) {
            parts.append("平日(祝日を除く)")
        } else if f.conditions.contains(where: { $0.kind == .dayOff }) {
            parts.append("土日・祝日")
        } else {
            parts.append(weekdays(f.trigger.weekdays))
            if f.conditions.contains(where: { $0.kind == .notHoliday }) { parts.append("祝日は休む") }
        }
        if f.conditions.contains(where: { $0.kind == .dayHasOuting }) { parts.append("外出の日だけ") }
        if f.conditions.contains(where: { $0.kind == .dayNoOuting }) { parts.append("家の日だけ") }
        if f.conditions.contains(where: { $0.kind == .dayShort }) { parts.append("足りない日だけ") }
        if let s = f.trigger.snoozeMin, s > 0 { parts.append("スヌーズ\(s)分") }
        return parts.joined(separator: "・")
    }

    /// 一覧に出す1行の要約(きっかけ → すること)。
    static func summary(_ f: Flow) -> String {
        let cond = f.conditions.isEmpty ? "" : "・" + f.conditions.map(condition).joined(separator: f.matchAll ? "・" : " か ")
        let acts = f.actions.map { action($0) }.joined(separator: "→")
        return "\(trigger(f.trigger))\(cond) → \(acts.isEmpty ? "(することがありません)" : acts)"
    }
}
