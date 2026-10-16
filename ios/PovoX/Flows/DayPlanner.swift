import Foundation

/// 予定(カレンダー)から、その日の外出と必要なデータ量を見積もり、何をいつしておくと楽かを出す。
///
/// 家では Wi-Fi なので「何もしない」が正解の日が多い。データが要るのは外にいる間だけなので、
/// 予定から「外にいる時間」を拾い、その時間に足りるか・足りなければ出かける前に何を入れるかを決める。
/// 見積もりは目安(予定の種類ごとの1時間あたりの量 × 長さ。移動の前後30分も足す)。
/// Foundation だけを使う(パソコン上でもテストできるように)。
enum DayPlanner {
    enum OutingKind: String {
        case travel, live, outdoor, social, shopping, work, study, medical, cinema, other

        var label: String {
            switch self {
            case .travel: return "移動・旅行"
            case .live: return "ライブ・観戦"
            case .outdoor: return "おでかけ"
            case .social: return "食事・集まり"
            case .shopping: return "買い物"
            case .work: return "仕事・打ち合わせ"
            case .study: return "学校・授業"
            case .medical: return "病院"
            case .cinema: return "映画・観劇"
            case .other: return "外出"
            }
        }

        var symbol: String {
            switch self {
            case .travel: return "tram.fill"
            case .live: return "music.mic"
            case .outdoor: return "figure.walk"
            case .social: return "fork.knife"
            case .shopping: return "bag.fill"
            case .work: return "briefcase.fill"
            case .study: return "book.fill"
            case .medical: return "cross.case.fill"
            case .cinema: return "film"
            case .other: return "mappin.and.ellipse"
            }
        }

        /// 「ふつう」の使い方での 1時間あたりの MB(地図・SNS・動画を少し)。
        var mbPerHour: Double {
            switch self {
            case .travel: return 300
            case .live: return 250
            case .outdoor: return 150
            case .social: return 100
            case .shopping: return 120
            case .work: return 50
            case .study: return 40
            case .medical: return 30
            case .cinema: return 15
            case .other: return 150
            }
        }
    }

    struct Outing: Equatable, Identifiable {
        var event: CalEvent
        var kind: OutingKind
        var start: Date
        var end: Date
        /// 見込みの使用量(移動ぶんを含む)。
        var estMB: Double
        var id: String { event.id + "@\(event.startMs)" }
    }

    enum Verdict: String {
        /// 外出の予定なし。
        case noOutings
        /// 使い放題が予定の終わりまで続く。
        case covered
        /// 残量で足りる。
        case enough
        /// ぎりぎり。
        case tight
        /// 足りない。
        case short
        /// 残量が分からない。
        case unknown
    }

    struct Suggestion: Equatable {
        /// 実際にすること(オートメーションのアクションとして実行する)。
        var action: FlowAction
        /// いつするとよいか(予定の少し前)。過ぎていれば今すぐ。
        var at: Date
        /// 短い名前(例: 24時間使い放題)。
        var what: String
        /// 1行の説明。
        var why: String
    }

    struct Plan: Equatable {
        /// "today" / "tomorrow"
        var day: String
        var dayLabel: String
        var date: Date
        var outings: [Outing]
        var needMB: Double
        var leftMB: Double?
        var verdict: Verdict
        var suggestion: Suggestion?
        var headline: String
        var detail: String

        var windowStart: Date? { outings.map(\.start).min() }
        var windowEnd: Date? { outings.map(\.end).max() }
    }

    static var tokyo: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        c.locale = Locale(identifier: "ja_JP")
        return c
    }()

    // MARK: - 予定の見分け

    private static let onlineWords = ["オンライン", "online", "zoom", "teams", "meet", "web会議", "ウェブ会議", "リモート", "在宅", "テレワーク", "配信を見る", "http"]
    private static let words: [(OutingKind, [String])] = [
        (.travel, ["旅行", "出張", "帰省", "新幹線", "飛行機", "空港", "フライト", "ドライブ", "観光", "遠征", "ツアー", "合宿", "移動", "trip", "travel", "flight"]),
        (.live, ["ライブ", "フェス", "コンサート", "観戦", "試合", "公演", "イベント", "遊園地", "テーマパーク", "ユニバ", "usj", "ディズニー", "万博", "live", "concert"]),
        (.cinema, ["映画", "観劇", "舞台", "ミュージカル", "美術館", "博物館", "cinema", "movie"]),
        (.outdoor, ["キャンプ", "登山", "ハイキング", "釣り", "海", "公園", "散歩", "花火", "お祭り", "祭り", "bbq", "ピクニック", "おでかけ", "お出かけ", "外出", "遊び"]),
        (.social, ["飲み会", "ランチ", "ディナー", "食事", "会食", "女子会", "デート", "誕生日会", "パーティ", "カフェ", "打ち上げ", "同窓会", "歓迎会", "送別会"]),
        (.shopping, ["買い物", "ショッピング", "セール", "ikea", "コストコ", "アウトレット"]),
        (.work, ["打ち合わせ", "会議", "面接", "商談", "訪問", "出社", "仕事", "シフト", "バイト", "研修", "説明会", "セミナー"]),
        (.study, ["授業", "講義", "学校", "大学", "塾", "テスト", "試験", "ゼミ", "実習", "職業訓練", "訓練校"]),
        (.medical, ["病院", "通院", "歯医者", "クリニック", "健診", "検診", "診察"]),
    ]

    static func isOnline(_ e: CalEvent) -> Bool {
        let text = (e.title + " " + (e.location ?? "")).lowercased()
        return onlineWords.contains { text.contains($0.lowercased()) }
    }

    static func kind(of e: CalEvent) -> OutingKind? {
        let text = (e.title + " " + (e.location ?? "")).lowercased()
        for (k, ws) in words where ws.contains(where: { text.contains($0.lowercased()) }) { return k }
        return nil
    }

    static func hasPlace(_ e: CalEvent) -> Bool {
        guard let l = e.location?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty else { return false }
        return !l.lowercased().hasPrefix("http")
    }

    /// 外出の予定か。オンラインは外出ではない。場所があるか、外出らしい言葉があれば外出。
    static func isOuting(_ e: CalEvent) -> Bool {
        if isOnline(e) { return false }
        if e.allDay { return kind(of: e) == .travel || kind(of: e) == .live || kind(of: e) == .outdoor }
        return hasPlace(e) || kind(of: e) != nil
    }

    static func outing(_ e: CalEvent, intensity: Double, on day: Date) -> Outing? {
        guard isOuting(e) else { return nil }
        let k = kind(of: e) ?? .other
        var start = e.start
        var end = e.end
        if e.allDay {
            // 終日の予定(旅行など)は、その日の 8時〜22時 を外にいる時間とみなす
            let d0 = tokyo.startOfDay(for: day)
            start = max(start, d0.addingTimeInterval(8 * 3600))
            end = min(end, d0.addingTimeInterval(22 * 3600))
        }
        guard end > start else { return nil }
        let hours = end.timeIntervalSince(start) / 3600
        // 移動: 場所のある予定は前後30分ずつ(1時間あたり 200MB)
        let commuteH = (hasPlace(e) || k == .travel) && !e.allDay ? 1.0 : 0
        let mb = (hours * k.mbPerHour + commuteH * 200) * intensity
        let pad: TimeInterval = commuteH > 0 ? 30 * 60 : 0
        return Outing(event: e, kind: k, start: start.addingTimeInterval(-pad), end: end.addingTimeInterval(pad), estMB: mb)
    }

    // MARK: - プラン

    /// その日のプラン。`day` は "today" か "tomorrow"。
    static func plan(day: String, facts: FlowFacts) -> Plan {
        let now = facts.now
        let base = tokyo.startOfDay(for: now)
        let dayStart = day == "tomorrow" ? tokyo.date(byAdding: .day, value: 1, to: base) ?? base.addingTimeInterval(86400) : base
        let dayEnd = tokyo.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let label = day == "tomorrow" ? "明日" : "今日"

        // その日にかかる予定(今日は、まだ終わっていないものだけ)
        var outings = facts.events
            .filter { $0.end > dayStart && $0.start < dayEnd }
            .compactMap { outing($0, intensity: facts.intensity, on: dayStart) }
            .filter { day == "tomorrow" || $0.end > now }
            .sorted { $0.start < $1.start }
        if day == "today" {
            // 進行中の予定は残りの時間ぶんだけ
            outings = outings.map { o in
                guard o.start < now else { return o }
                var c = o
                let total = o.end.timeIntervalSince(o.start)
                let left = o.end.timeIntervalSince(now)
                c.estMB = total > 0 ? o.estMB * left / total : 0
                c.start = now
                return c
            }
        }
        let need = outings.reduce(0) { $0 + $1.estMB }
        // 明日の朝には今日のぶんが減っているが、ここでは今の残量で見る(控えめに言う)
        let left = facts.leftMB

        var plan = Plan(day: day, dayLabel: label, date: dayStart, outings: outings, needMB: need, leftMB: left,
                        verdict: .noOutings, suggestion: nil, headline: "", detail: "")

        guard let first = outings.first, let wStart = plan.windowStart, let wEnd = plan.windowEnd else {
            plan.verdict = .noOutings
            plan.headline = facts.calendarAuthorized ? "\(label)は外出の予定がありません" : "カレンダーを許可すると、予定から準備できます"
            plan.detail = facts.calendarAuthorized ? "Wi-Fi で過ごす日なら、何もしなくて大丈夫です。" : "外出の予定に合わせて、出かける前に使い放題などを用意します。"
            return plan
        }
        let names = outings.prefix(2).map { $0.event.title }.joined(separator: "・") + (outings.count > 2 ? " ほか\(outings.count - 2)件" : "")
        let span = "\(hm(wStart))〜\(hm(wEnd))"

        // 使い放題が予定の終わりまで続く
        if facts.unlimitedActive == true, let h = facts.unlimitedHoursLeft, now.addingTimeInterval(h * 3600) >= wEnd {
            plan.verdict = .covered
            plan.headline = "使い放題が\(label)の予定の終わりまで続きます"
            plan.detail = "\(names)(\(span))。このままで大丈夫です。"
            return plan
        }
        guard let left else {
            plan.verdict = .unknown
            plan.headline = "\(label)は \(span) に外出(約\(mbText(need)))"
            plan.detail = "残量が分からないので、出かける前に一度更新してください。"
            return plan
        }
        if left >= need * 1.3 + 100 {
            plan.verdict = .enough
            plan.headline = "残り \(mbText(left)) で足りそうです"
            plan.detail = "\(names)(\(span))で 約\(mbText(need)) 使う見込み。何もしなくて大丈夫です。"
            return plan
        }
        plan.verdict = left >= need ? .tight : .short
        plan.headline = plan.verdict == .tight
            ? "\(span) の外出で ぎりぎりです(約\(mbText(need)) / 残り\(mbText(left)))"
            : "\(span) の外出で 約\(mbText(need)) 使いそう。残り \(mbText(left)) では足りません"
        let s = suggestion(window: (wStart, wEnd), first: first, need: need, left: left, facts: facts)
        plan.suggestion = s
        plan.detail = "\(names)。\(s.why)"
        return plan
    }

    /// 何をいつ入れるか。手間が少なく、外にいる間ずっと気にしなくていいものを選ぶ。
    static func suggestion(window: (Date, Date), first: Outing, need: Double, left: Double, facts: FlowFacts) -> Suggestion {
        let now = facts.now
        let at = max(now, window.0.addingTimeInterval(-15 * 60))
        let when = at <= now.addingTimeInterval(60) ? "今すぐ" : "\(hm(at)) に"
        let hours = window.1.timeIntervalSince(max(window.0, now)) / 3600
        // 手持ちのコードがあり、足りない量が少ないなら、まずコード
        if !facts.codeTags.isEmpty && need - left <= 1024 {
            return Suggestion(action: .code(), at: at, what: "手持ちのコード",
                              why: "出かける前(\(when.replacingOccurrences(of: " に", with: "")))に手持ちのコードを入れておくと足ります。")
        }
        // 使い放題: 外にいる時間をまるごと覆える一番短いもの
        let products = (facts.products ?? []).filter { $0.unlimited && !$0.requires3ds && $0.hours != nil }
        let lengths = Array(Set(products.compactMap { $0.hours.map { Int($0.rounded()) } })).sorted()
        let fallback = [1, 24]
        let options = lengths.isEmpty ? fallback : lengths
        let pick = options.first { Double($0) >= hours } ?? options.last ?? 24
        let what = "\(durationName(pick))使い放題"
        let cover = Double(pick) >= hours ? "外にいる間ずっと残量を気にしなくて済みます。" : "長い外出なので、切れたらもう一度入れてください。"
        return Suggestion(action: .unlimited(pick), at: at, what: what,
                          why: "\(when)\(what)を入れておくと、\(cover)")
    }

    /// オートメーションの「プランを通知」の文面。
    static func brief(day: String, facts: FlowFacts) -> (title: String, body: String)? {
        let d: String
        if day == "auto" {
            d = tokyo.component(.hour, from: facts.now) >= 18 ? "tomorrow" : "today"
        } else {
            d = day
        }
        guard facts.calendarAuthorized else { return nil }
        let p = plan(day: d, facts: facts)
        let title = "povoX: \(p.dayLabel)のプラン"
        var body = p.headline
        if let s = p.suggestion {
            body += "\n→ \(s.why)"
        } else if p.verdict != .noOutings {
            body += "\n" + p.detail
        }
        return (title, body)
    }

    // MARK: - 表示

    static func hm(_ d: Date) -> String {
        let c = tokyo.dateComponents([.hour, .minute], from: d)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func mbText(_ mb: Double) -> String {
        if mb >= 1000 { return String(format: "%.1fGB", mb / 1024) }
        return "\(Int((mb / 10).rounded() * 10))MB"
    }

    static func durationName(_ hours: Int) -> String {
        if hours >= 24 && hours % 24 == 0 { return hours == 24 ? "24時間" : "\(hours / 24)日間" }
        return "\(hours)時間"
    }
}
