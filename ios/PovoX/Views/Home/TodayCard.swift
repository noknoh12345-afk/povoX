import SwiftUI

/// 今日のプラン: 予定から外出を拾い、残量で足りるか・出かける前に何を入れておくと楽かを出す。
struct TodayPlanCard: View {
    @EnvironmentObject var store: AppStore
    @State private var showTomorrow = false
    @State private var confirmNow: DayPlanner.Suggestion?

    private var plan: DayPlanner.Plan? { showTomorrow ? store.tomorrow : store.today }

    private var learnLabel: String {
        guard let m = store.learned else { return "学習: まだ" }
        let n = m.kinds.values.reduce(0) { $0 + $1.events }
        return n > 0 ? "学習: 外出\(n)件から" : "学習: データ待ち"
    }

    var body: some View {
        Group {
            if store.calendarAccess != .authorized {
                askCard
            } else if let plan {
                planCard(plan)
            }
        }
        .onAppear {
            // 夕方以降で今日の外出がもう無ければ、明日を先に見せる
            if let t = store.today, t.outings.isEmpty, DayPlanner.tokyo.component(.hour, from: Date()) >= 18 { showTomorrow = true }
        }
        .confirmationDialog(confirmNow.map { "\($0.what)を今すぐ入れますか?" } ?? "",
                            isPresented: Binding(get: { confirmNow != nil }, set: { if !$0 { confirmNow = nil } }), titleVisibility: .visible) {
            if let s = confirmNow {
                Button("今すぐ入れる") { Task { await store.runSuggestionNow(s) } }
            }
            Button("やめる", role: .cancel) { confirmNow = nil }
        } message: {
            Text("上限・回数などの安全装置は通ります。")
        }
    }

    private var askCard: some View {
        Card("今日のプラン", systemImage: "calendar") {
            Text("カレンダーを許可すると、外出の予定に合わせて「足りるか」「出かける前に何を入れておくと楽か」を先回りして出します。家で Wi-Fi の日は何もしません。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await store.requestCalendar() }
            } label: {
                Label("カレンダーを許可", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("today.allowCalendar")
            Text("予定は端末の中だけで使い、外へは送りません。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func planCard(_ p: DayPlanner.Plan) -> some View {
        Card(nil, systemImage: nil) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Picker("日", selection: $showTomorrow) {
                    Text("今日").tag(false)
                    Text("明日").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                .accessibilityIdentifier("today.day")
                Spacer(minLength: 0)
                VerdictChip(verdict: p.verdict)
            }
            Text(p.headline)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.headline")
            if !p.outings.isEmpty {
                VStack(spacing: 8) {
                    ForEach(p.outings) { o in OutingRow(outing: o, learned: store.learned?.rate(o.kind) != nil) }
                }
                if let left = p.leftMB, p.needMB > 0, p.verdict != .covered {
                    VStack(alignment: .leading, spacing: 4) {
                        MeterBar(fraction: left / p.needMB, tint: left >= p.needMB ? Theme.ok : Theme.warn)
                        Text("見込み 約\(DayPlanner.mbText(p.needMB)) / 残り \(DayPlanner.mbText(left))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                Text(p.detail).font(.caption).foregroundStyle(.secondary)
            }
            if let s = p.suggestion {
                SuggestionBox(suggestion: s, plan: p, confirmNow: $confirmNow)
            }
            if !showTomorrow && !store.todayOthers.isEmpty {
                OtherEventsList(events: store.todayOthers)
            }
            HStack {
                IntensityMenu()
                Spacer(minLength: 0)
                NavigationLink { LearningView() } label: {
                    Label(learnLabel, systemImage: "brain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("today.learning")
            }
        }
    }
}

private struct VerdictChip: View {
    let verdict: DayPlanner.Verdict

    var body: some View {
        switch verdict {
        case .noOutings: Chip(text: "外出なし", systemImage: "house", tint: .secondary)
        case .covered: Chip(text: "使い放題で安心", systemImage: "infinity", filled: true)
        case .enough: Chip(text: "足りる", systemImage: "checkmark.circle.fill", tint: Theme.ok)
        case .tight: Chip(text: "ぎりぎり", systemImage: "exclamationmark.circle.fill", tint: Theme.warn)
        case .short: Chip(text: "足りない", systemImage: "exclamationmark.triangle.fill", tint: Theme.danger)
        case .unknown: Chip(text: "残量不明", systemImage: "questionmark.circle", tint: .secondary)
        }
    }
}

private struct OutingRow: View {
    @EnvironmentObject var store: AppStore
    let outing: DayPlanner.Outing
    /// この種類の量を学習済みか。
    var learned = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PartIcon(symbol: outing.kind.symbol, tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(outing.event.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(timeText + (outing.event.location.map { "・\($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text("約\(DayPlanner.mbText(outing.estMB))").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                Text(learned ? "学習済み" : "目安").font(.caption2).foregroundStyle(.tertiary)
            }
            Menu {
                Button { Task { await store.setOverride(title: outing.event.title, outing: false) } } label: {
                    Label("家だった(外出に数えない)", systemImage: "house")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("today.outing.menu")
        }
    }

    private var timeText: String {
        outing.event.allDay ? "終日(\(outing.kind.label))" : "\(DayPlanner.hm(outing.event.start))〜\(DayPlanner.hm(outing.event.end))"
    }
}

/// 外出に数えていない今日の予定(「外出だった」と直せる)。
private struct OtherEventsList: View {
    @EnvironmentObject var store: AppStore
    let events: [CalEvent]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(events) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.caption).lineLimit(1)
                        Text(e.allDay ? "終日" : "\(DayPlanner.hm(e.start))〜\(DayPlanner.hm(e.end))").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("外出だった") { Task { await store.setOverride(title: e.title, outing: true) } }
                        .font(.caption)
                }
            }
        } label: {
            Text("外出に数えていない予定 \(events.count)件").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 提案と、予約・今すぐのボタン。
private struct SuggestionBox: View {
    @EnvironmentObject var store: AppStore
    let suggestion: DayPlanner.Suggestion
    let plan: DayPlanner.Plan
    @Binding var confirmNow: DayPlanner.Suggestion?

    var body: some View {
        let reserved = store.reservation(for: suggestion)
        let later = suggestion.at > Date().addingTimeInterval(120)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill").foregroundStyle(Theme.accent)
                Text(later ? "\(DayPlanner.hm(suggestion.at)) に \(suggestion.what)" : "今 \(suggestion.what)")
                    .font(.subheadline.weight(.bold))
            }
            Text(suggestion.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let r = reserved {
                HStack {
                    Label("\(DayPlanner.hm(suggestion.at)) に予約済み", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.ok)
                    Spacer()
                    Button("取り消す") { store.deleteFlow(r.id) }
                        .font(.caption)
                        .accessibilityIdentifier("today.cancelReservation")
                }
            } else {
                HStack(spacing: 10) {
                    if later {
                        Button {
                            store.reserve(suggestion, plan: plan)
                        } label: {
                            Label("予約する", systemImage: "calendar.badge.clock")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("today.reserve")
                    }
                    Button {
                        confirmNow = suggestion
                    } label: {
                        if store.isBusy("flow") { ProgressView() } else { Text(later ? "今すぐ" : "今すぐ入れる") }
                    }
                    .buttonStyle(later ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                    .accessibilityIdentifier("today.now")
                }
                if later {
                    Text("予約すると、その時刻に povoX が入れます(通知の「実行する」でも)。上限などの安全装置は通ります。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.yellow.opacity(0.7), lineWidth: 1))
    }
}

/// 見積もりの濃さを変える。
private struct IntensityMenu: View {
    @EnvironmentObject var store: AppStore
    private let names = ["控えめ", "ふつう", "たくさん"]

    var body: some View {
        Menu {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    Task { await store.setUsageIntensity(i) }
                } label: {
                    if i == store.usageIntensity { Label(names[i], systemImage: "checkmark") } else { Text(names[i]) }
                }
            }
        } label: {
            Label("外での使い方: \(names[max(0, min(2, store.usageIntensity))])(見込みは目安)", systemImage: "slider.horizontal.below.rectangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// ButtonStyle を条件で切り替えるための入れ物。
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// ホームに置いたショートカット(タップで実行)。
struct HomeShortcuts: View {
    @EnvironmentObject var store: AppStore
    @State private var confirm: Flow?
    @State private var editing: FlowEditTarget?

    private var items: [Flow] { store.flows.filter { $0.showOnHome } }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("ショートカット", systemImage: "square.2.layers.3d.top.filled")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("編集") { store.tab = .rules }
                        .font(.footnote)
                        .accessibilityIdentifier("home.shortcuts.edit")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(items) { f in
                        ShortcutTileButton(flow: f, confirm: $confirm, editing: $editing, compact: true)
                    }
                }
            }
            .flowRunConfirmation($confirm)
            .sheet(item: $editing) { t in FlowEditorView(flow: t.flow, isNew: t.isNew).environmentObject(store) }
        }
    }
}
