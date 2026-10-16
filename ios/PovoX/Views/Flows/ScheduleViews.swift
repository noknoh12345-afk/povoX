import SwiftUI

/// 「スケジュール」: 目覚まし時計のように、いつ・どんな日に・何をするかを決める(時刻・1回だけのオートメーション)。
struct SchedulePane: View {
    @EnvironmentObject var store: AppStore
    @Binding var editing: FlowEditTarget?
    @State private var alarm: FlowEditTarget?

    private var alarms: [Flow] {
        store.flows.filter { $0.trigger.kind == .timeOfDay || $0.trigger.kind == .once }
            .sorted { sortKey($0) < sortKey($1) }
    }

    private func sortKey(_ f: Flow) -> Int {
        if f.trigger.kind == .once, let ms = f.trigger.atMs {
            let c = DayPlanner.tokyo.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        return (f.trigger.hour ?? 0) * 60 + (f.trigger.minute ?? 0)
    }

    private var facts: FlowFacts {
        var f = store.planFacts ?? FlowFacts()
        f.now = Date()
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NextAlarmBanner(alarms: alarms, facts: facts)
            ForEach(alarms) { f in
                AlarmRow(flow: f, facts: facts) { alarm = FlowEditTarget(flow: f, isNew: false) } detail: {
                    editing = FlowEditTarget(flow: f, isNew: false)
                }
            }
            Button {
                alarm = FlowEditTarget(flow: AlarmEditorView.blank(), isNew: true)
            } label: {
                Label("アラームを追加", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("schedule.add")
            Text("時刻に通知が届きます(アプリが閉じていても)。povo の操作は「実行する」で、そのほかは通知そのものが実行です。曜日・祝日・予定の有無は前もって見て、合わない日は鳴らしません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $alarm) { t in AlarmEditorView(flow: t.flow, isNew: t.isNew).environmentObject(store) }
    }
}

private struct NextAlarmBanner: View {
    let alarms: [Flow]
    let facts: FlowFacts

    var body: some View {
        let next = alarms.compactMap { f in FlowEngine.nextRing(f, facts: facts).map { (f, $0) } }.min { $0.1 < $1.1 }
        HStack(spacing: 10) {
            Image(systemName: "alarm.fill").foregroundStyle(Theme.accent)
            if let n = next {
                Text("次は \(dayLabel(n.1)) \(DayPlanner.hm(n.1))・\(n.0.name)").font(.subheadline.weight(.semibold))
            } else {
                Text("鳴る予定のアラームはありません").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityIdentifier("schedule.next")
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = DayPlanner.tokyo
        if cal.isDateInToday(d) { return "今日" }
        if cal.isDateInTomorrow(d) { return "明日" }
        let c = cal.dateComponents([.month, .day, .weekday], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)(\(FlowEngine.weekdayName((c.weekday ?? 1) - 1)))"
    }
}

/// 目覚まし時計の1行(大きな時刻・いつ鳴るか・すること・オン/オフ)。
private struct AlarmRow: View {
    @EnvironmentObject var store: AppStore
    let flow: Flow
    let facts: FlowFacts
    let open: () -> Void
    let detail: () -> Void

    private var timeText: String {
        if flow.trigger.kind == .once, let ms = flow.trigger.atMs {
            return DayPlanner.hm(Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        return String(format: "%d:%02d", flow.trigger.hour ?? 7, flow.trigger.minute ?? 0)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeText)
                        .font(.system(size: 46, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(flow.enabled ? Color.primary : Color.secondary)
                    Text("\(flow.name)・\(FlowText.alarmRepeat(flow))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(flow.enabled ? Color.primary : Color.secondary)
                        .lineLimit(2)
                    Text(flow.actions.map { FlowText.action($0) }.joined(separator: "→"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    FlowLastRun(flow: flow, memory: store.flowMemory)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { flow.enabled }, set: { store.setFlowEnabled(flow.id, $0) }))
                .labelsHidden()
                .accessibilityIdentifier("alarmToggle.\(flow.galleryID ?? flow.id)")
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contextMenu {
            Button(action: open) { Label("編集", systemImage: "alarm") }
            Button(action: detail) { Label("詳しく編集(条件をすべて)", systemImage: "slider.horizontal.3") }
            Button(role: .destructive) { store.deleteFlow(flow.id) } label: { Label("削除", systemImage: "trash") }
        }
    }
}

/// アラームの編集(時刻のホイール・繰り返し・祝日・どんな日に・ラベル・すること・スヌーズ)。
struct AlarmEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Flow
    private let isNew: Bool
    @State private var showAction = false

    init(flow: Flow, isNew: Bool) {
        _draft = State(initialValue: flow)
        self.isNew = isNew
    }

    static func blank() -> Flow {
        Flow(name: "アラーム", symbol: "alarm.fill", color: "orange", trigger: .time(7, 0), actions: [.brief("today")], ask: true)
    }

    enum Repeat: String, CaseIterable, Identifiable {
        case everyday, workday, dayOff, custom, once
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyday: return "毎日"
            case .workday: return "平日"
            case .dayOff: return "休日"
            case .custom: return "曜日"
            case .once: return "1回"
            }
        }
    }

    enum DayKind: String, CaseIterable, Identifiable {
        case any, outing, home, short
        var id: String { rawValue }
        var label: String {
            switch self {
            case .any: return "いつでも"
            case .outing: return "外出の予定がある日だけ"
            case .home: return "外出の予定がない日だけ"
            case .short: return "今日の予定に残量が足りない日だけ"
            }
        }
        var condition: FlowConditionKind? {
            switch self {
            case .any: return nil
            case .outing: return .dayHasOuting
            case .home: return .dayNoOuting
            case .short: return .dayShort
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("時刻", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .environment(\.timeZone, DayPlanner.tokyo.timeZone)
                        .accessibilityIdentifier("alarm.time")
                }
                Section("繰り返し") {
                    Picker("繰り返し", selection: repeatBinding) {
                        ForEach(Repeat.allCases) { r in Text(r.label).tag(r) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("alarm.repeat")
                    switch repeatMode {
                    case .custom:
                        WeekdayPicker(days: $draft.trigger.weekdays)
                    case .once:
                        DatePicker("日付", selection: onceDateBinding, in: Date()..., displayedComponents: .date)
                            .environment(\.timeZone, DayPlanner.tokyo.timeZone)
                    default:
                        EmptyView()
                    }
                    if repeatMode == .everyday || repeatMode == .custom {
                        Toggle("祝日は鳴らさない", isOn: conditionToggle(.notHoliday))
                    }
                    if repeatMode == .workday {
                        Text("土日と祝日(振替休日・国民の休日を含む)は鳴らしません。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("どんな日に", selection: dayKindBinding) {
                        ForEach(DayKind.allCases) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("どんな日に")
                } footer: {
                    if dayKindBinding.wrappedValue != .any && store.calendarAccess != .authorized {
                        Text("カレンダーが許可されていないので、予定を使う条件は満たされません。")
                    }
                }
                Section("ラベル") {
                    TextField("ラベル", text: $draft.name)
                        .accessibilityIdentifier("alarm.label")
                }
                Section {
                    ForEach($draft.actions) { $a in
                        let id = a.id
                        ActionRow(index: draft.actions.firstIndex { $0.id == id } ?? 0, action: $a, count: draft.actions.count, selfID: draft.id,
                                  move: { from, to in draft.actions.move(fromOffsets: IndexSet(integer: from), toOffset: to) },
                                  remove: { draft.actions.removeAll { $0.id == id } })
                    }
                    .onDelete { draft.actions.remove(atOffsets: $0) }
                    Button { showAction = true } label: { Label("することを追加", systemImage: "plus.circle.fill") }
                } header: {
                    Text("鳴ったらすること")
                } footer: {
                    Text(draft.notifyOnly ? "通知だけなので、時刻に通知が届けばそれで完了です。" : "povo の操作・設定の切り替えは、通知の「実行する」で行います(その前後に povoX が動いていればそのまま実行)。")
                }
                Section {
                    Picker("スヌーズ", selection: snoozeBinding) {
                        Text("しない").tag(0)
                        Text("5分").tag(5)
                        Text("10分").tag(10)
                        Text("15分").tag(15)
                        Text("30分").tag(30)
                    }
                    if draft.touchesPovo {
                        Toggle("購入・コードは通知で確認してから", isOn: $draft.ask)
                    }
                    Toggle("オン", isOn: $draft.enabled)
                } footer: {
                    Text("スヌーズ: 通知を押すか消すまで、もう一度鳴らします。")
                }
                if !isNew {
                    Section {
                        Button("アラームを削除", role: .destructive) {
                            store.deleteFlow(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "アラームを追加" : "アラームを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var f = draft
                        f.name = f.name.trimmingCharacters(in: .whitespaces).isEmpty ? "アラーム" : f.name
                        if !f.touchesPovo { f.ask = false }
                        f.cooldownMin = 0
                        store.saveFlow(f)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.actions.isEmpty)
                    .accessibilityIdentifier("alarm.save")
                }
            }
            .sheet(isPresented: $showAction) { ActionPickerView { draft.actions.append($0) } }
        }
    }

    // MARK: - 値のつなぎ

    private var repeatMode: Repeat {
        if draft.trigger.kind == .once { return .once }
        if has(.workday) { return .workday }
        if has(.dayOff) { return .dayOff }
        return draft.trigger.weekdays == nil ? .everyday : .custom
    }

    private func has(_ k: FlowConditionKind) -> Bool { draft.conditions.contains { $0.kind == k } }

    private func setCondition(_ k: FlowConditionKind, _ on: Bool) {
        draft.conditions.removeAll { $0.kind == k }
        if on { draft.conditions.append(FlowCondition(k)) }
    }

    private func conditionToggle(_ k: FlowConditionKind) -> Binding<Bool> {
        Binding(get: { has(k) }, set: { setCondition(k, $0) })
    }

    /// 今の時刻(時・分)。
    private var hourMinute: (Int, Int) {
        if draft.trigger.kind == .once, let ms = draft.trigger.atMs {
            let c = DayPlanner.tokyo.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ms) / 1000))
            return (c.hour ?? 7, c.minute ?? 0)
        }
        return (draft.trigger.hour ?? 7, draft.trigger.minute ?? 0)
    }

    private var repeatBinding: Binding<Repeat> {
        Binding(get: { repeatMode }, set: { r in
            let (h, m) = hourMinute
            for k in [FlowConditionKind.workday, .dayOff] { setCondition(k, false) }
            switch r {
            case .once:
                // 次にその時刻が来る日
                var at = AlarmEditorView.date(on: Date(), h, m)
                if at <= Date() { at = at.addingTimeInterval(86_400) }
                let snooze = draft.trigger.snoozeMin
                draft.trigger = .once(at)
                draft.trigger.snoozeMin = snooze
                setCondition(.notHoliday, false)
            default:
                if draft.trigger.kind == .once {
                    let snooze = draft.trigger.snoozeMin
                    draft.trigger = .time(h, m)
                    draft.trigger.snoozeMin = snooze
                }
                switch r {
                case .everyday: draft.trigger.weekdays = nil
                case .workday: draft.trigger.weekdays = nil; setCondition(.workday, true); setCondition(.notHoliday, false)
                case .dayOff: draft.trigger.weekdays = nil; setCondition(.dayOff, true); setCondition(.notHoliday, false)
                case .custom: draft.trigger.weekdays = draft.trigger.weekdays ?? [1, 2, 3, 4, 5]
                case .once: break
                }
            }
        })
    }

    private var dayKindBinding: Binding<DayKind> {
        Binding(get: {
            DayKind.allCases.first { k in k.condition.map(has) ?? false } ?? .any
        }, set: { k in
            for c in [FlowConditionKind.dayHasOuting, .dayNoOuting, .dayShort] { setCondition(c, false) }
            if let c = k.condition { setCondition(c, true) }
        })
    }

    private var snoozeBinding: Binding<Int> {
        Binding(get: { draft.trigger.snoozeMin ?? 0 }, set: { draft.trigger.snoozeMin = $0 == 0 ? nil : $0 })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let (h, m) = hourMinute
            return AlarmEditorView.date(on: Date(), h, m)
        }, set: { d in
            let c = DayPlanner.tokyo.dateComponents([.hour, .minute], from: d)
            if draft.trigger.kind == .once, let ms = draft.trigger.atMs {
                let day = Date(timeIntervalSince1970: Double(ms) / 1000)
                draft.trigger.atMs = Int64(AlarmEditorView.date(on: day, c.hour ?? 7, c.minute ?? 0).timeIntervalSince1970 * 1000)
            } else {
                draft.trigger.hour = c.hour
                draft.trigger.minute = c.minute
            }
        })
    }

    private var onceDateBinding: Binding<Date> {
        Binding(get: {
            draft.trigger.atMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        }, set: { d in
            let (h, m) = hourMinute
            draft.trigger.atMs = Int64(AlarmEditorView.date(on: d, h, m).timeIntervalSince1970 * 1000)
        })
    }

    static func date(on day: Date, _ h: Int, _ m: Int) -> Date {
        var c = DayPlanner.tokyo.dateComponents([.year, .month, .day], from: day)
        c.hour = h
        c.minute = m
        return DayPlanner.tokyo.date(from: c) ?? day
    }
}
