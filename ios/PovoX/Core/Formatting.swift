import Foundation

/// 表示の書き方。
enum Fmt {
    static let kbPerGB = 1_048_576.0

    /// KB(1024基準)→ "17.29GB" / "256MB"
    static func data(kb: Double) -> String {
        let p = dataParts(kb: kb)
        return p.value + p.unit
    }

    /// 大きな数字と単位を分けて返す。
    static func dataParts(kb: Double) -> (value: String, unit: String) {
        let gb = kb / kbPerGB
        if gb >= 10 { return (String(format: "%.1f", gb), "GB") }
        if gb >= 1 { return (String(format: "%.2f", gb), "GB") }
        return (String(format: "%.0f", max(0, kb / 1024)), "MB")
    }

    /// 時間 → "約2日3時間" / "約5時間" / "約40分"
    static func duration(hours: Double) -> String {
        if hours.isNaN || hours.isInfinite { return "—" }
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 { return "約\(max(1, minutes))分" }
        let h = minutes / 60
        if h < 24 {
            let m = minutes % 60
            return m >= 10 && h < 6 ? "約\(h)時間\(m)分" : "約\(h)時間"
        }
        let d = h / 24
        let rh = h % 24
        return rh == 0 ? "約\(d)日" : "約\(d)日\(rh)時間"
    }

    static func yen(_ v: UInt32) -> String {
        "\(grouped(Int(v)))円"
    }

    static func grouped(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static let jp = Locale(identifier: "ja_JP")
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = jp
        f.timeZone = tokyo
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let timeF = formatter("HH:mm")
    private static let dayTimeF = formatter("MMMdHH:mm")
    private static let dayF = formatter("MMMdEEE")

    /// "13:05"(今日)/ "10月14日 13:05"
    static func when(ms: Int64, now: Date = Date()) -> String {
        let d = date(ms: ms)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        if cal.isDate(d, inSameDayAs: now) { return timeF.string(from: d) }
        return dayTimeF.string(from: d)
    }

    static func day(ms: Int64) -> String {
        dayF.string(from: date(ms: ms))
    }

    /// "3分前" など
    static func ago(ms: Int64, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date(ms: ms))
        if s < 60 { return "たった今" }
        if s < 3600 { return "\(Int(s / 60))分前" }
        if s < 86_400 { return "\(Int(s / 3600))時間前" }
        return "\(Int(s / 86_400))日前"
    }
}
