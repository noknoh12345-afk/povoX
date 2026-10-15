import Charts
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showShop = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusBanners()
                    HeroCard()
                    ForEach(store.pending) { p in
                        PendingCard(pending: p)
                    }
                    UsageChartCard(history: store.history, insights: store.insights, snapshot: store.snapshot)
                    QuickActions(showShop: $showShop)
                    if let run = store.runs.first {
                        LastRunCard(run: run)
                    }
                    if let s = store.snapshot {
                        ToppingsCard(snapshot: s)
                        BreakdownCard(snapshot: s)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("povoX")
            .refreshable { await store.refresh(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.mock { Chip(text: "モック", systemImage: "theatermasks", tint: .purple) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh(force: true) }
                    } label: {
                        if store.isBusy("refresh") { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityIdentifier("home.refresh")
                }
            }
            .navigationDestination(isPresented: $showShop) { ShopView() }
        }
    }
}

/// 残量の輪と、予測・状態。
struct HeroCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let snap = store.snapshot
        Card {
            HStack(alignment: .center, spacing: 18) {
                RemainingRing(snapshot: snap)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    if snap?.unlimited.active == true {
                        Chip(text: "使い放題中", systemImage: "infinity", filled: true)
                        if let u = snap?.unlimited.untilMs {
                            infoRow("終了", Fmt.when(ms: u))
                            infoRow("残り", Fmt.duration(hours: max(0, Double(u) / 1000 - Date().timeIntervalSince1970) / 3600))
                        }
                    } else if let h = store.insights?.hoursLeft {
                        infoRow("このペースで", Fmt.duration(hours: h))
                        if let r = store.insights?.kbPerHour { infoRow("1時間あたり", Fmt.data(kb: r)) }
                    } else if store.insights?.kbPerHour == 0 {
                        infoRow("最近は", "減っていません")
                    } else {
                        infoRow("予測", "記録が増えると出ます")
                    }
                    if let t = store.insights?.usedTodayKb, t > 0 {
                        infoRow("今日", Fmt.data(kb: t))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 6) {
                if let st = store.status {
                    Chip(text: "購入: \(st.settings.purchaseMode.label)", systemImage: "cart", tint: st.settings.purchaseMode == .auto ? Theme.warn : .secondary)
                    Chip(text: "コード: \(st.settings.codeMode.label)", systemImage: "ticket", tint: st.settings.codeMode == .auto ? Theme.warn : .secondary)
                }
                Spacer(minLength: 0)
            }
            if let s = snap {
                Text("更新 \(Fmt.ago(ms: s.fetchedMs))\(nextCheckText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("home.hero")
    }

    private var nextCheckText: String {
        guard let next = BackgroundScheduler.nextScheduled, next > Date() else { return "" }
        return " ・ 次の自動チェック \(Fmt.when(ms: Int64(next.timeIntervalSince1970 * 1000)))ごろ"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

struct RemainingRing: View {
    let snapshot: Snapshot?

    private var fraction: Double {
        guard let s = snapshot, let left = s.leftKb else { return 0 }
        if s.unlimited.active == true { return 1 }
        let plan = max(s.planKb ?? 0, left, 1)
        return left / plan
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.groove, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * max(0.02, fraction))
                .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.6), value: fraction)
            VStack(spacing: 0) {
                if snapshot?.unlimited.active == true {
                    Image(systemName: "infinity").font(.system(size: 38, weight: .bold))
                    Text("使い放題").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else if let kb = snapshot?.leftKb {
                    let p = Fmt.dataParts(kb: kb)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(p.value).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.5).lineLimit(1)
                        Text(p.unit).font(.headline.weight(.bold))
                    }
                    Text("残り").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    Text("—").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    Text(snapshot == nil ? "未取得" : "読めません").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.ring")
    }
}

/// 3日分の残量のグラフ。
struct UsageChartCard: View {
    let history: [UsageSample]
    let insights: UsageInsights?
    let snapshot: Snapshot?

    private struct Point: Identifiable {
        let id: Int64
        let date: Date
        let gb: Double
    }

    private var points: [Point] {
        history.map { Point(id: $0.tMs, date: Fmt.date(ms: $0.tMs), gb: $0.leftKb / Fmt.kbPerGB) }
    }

    /// 予測線(今から 0 になるまで、最大24時間先まで)。
    private var forecast: [Point] {
        guard let last = history.last, !last.unlimited, let h = insights?.hoursLeft, h > 0, let rate = insights?.kbPerHour, rate > 0 else { return [] }
        let start = Fmt.date(ms: last.tMs)
        let hours = min(h, 24)
        let end = start.addingTimeInterval(hours * 3600)
        let endGB = max(0, (last.leftKb - rate * hours) / Fmt.kbPerGB)
        return [Point(id: 0, date: start, gb: last.leftKb / Fmt.kbPerGB), Point(id: 1, date: end, gb: endGB)]
    }

    var body: some View {
        Card("残量の推移(3日)", systemImage: "chart.xyaxis.line") {
            if points.count < 2 {
                Text("自動チェックのたびに記録します。しばらくすると、ここにグラフが出ます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                Chart {
                    ForEach(points) { p in
                        AreaMark(x: .value("時刻", p.date), y: .value("GB", p.gb))
                            .foregroundStyle(LinearGradient(colors: [Theme.yellow.opacity(0.45), Theme.yellow.opacity(0.0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("時刻", p.date), y: .value("GB", p.gb))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(forecast) { p in
                        LineMark(x: .value("時刻", p.date), y: .value("GB", p.gb), series: .value("系列", "予測"))
                            .foregroundStyle(Theme.warn)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: d < 1 ? "%.1f" : "%.0f", d)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 12)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().locale(Locale(identifier: "ja_JP")))
                    }
                }
                .frame(height: 170)
                if !forecast.isEmpty {
                    Label("点線: 今のペースが続いたとき", systemImage: "line.diagonal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("home.chart")
    }
}

struct QuickActions: View {
    @EnvironmentObject var store: AppStore
    @Binding var showShop: Bool

    var body: some View {
        HStack(spacing: 10) {
            action("今すぐチェック", "bolt.fill", id: "home.runNow", busy: store.isBusy("run")) {
                Task { _ = await store.runNow(dry: false) }
            }
            action("コード", "ticket.fill", id: "home.codes", badge: Int(store.status?.codesPending ?? 0)) {
                store.tab = .codes
            }
            action("トッピング", "cart.fill", id: "home.shop") {
                showShop = true
            }
        }
    }

    private func action(_ title: String, _ icon: String, id: String, busy: Bool = false, badge: Int = 0, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    if busy {
                        ProgressView().frame(height: 22)
                    } else {
                        Image(systemName: icon).font(.system(size: 20, weight: .semibold)).frame(height: 22)
                    }
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.yellow, in: Capsule())
                            .foregroundStyle(.black)
                            .offset(x: 14, y: -8)
                    }
                }
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier(id)
    }
}

/// 確認待ちのカード(通知を見逃したとき用)。
struct PendingCard: View {
    @EnvironmentObject var store: AppStore
    let pending: PendingAction

    var body: some View {
        Card(pending.kind == .buy ? "購入の確認" : "コードの確認", systemImage: "bell.badge.fill") {
            Text(pending.label).font(.headline)
            Text(pending.detail).font(.callout).foregroundStyle(.secondary)
            Text("\(Fmt.when(ms: pending.expiresMs)) まで有効").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("やめる") { Task { await store.dismiss(pending) } }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("pending.dismiss")
                Button {
                    Task { await store.confirm(pending) }
                } label: {
                    if store.isBusy("pending") { ProgressView() } else { Text("実行する") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("pending.execute")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.yellow, lineWidth: 2))
    }
}

struct LastRunCard: View {
    @EnvironmentObject var store: AppStore
    let run: RunRecord

    var body: some View {
        Button {
            store.tab = .activity
        } label: {
            Card("前回の自動チェック", systemImage: "clock.arrow.circlepath",
                 accessory: AnyView(Text(Fmt.when(ms: run.startedMs)).font(.caption).foregroundStyle(.secondary))) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: run.iconName)
                        .foregroundStyle(run.iconTint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.summary).font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text(RunText.trigger(run.trigger)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ToppingsCard: View {
    let snapshot: Snapshot

    var body: some View {
        Card("ご利用中のトッピング", systemImage: "square.stack.3d.up") {
            if let list = snapshot.toppings {
                if list.isEmpty { Text("なし").foregroundStyle(.secondary) }
                ForEach(list, id: \.self) { t in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.subheadline.weight(.medium))
                            if let r = t.remaining { Text("残量 \(r)").font(.caption) }
                            if let e = t.expiryMs {
                                Text("\(Fmt.when(ms: e)) まで").font(.caption).foregroundStyle(expiringSoon(e) ? Theme.danger : .secondary)
                            } else if let e = t.expiry {
                                Text(e.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if t.name.contains("使い放題") { Image(systemName: "infinity").foregroundStyle(.secondary) }
                    }
                    if t != list.last { Divider() }
                }
            } else {
                Text("読めませんでした\(snapshot.toppingsError.map { ": \($0)" } ?? "")。使い放題中か分からないので、ルールによるコード適用は行いません。")
                    .font(.caption)
            }
        }
    }

    private func expiringSoon(_ ms: Int64) -> Bool {
        Double(ms) / 1000 - Date().timeIntervalSince1970 < 3 * 86_400
    }
}

struct BreakdownCard: View {
    let snapshot: Snapshot

    var body: some View {
        Card("内訳", systemImage: "list.bullet") {
            ForEach(snapshot.buckets, id: \.key) { b in
                HStack {
                    Text(b.label)
                    Spacer()
                    Text(Fmt.data(kb: b.leftKb)).monospacedDigit()
                    if let p = b.planKb, p > 0 {
                        Text("/ \(Fmt.data(kb: p))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            if snapshot.callsUsedSec != nil || snapshot.smsUsed != nil {
                Divider()
                HStack {
                    if let c = snapshot.callsUsedSec { Text("通話 \(Int(c) / 60)分\(Int(c) % 60)秒") }
                    Spacer()
                    if let s = snapshot.smsUsed { Text("SMS \(Int(s))通") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

enum RunText {
    static func trigger(_ t: String) -> String {
        switch t {
        case "background": return "バックグラウンド更新"
        case "shortcut": return "ショートカット"
        case "foreground": return "アプリ表示中"
        case "manual": return "手動"
        case "試運転": return "試運転"
        default: return "ショートカット(\(t))"
        }
    }
}
