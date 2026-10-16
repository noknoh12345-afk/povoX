import Foundation

/// 日本の祝日(国民の祝日に関する法律。2000〜2099年)。カレンダーの許可がなくても「祝日は休む」に使う。
/// 振替休日(日曜の祝日の次の平日)と国民の休日(祝日にはさまれた日)を含む。2019〜2021年の特例も入れている。
/// 春分・秋分は計算式(1980〜2099年に有効)による。官報で翌年分が決まるまでは予測であることに注意。
enum JapaneseHolidays {
    private static var cache: [Int: [String: String]] = [:]
    private static let lock = NSLock()

    /// その日の祝日名(祝日でなければ nil)。日付は日本時間で見る。
    static func name(_ date: Date) -> String? {
        let c = DayPlanner.tokyo.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return table(y)[key(m, d)]
    }

    static func isHoliday(_ date: Date) -> Bool { name(date) != nil }

    /// 土日・祝日(「休みの日」)。
    static func isDayOff(_ date: Date) -> Bool {
        let wd = DayPlanner.tokyo.component(.weekday, from: date)
        return wd == 1 || wd == 7 || isHoliday(date)
    }

    static func table(_ y: Int) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let t = cache[y] { return t }
        let t = build(y)
        cache[y] = t
        return t
    }

    private static func key(_ m: Int, _ d: Int) -> String { String(format: "%02d-%02d", m, d) }

    /// その月の第 n 月曜日。
    private static func nthMonday(_ y: Int, _ m: Int, _ n: Int) -> Int {
        let first = weekday(y, m, 1) // 0=日
        let offset = (8 - first) % 7 // 最初の月曜
        return 1 + offset + (n - 1) * 7
    }

    /// 0=日 … 6=土(ツェラーの公式)。
    static func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int {
        var yy = y, mm = m
        if mm < 3 { mm += 12; yy -= 1 }
        let k = yy % 100, j = yy / 100
        let h = (d + (13 * (mm + 1)) / 5 + k + k / 4 + j / 4 + 5 * j) % 7 // 0=土
        return (h + 6) % 7
    }

    private static func vernal(_ y: Int) -> Int {
        Int(20.8431 + 0.242194 * Double(y - 1980)) - (y - 1980) / 4
    }

    private static func autumnal(_ y: Int) -> Int {
        Int(23.2488 + 0.242194 * Double(y - 1980)) - (y - 1980) / 4
    }

    private static func build(_ y: Int) -> [String: String] {
        guard y >= 2000 && y <= 2099 else { return [:] }
        var h: [String: String] = [:]
        func add(_ m: Int, _ d: Int, _ n: String) { h[key(m, d)] = n }
        add(1, 1, "元日")
        add(1, nthMonday(y, 1, 2), "成人の日")
        add(2, 11, "建国記念の日")
        if y >= 2020 { add(2, 23, "天皇誕生日") } else if y <= 2018 { add(12, 23, "天皇誕生日") }
        add(3, vernal(y), "春分の日")
        add(4, 29, y >= 2007 ? "昭和の日" : "みどりの日")
        add(5, 3, "憲法記念日")
        if y >= 2007 { add(5, 4, "みどりの日") }
        add(5, 5, "こどもの日")
        switch y {
        case 2020: add(7, 23, "海の日"); add(7, 24, "スポーツの日"); add(8, 10, "山の日")
        case 2021: add(7, 22, "海の日"); add(7, 23, "スポーツの日"); add(8, 8, "山の日")
        default:
            add(7, y >= 2003 ? nthMonday(y, 7, 3) : 20, "海の日")
            if y >= 2016 { add(8, 11, "山の日") }
            add(10, nthMonday(y, 10, 2), y >= 2020 ? "スポーツの日" : "体育の日")
        }
        add(9, y >= 2003 ? nthMonday(y, 9, 3) : 15, "敬老の日")
        add(9, autumnal(y), "秋分の日")
        add(11, 3, "文化の日")
        add(11, 23, "勤労感謝の日")
        if y == 2019 {
            add(4, 30, "国民の休日"); add(5, 1, "天皇の即位の日"); add(5, 2, "国民の休日"); add(10, 22, "即位礼正殿の儀の行われる日")
        }
        // 国民の休日(祝日にはさまれた平日)
        let days = dayList(y)
        for (i, d) in days.enumerated() where i > 0 && i < days.count - 1 {
            if h[d.k] == nil, h[days[i - 1].k] != nil, h[days[i + 1].k] != nil, d.wd != 0 { h[d.k] = "国民の休日" }
        }
        // 振替休日(日曜の祝日の次の、祝日でない日)
        if y >= 2007 {
            for (i, d) in days.enumerated() where d.wd == 0 && h[d.k] != nil && !h[d.k]!.hasPrefix("振替") {
                var j = i + 1
                while j < days.count, h[days[j].k] != nil { j += 1 }
                if j < days.count { h[days[j].k] = "振替休日" }
            }
        }
        return h
    }

    private static func dayList(_ y: Int) -> [(k: String, wd: Int)] {
        var out: [(String, Int)] = []
        let lengths = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        for m in 1...12 {
            for d in 1...lengths[m - 1] { out.append((key(m, d), weekday(y, m, d))) }
        }
        return out.map { (k: $0.0, wd: $0.1) }
    }
}
