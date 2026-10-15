import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusBanners()
                    RemainingCard(snapshot: model.snapshot)
                    if let s = model.snapshot {
                        if let u = s.usage, !u.buckets.isEmpty {
                            BucketsCard(buckets: u.buckets, calls: u.calls, sms: u.sms)
                        }
                        ToppingsCard(snapshot: s)
                    }
                    AutoSummaryCard()
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("povoX")
            .refreshable { await model.refresh(force: true) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await model.refresh(force: true) }
                    } label: {
                        if model.busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(model.busy)
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MeterBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.groove)
                Capsule().fill(Theme.yellow)
                    .overlay(Capsule().stroke(Color.black.opacity(0.08)))
                    .frame(width: max(8, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 10)
    }
}

struct RemainingCard: View {
    let snapshot: Snapshot?

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("データ残量").font(.subheadline.weight(.semibold))
                Spacer()
                if snapshot?.unlimitedActive == true {
                    Text("使い放題中")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.yellow, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            if let s = snapshot, let kb = s.leftKb {
                Text(kb.kbText)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                let plan = s.usage?.buckets.compactMap { $0.planKb }.reduce(0, +) ?? 0
                if plan > 0 {
                    MeterBar(fraction: kb / plan)
                    Text("容量 \(plan.kbText) のうち").font(.caption).foregroundStyle(.secondary)
                }
                if let u = s.unlimited {
                    Text("\(u.name)\(u.expiry.map { "\n\($0)" } ?? "")").font(.caption)
                }
                Text("更新: \(s.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(s.cached == true ? "(前回の値)" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if snapshot != nil {
                Text("残量を読めませんでした(povo 側の形が変わった可能性)。").font(.callout)
            } else {
                Text("—").font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Text("下に引っ張るか右上のボタンで取得します").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BucketsCard: View {
    let buckets: [Bucket]
    let calls: Counter?
    let sms: Counter?

    var body: some View {
        Card("内訳") {
            ForEach(buckets) { b in
                HStack {
                    Text(b.label)
                    Spacer()
                    Text(b.leftKb.kbText).monospacedDigit()
                    if let p = b.planKb, p > 0 {
                        Text("/ \(p.kbText)").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .font(.callout)
            }
            if calls != nil || sms != nil {
                Divider()
                HStack {
                    if let c = calls { Text("通話 \(Int(c.used / 60))分\(Int(c.used.truncatingRemainder(dividingBy: 60)))秒") }
                    Spacer()
                    if let s = sms { Text("SMS \(Int(s.used))通") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ToppingsCard: View {
    let snapshot: Snapshot

    var body: some View {
        Card("ご利用中のトッピング") {
            if let list = snapshot.toppings {
                if list.isEmpty {
                    Text("なし").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.self) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.callout.weight(.medium))
                        if let r = t.remaining { Text("残量 \(r)").font(.caption) }
                        if let e = t.expiry { Text(e.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("読めませんでした\(snapshot.toppingsError.map { ": \($0)" } ?? "")。使い放題中かどうか分からないので、コードの自動適用は行いません。")
                    .font(.caption)
            }
        }
    }
}

struct AutoSummaryCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("自動化") {
            if let b = model.status?.budget {
                HStack {
                    VStack(alignment: .leading) {
                        Text("今月の自動購入").font(.caption).foregroundStyle(.secondary)
                        Text("\(b.autoSpentYen)円 / \(b.capYen)円").font(.callout.monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("未使用コード").font(.caption).foregroundStyle(.secondary)
                        Text("\(model.status?.codesPending ?? 0)件").font(.callout.monospacedDigit())
                    }
                }
                MeterBar(fraction: b.capYen > 0 ? Double(b.autoSpentYen) / Double(b.capYen) : 0)
            }
            if let last = Automation.lastRun {
                Text("前回の自動チェック: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let r = model.lastReport {
                Text(r).font(.caption)
            }
        }
    }
}
