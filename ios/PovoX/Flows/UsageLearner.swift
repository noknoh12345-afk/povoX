import Foundation

// 学習: 端末の生データ(povo の残量の記録・通信量カウンタ・過去の予定・利用者の直し)から、
// その人の使い方を覚え、「今日のプラン」の見積もりを推測の数字から置き換える。
//
// - 使用量の物差し: 通信量カウンタ(モバイル通信。使い放題中も測れる)を、povo の残量の減りに合わせて換算したもの。
//   カウンタが無い区間は povo の残量の減り(使い放題でないときだけ)。
// - 予定の種類ごとの 1時間あたりの量: 過去の外出の予定の時間(前後の移動を含む)に使った量から。
//   件数が少ないうちは最初の目安(DayPlanner の値)に寄せる(少ない例に振り回されない)。
// - いつもの1日: 平日/休日 × 時間ごとの使用量(予定に無い外出の目安)。
// - 正しさ: 古い 2/3 で覚えて新しい 1/3 で確かめる(覚えるのに使っていない予定での誤差と、90%の見積もりを超えた割合)。
// 端末の外には送らない。Foundation だけを使う(パソコン上でも検査できる)。

/// 予定の種類ごとに覚えた量。
struct KindRate: Codable, Equatable {
    /// 覚えるのに使った予定の数と、その合計時間。
    var events: Int
    var hours: Double
    /// 1時間あたりの量(MB): 中央と 90%。最初の目安と混ぜたあとの値。
    var mbPerHourP50: Double
    var mbPerHourP90: Double
}

/// 学習の正しさ(覚えるのに使っていない予定で測る)。
struct LearnAccuracy: Codable, Equatable {
    var testEvents: Int
    /// 最初の目安のままの誤差(MB)と、学習後の誤差。
    var priorMAE: Double
    var learnedMAE: Double
    /// 実際の量が 90% の見積もりを超えた割合(0.1 前後が正しい)。
    var priorExceed: Double
    var learnedExceed: Double
    /// ピンボール損失(90%)。小さいほどよい。
    var priorPinball: Double
    var learnedPinball: Double
}

struct LearnedModel: Codable, Equatable {
    var updatedMs: Int64
    /// 学習に使えたデータの日数。
    var days: Double
    var kinds: [String: KindRate]
    /// 平日/休日 × 0〜23時の、1時間あたりのモバイル通信量(MB)の中央と 90%。
    var weekdayP50: [Double]
    var weekdayP90: [Double]
    var dayOffP50: [Double]
    var dayOffP90: [Double]
    /// povo の残量の減り ÷ 通信量カウンタ(わかれば)。
    var povoPerCell: Double?
    /// 利用者の直し: 予定の名前(数字・空白を除く)→ 外出か。
    var overrides: [String: Bool]
    var accuracy: LearnAccuracy?

    static let empty = LearnedModel(updatedMs: 0, days: 0, kinds: [:], weekdayP50: [], weekdayP90: [], dayOffP50: [], dayOffP90: [],
                                    povoPerCell: nil, overrides: [:], accuracy: nil)

    /// その種類の 1時間あたりの見積もり(90%)。覚えていなければ nil。
    func rate(_ kind: DayPlanner.OutingKind) -> Double? {
        guard let k = kinds[kind.rawValue], k.events >= 1 else { return nil }
        return k.mbPerHourP90
    }

    /// 予定の名前の直しの鍵(数字・空白・記号を除いて小文字)。「第3回 ゼミ」と「第4回 ゼミ」を同じに扱う。
    static func key(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
    }

    func override(for e: CalEvent) -> Bool? { overrides[LearnedModel.key(e.title)] }
}

enum UsageLearner {
    struct Input {
        /// povo の残量の記録(時刻ミリ秒・KB・使い放題中か)。
        var samples: [(t: Int64, leftKb: Double, unlimited: Bool)]
        /// 通信量カウンタ(時刻ミリ秒・読み)。
        var net: [(t: Int64, s: NetSample)]
        /// 過去の予定。
        var events: [CalEvent]
        var overrides: [String: Bool]
        var now: Date
    }

    /// 最初の目安と混ぜる重み(何件ぶんの予定とみなすか)。
    static let priorWeight = 2.0
    /// 移動の前後(分)。
    static let padMin = 30.0

    // MARK: - 使用量の物差し

    /// 時刻 → 累計のモバイル通信量(MB)。再起動で区切る。
    struct CellCurve {
        var segments: [[(t: Int64, mb: Double)]]

        init(_ net: [(t: Int64, s: NetSample)]) {
            var segs: [[(t: Int64, mb: Double)]] = []
            var cur: [(t: Int64, mb: Double)] = []
            var lastBoot: Int64?
            var total = 0.0
            var prev: NetSample?
            for (t, s) in net.sorted(by: { $0.t < $1.t }) {
                if let b = lastBoot, abs(b - s.bootMs) > 5_000 {
                    if cur.count > 1 { segs.append(cur) }
                    cur = []
                    prev = nil
                    total = 0
                }
                if let p = prev {
                    total += Double(WakeStats.delta(p.cellIn, s.cellIn) + WakeStats.delta(p.cellOut, s.cellOut)) / 1_048_576
                }
                cur.append((t, total))
                prev = s
                lastBoot = s.bootMs
            }
            if cur.count > 1 { segs.append(cur) }
            segments = segs
        }

        /// a〜b のモバイル通信量(MB)。区間がまるごと記録の中にあるときだけ(間は一様に使ったとみなす)。
        func between(_ a: Int64, _ b: Int64) -> Double? {
            for seg in segments {
                guard let first = seg.first, let last = seg.last, first.t <= a, b <= last.t else { continue }
                return value(seg, b) - value(seg, a)
            }
            return nil
        }

        private func value(_ seg: [(t: Int64, mb: Double)], _ t: Int64) -> Double {
            guard let i = seg.firstIndex(where: { $0.t >= t }) else { return seg.last?.mb ?? 0 }
            if i == 0 { return seg[0].mb }
            let p = seg[i - 1], q = seg[i]
            let f = q.t == p.t ? 1 : Double(t - p.t) / Double(q.t - p.t)
            return p.mb + (q.mb - p.mb) * f
        }
    }

    /// povo の残量の減りで見た a〜b の使用量(MB)。使い放題をまたぐ・増えた(購入)区間は数えない。
    static func povoBetween(_ samples: [(t: Int64, leftKb: Double, unlimited: Bool)], _ a: Int64, _ b: Int64) -> Double? {
        guard let i0 = samples.lastIndex(where: { $0.t <= a }), let i1 = samples.firstIndex(where: { $0.t >= b }), i0 < i1 else { return nil }
        let span = samples[i0...i1]
        if span.contains(where: { $0.unlimited }) { return nil }
        var used = 0.0
        for (p, q) in zip(span, span.dropFirst()) {
            let d = p.leftKb - q.leftKb
            if d < -1024 { return nil } // 増えた(購入・コード)
            used += max(0, d)
        }
        // 区間の外側の分を時間で按分して除く
        let whole = Double(samples[i1].t - samples[i0].t)
        guard whole > 0 else { return nil }
        return used / 1024 * Double(b - a) / whole
    }

    /// 1つの物差し: カウンタ(povo に換算)を優先し、無ければ povo の減り。
    static func usage(_ a: Int64, _ b: Int64, curve: CellCurve, samples: [(t: Int64, leftKb: Double, unlimited: Bool)], ratio: Double?) -> Double? {
        if let c = curve.between(a, b) { return c * (ratio ?? 1) }
        return povoBetween(samples, a, b)
    }

    /// povo の減り ÷ カウンタ(使い放題でない区間で、両方わかるところ)。
    static func povoPerCell(curve: CellCurve, samples: [(t: Int64, leftKb: Double, unlimited: Bool)]) -> Double? {
        var povo = 0.0, cell = 0.0
        for (p, q) in zip(samples, samples.dropFirst()) where !p.unlimited && !q.unlimited && q.t - p.t <= 6 * 3_600_000 {
            let d = p.leftKb - q.leftKb
            guard d >= 0, let c = curve.between(p.t, q.t) else { continue }
            povo += d / 1024
            cell += c
        }
        guard cell >= 50, povo > 0 else { return nil }
        return max(0.5, min(2.0, povo / cell))
    }

    // MARK: - 学習

    static func learn(_ input: Input) -> LearnedModel {
        let samples = input.samples.sorted { $0.t < $1.t }
        let curve = CellCurve(input.net)
        let ratio = povoPerCell(curve: curve, samples: samples)
        let nowMs = Int64(input.now.timeIntervalSince1970 * 1000)
        var model = LearnedModel.empty
        model.updatedMs = nowMs
        model.overrides = input.overrides
        model.povoPerCell = ratio
        let firstT = min(samples.first?.t ?? nowMs, curve.segments.first?.first?.t ?? nowMs)
        model.days = Double(nowMs - firstT) / 86_400_000

        // 過去の外出の予定ごとの量
        let observations = observe(input.events, overrides: input.overrides, now: input.now) { a, b in
            usage(a, b, curve: curve, samples: samples, ratio: ratio)
        }
        model.kinds = rates(observations)

        // 正しさ: 古い 2/3 で覚え、新しい 1/3 で確かめる
        let sorted = observations.sorted { $0.start < $1.start }
        if sorted.count >= 6 {
            let cut = sorted.count * 2 / 3
            let train = rates(Array(sorted[..<cut]))
            model.accuracy = evaluate(Array(sorted[cut...]), learned: train)
        }

        // いつもの1日(時間ごと)
        var wd: [[Double]] = Array(repeating: [], count: 24), off: [[Double]] = Array(repeating: [], count: 24)
        var h = (firstT / 3_600_000 + 1) * 3_600_000
        while h + 3_600_000 <= nowMs {
            if let u = usage(h, h + 3_600_000, curve: curve, samples: samples, ratio: ratio) {
                let d = Date(timeIntervalSince1970: Double(h) / 1000)
                let hour = DayPlanner.tokyo.component(.hour, from: d)
                if JapaneseHolidays.isDayOff(d) { off[hour].append(u) } else { wd[hour].append(u) }
            }
            h += 3_600_000
        }
        func p(_ xs: [[Double]], _ q: Double) -> [Double] { xs.map { WakeStats.percentile($0, q) ?? 0 } }
        if wd.contains(where: { !$0.isEmpty }) { model.weekdayP50 = p(wd, 0.5); model.weekdayP90 = p(wd, 0.9) }
        if off.contains(where: { !$0.isEmpty }) { model.dayOffP50 = p(off, 0.5); model.dayOffP90 = p(off, 0.9) }
        return model
    }

    struct Observation {
        var kind: DayPlanner.OutingKind
        var start: Date
        var hours: Double
        var usedMB: Double
        var title: String
    }

    /// 過去の外出の予定と、その時間(前後の移動を含む)に実際に使った量。
    static func observe(_ events: [CalEvent], overrides: [String: Bool], now: Date, usage: (Int64, Int64) -> Double?) -> [Observation] {
        events.compactMap { e in
            guard e.end <= now, !e.allDay, DayPlanner.isOuting(e, overrides: overrides) else { return nil }
            let pad = DayPlanner.hasPlace(e) || DayPlanner.kind(of: e) == .travel ? padMin * 60 : 0
            let a = e.start.addingTimeInterval(-pad), b = e.end.addingTimeInterval(pad)
            let hours = b.timeIntervalSince(a) / 3600
            guard hours >= 0.25, hours <= 16,
                  let u = usage(Int64(a.timeIntervalSince1970 * 1000), Int64(b.timeIntervalSince1970 * 1000)) else { return nil }
            return Observation(kind: DayPlanner.kind(of: e) ?? .other, start: e.start, hours: hours, usedMB: u, title: e.title)
        }
    }

    /// 種類ごとの 1時間あたりの量(最初の目安と混ぜる)。
    static func rates(_ obs: [Observation]) -> [String: KindRate] {
        var out: [String: KindRate] = [:]
        let groups = Dictionary(grouping: obs, by: { $0.kind })
        for (kind, list) in groups {
            let r = list.map { $0.usedMB / $0.hours }
            let n = Double(r.count)
            let prior = kind.mbPerHour
            let p50 = WakeStats.percentile(r, 0.5) ?? prior
            let p90 = WakeStats.percentile(r, 0.9) ?? prior
            let w = priorWeight
            out[kind.rawValue] = KindRate(events: r.count, hours: list.reduce(0) { $0 + $1.hours },
                                          mbPerHourP50: (prior * 0.6 * w + p50 * n) / (w + n),
                                          mbPerHourP90: (prior * w + p90 * n) / (w + n))
        }
        return out
    }

    /// 覚えるのに使っていない予定で、最初の目安と学習後を比べる。
    static func evaluate(_ test: [Observation], learned: [String: KindRate]) -> LearnAccuracy {
        func pinball(_ y: Double, _ q: Double) -> Double { y >= q ? 0.9 * (y - q) : 0.1 * (q - y) }
        var pe = 0.0, le = 0.0, px = 0, lx = 0, pp = 0.0, lp = 0.0
        for o in test {
            let prior = o.kind.mbPerHour * o.hours
            let mine = (learned[o.kind.rawValue]?.mbPerHourP90 ?? o.kind.mbPerHour) * o.hours
            pe += abs(o.usedMB - prior)
            le += abs(o.usedMB - mine)
            if o.usedMB > prior { px += 1 }
            if o.usedMB > mine { lx += 1 }
            pp += pinball(o.usedMB, prior)
            lp += pinball(o.usedMB, mine)
        }
        let n = Double(max(1, test.count))
        return LearnAccuracy(testEvents: test.count, priorMAE: pe / n, learnedMAE: le / n,
                             priorExceed: Double(px) / n, learnedExceed: Double(lx) / n,
                             priorPinball: pp / n, learnedPinball: lp / n)
    }

    /// 画面に出す文。
    static func lines(_ m: LearnedModel) -> [String] {
        var out: [String] = []
        out.append(String(format: "学習に使えたデータ: 約%.0f日", m.days))
        if let r = m.povoPerCell { out.append(String(format: "povo の数え方 ÷ 端末のカウンタ = %.2f", r)) }
        let kinds = m.kinds.sorted { $0.value.events > $1.value.events }
        if kinds.isEmpty {
            out.append("外出の予定ごとの量: まだ覚えていません(通信量カウンタの記録と、過去の外出の予定が要ります)")
        }
        for (k, r) in kinds {
            let label = DayPlanner.OutingKind(rawValue: k)?.label ?? k
            let prior = DayPlanner.OutingKind(rawValue: k)?.mbPerHour ?? 0
            out.append("\(label): \(r.events)件・\(String(format: "%.0f", r.hours))時間 → 1時間 \(Int(r.mbPerHourP90))MB(最初の目安 \(Int(prior))MB)")
        }
        if let a = m.accuracy {
            out.append("確かめ(覚えるのに使っていない \(a.testEvents)件): 誤差 \(Int(a.priorMAE))MB → \(Int(a.learnedMAE))MB・見積もりを超えた割合 \(Int(a.priorExceed * 100))% → \(Int(a.learnedExceed * 100))%")
        } else {
            out.append("確かめ: 外出の予定が6件以上たまると、覚えていない予定で誤差を測ります")
        }
        if !m.overrides.isEmpty { out.append("直した予定: \(m.overrides.count)件") }
        return out
    }
}

/// 学習の保存(UserDefaults に JSON)。
final class LearningStore {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let modelKey = "learn.model.v1"
    private static let overridesKey = "learn.overrides.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func model() -> LearnedModel? {
        lock.lock(); defer { lock.unlock() }
        guard let d = defaults.data(forKey: LearningStore.modelKey) else { return nil }
        var m = try? JSONDecoder().decode(LearnedModel.self, from: d)
        m?.overrides = overridesUnlocked()
        return m
    }

    func save(_ m: LearnedModel) {
        lock.lock(); defer { lock.unlock() }
        if let d = try? JSONEncoder().encode(m) { defaults.set(d, forKey: LearningStore.modelKey) }
    }

    func overrides() -> [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        return overridesUnlocked()
    }

    private func overridesUnlocked() -> [String: Bool] {
        (defaults.dictionary(forKey: LearningStore.overridesKey) as? [String: Bool]) ?? [:]
    }

    /// 予定の直し(nil で元に戻す)。
    func setOverride(_ title: String, outing: Bool?) {
        lock.lock(); defer { lock.unlock() }
        var o = overridesUnlocked()
        let k = LearnedModel.key(title)
        guard !k.isEmpty else { return }
        o[k] = outing
        defaults.set(o, forKey: LearningStore.overridesKey)
    }
}
