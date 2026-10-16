import SwiftUI

/// オートメーションを作る・直す(ショートカット App のエディタのように「いつ → もし → すること」)。
struct FlowEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Flow
    private let isNew: Bool
    @State private var showIcon = false
    @State private var showTrigger = false
    @State private var showCondition = false
    @State private var showAction = false
    @State private var confirmRun = false
    @State private var confirmDelete = false

    init(flow: Flow, isNew: Bool) {
        _draft = State(initialValue: flow)
        self.isNew = isNew
    }

    /// 新しいオートメーション(ボタンで実行 / きっかけつき)。
    static func blank(manual: Bool) -> Flow {
        Flow(name: manual ? "新しいショートカット" : "新しいオートメーション", symbol: manual ? "bolt.fill" : "gearshape.2.fill",
             color: manual ? "yellow" : "blue", trigger: manual ? .manual() : .calendar(lead: 30, outingOnly: true),
             actions: [], ask: !manual, showOnHome: manual)
    }

    var body: some View {
        NavigationStack {
            Form {
                header
                triggerSection
                conditionSection
                actionSection
                optionSection
                warningSection
                runSection
            }
            .navigationTitle(isNew ? "新規" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.saveFlow(normalized)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .accessibilityIdentifier("flowEditor.save")
                }
            }
            .sheet(isPresented: $showIcon) { FlowIconPicker(symbol: $draft.symbol, color: $draft.color) }
            .sheet(isPresented: $showTrigger) {
                TriggerPickerView { t in
                    let wasManual = draft.trigger.kind == .manual
                    draft.trigger = t
                    draft.cooldownMin = Flow.defaultCooldown(for: t.kind)
                    if wasManual && t.kind != .manual { draft.showOnHome = false }
                    if t.kind == .manual { draft.showOnHome = true }
                }
            }
            .sheet(isPresented: $showCondition) { ConditionPickerView { draft.conditions.append($0) } }
            .sheet(isPresented: $showAction) { ActionPickerView { draft.actions.append($0) } }
            .confirmationDialog(runQuestion, isPresented: $confirmRun, titleVisibility: .visible) {
                Button("実行する") { Task { await run() } }
                Button("やめる", role: .cancel) {}
            }
            .confirmationDialog("「\(draft.name)」を削除しますか?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.deleteFlow(draft.id)
                    dismiss()
                }
            }
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.actions.isEmpty
    }

    private var normalized: Flow {
        var f = draft
        f.name = f.name.trimmingCharacters(in: .whitespaces)
        if !f.touchesPovo { f.ask = false }
        return f
    }

    private var runQuestion: String {
        let what = draft.actions.map { FlowText.action($0) }.joined(separator: "→")
        return "「\(draft.name)」を今すぐ実行します: \(what)"
    }

    // MARK: - 見出し

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Button { showIcon = true } label: { FlowIcon(symbol: draft.symbol, color: draft.color, size: 52) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flowEditor.icon")
                TextField("名前", text: $draft.name)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("flowEditor.name")
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - いつ

    private var triggerSection: some View {
        Section {
            Button { showTrigger = true } label: {
                HStack(spacing: 12) {
                    PartIcon(symbol: FlowText.triggerSymbol(draft.trigger.kind), tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FlowText.triggerTitle(draft.trigger.kind)).foregroundStyle(.primary)
                        Text(FlowText.trigger(draft.trigger)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("flowEditor.trigger")
            TriggerParams(trigger: $draft.trigger)
        } header: {
            Text("いつ")
        } footer: {
            Text(triggerFooter)
        }
    }

    private var triggerFooter: String {
        switch draft.trigger.kind {
        case .timeOfDay, .calendarEvent, .once:
            return draft.notifyOnly
                ? "時刻になると通知でお知らせします(中身は少し前の残量・予定で作ります)。"
                : "時刻になると「実行する」ボタンつきの通知が届きます。その前後に povoX が動いていれば、そのまま実行します。"
        case .leftWifi, .joinedWifi, .unplugged:
            return "povoX が次に残量を確かめたときに気づきます。すぐ動かすには、ショートカット App のオートメーションに「povoXの自動チェック」を入れてください。"
        case .manual:
            return "ホームのボタン・Siri・ショートカット App(「povoXのオートメーションを実行」)から動かします。"
        default:
            return "povoX が残量を確かめるたびに見ます(バックグラウンド更新・アプリ表示中・ショートカット・位置情報)。"
        }
    }

    // MARK: - もし

    private var conditionSection: some View {
        Section {
            ForEach($draft.conditions) { $c in
                ConditionRow(condition: $c)
            }
            .onDelete { draft.conditions.remove(atOffsets: $0) }
            if draft.conditions.count > 1 {
                Picker("条件の合わせ方", selection: $draft.matchAll) {
                    Text("すべて合う").tag(true)
                    Text("どれか合う").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Button { showCondition = true } label: { Label("条件を追加", systemImage: "plus.circle.fill") }
                .accessibilityIdentifier("flowEditor.addCondition")
        } header: {
            Text("もし(なくてもよい)")
        } footer: {
            if !draft.conditions.isEmpty { Text("条件は左にスワイプで消せます。") }
        }
    }

    // MARK: - すること

    private var actionSection: some View {
        Section {
            ForEach($draft.actions) { $a in
                let id = a.id
                ActionRow(index: draft.actions.firstIndex { $0.id == id } ?? 0, action: $a, count: draft.actions.count, selfID: draft.id,
                          move: { from, to in draft.actions.move(fromOffsets: IndexSet(integer: from), toOffset: to) },
                          remove: { draft.actions.removeAll { $0.id == id } })
            }
            .onDelete { draft.actions.remove(atOffsets: $0) }
            Button { showAction = true } label: { Label("アクションを追加", systemImage: "plus.circle.fill") }
                .accessibilityIdentifier("flowEditor.addAction")
        } header: {
            Text("すること")
        } footer: {
            Text("コード・使い放題・データ追加は上から試し、できたところで止まります(1回に1つ)。通知と設定の切り替えは全部行います。")
        }
    }

    // MARK: - オプション

    private var optionSection: some View {
        Section("オプション") {
            Toggle("オン", isOn: $draft.enabled)
            if draft.touchesPovo {
                Toggle(isOn: $draft.ask) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("実行前に確認")
                        Text(draft.ask ? "購入・コードは通知の「実行する」を押してから" : (draft.trigger.kind == .manual ? "ボタンを押したら、そのまま実行" : "povoX の設定(購入のしかた)に従う"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("flowEditor.ask")
            }
            Toggle("ホームに置く", isOn: $draft.showOnHome)
            if !draft.trigger.isScheduled && draft.trigger.kind != .manual && draft.trigger.kind != .shortcut {
                Stepper(value: $draft.cooldownMin, in: 0...720, step: 15) {
                    LabeledContent("続けて動かさない", value: draft.cooldownMin == 0 ? "なし" : "\(draft.cooldownMin)分")
                }
            }
        }
    }

    @ViewBuilder
    private var warningSection: some View {
        let warnings = self.warnings
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var warnings: [String] {
        var out: [String] = []
        guard let s = store.status?.settings else { return out }
        if draft.spends && s.purchaseMode == .off { out.append("設定で「ルールによる購入」が「しない」なので、購入はしません(設定タブで変えられます)。") }
        if draft.actions.contains(where: { $0.kind == .applyCode }) && s.codeMode == .off { out.append("設定で「コード適用」が「しない」なので、コードは使いません。") }
        if s.dryRun && draft.touchesPovo { out.append("試運転中なので、記録だけになります。") }
        let needsCal = draft.trigger.kind == .calendarEvent || draft.conditions.contains { [.dayShort, .inOuting, .outingWithin].contains($0.kind) }
            || draft.actions.contains { $0.kind == .dayBrief }
        if needsCal && store.calendarAccess != .authorized { out.append("カレンダーが許可されていないので、予定を使う部分は動きません。") }
        if [.arrive, .leave].contains(draft.trigger.kind) && !AppServices.shared.settings.locationEnabled {
            out.append("位置情報での起動がオフです(設定 → 自動チェックのきっかけ)。")
        }
        return out
    }

    // MARK: - 実行・削除

    private var runSection: some View {
        Section {
            Button {
                if draft.spends { confirmRun = true } else { Task { await run() } }
            } label: {
                HStack {
                    Label("今すぐ実行", systemImage: "play.fill")
                    Spacer()
                    if store.isBusy("flow") { ProgressView() }
                }
            }
            .disabled(draft.actions.isEmpty || store.isBusy("flow"))
            .accessibilityIdentifier("flowEditor.run")
            if !isNew {
                Button("削除", role: .destructive) { confirmDelete = true }
            }
        } footer: {
            Text("今すぐ実行は、きっかけを待たずに動かします(条件と安全装置は通ります)。")
        }
    }

    private func run() async {
        if isNew || store.flow(draft.id) != normalized {
            await store.runAdHoc(normalized)
        } else {
            await store.runFlow(normalized)
        }
    }
}

// MARK: - きっかけの細かい設定

struct TriggerParams: View {
    @Binding var trigger: FlowTrigger

    static let gbOptions: [Double] = [0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 3, 5]
    static let hourOptions: [Double] = [1, 2, 3, 6, 12, 24]
    static let minuteOptions = [5, 10, 15, 30, 60]
    static let percentOptions = [10, 15, 20, 30, 50]
    static let mbOptions = [300, 500, 1000, 2000, 3000]
    static let leadOptions = [0, 10, 15, 30, 60, 90, 120, 180]

    var body: some View {
        switch trigger.kind {
        case .dataBelow:
            ValuePicker(title: "残量", value: orDefault($trigger.gb, 0.1), options: Self.gbOptions) { "\(FlowEngine.gbText($0)) を下回ったら" }
        case .hoursLeftBelow:
            ValuePicker(title: "あと", value: orDefault($trigger.hours, 3), options: Self.hourOptions) { "\(FlowEngine.hoursText($0))を切ったら" }
        case .unlimitedEnding:
            ValuePicker(title: "残り", value: orDefault($trigger.minutes, 10), options: Self.minuteOptions) { "\($0)分を切ったら" }
        case .batteryBelow:
            ValuePicker(title: "電池", value: orDefault($trigger.percent, 20), options: Self.percentOptions) { "\($0)%以下" }
        case .usedTodayAbove:
            ValuePicker(title: "今日の使用量", value: orDefault($trigger.mb, 1000), options: Self.mbOptions) { "\($0)MB 以上" }
        case .timeOfDay:
            DatePicker("時刻", selection: timeBinding, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, DayPlanner.tokyo.timeZone)
            WeekdayPicker(days: $trigger.weekdays)
        case .calendarEvent:
            ValuePicker(title: "予定の", value: orDefault($trigger.leadMin, 30), options: Self.leadOptions) { $0 == 0 ? "始まるとき" : "\($0)分前" }
            Toggle("外出の予定だけ", isOn: orDefault($trigger.outingOnly, false))
            TextField("タイトル・場所に含む言葉(空なら全部)", text: orDefault($trigger.keyword, ""))
        case .shortcut:
            TextField("名前(例: 出発)", text: orDefault($trigger.name, ""))
            Text("ショートカット App → オートメーション → アクション「povoXの自動チェック」の「きっかけ」に、この名前を入れます。")
                .font(.caption).foregroundStyle(.secondary)
        case .once:
            DatePicker("日時", selection: onceBinding, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, DayPlanner.tokyo.timeZone)
        default:
            EmptyView()
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { FlowEngine.time(trigger, on: Date()) ?? Date() },
            set: { d in
                let c = DayPlanner.tokyo.dateComponents([.hour, .minute], from: d)
                trigger.hour = c.hour
                trigger.minute = c.minute
            })
    }

    private var onceBinding: Binding<Date> {
        Binding(
            get: { trigger.atMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date().addingTimeInterval(3600) },
            set: { trigger.atMs = Int64($0.timeIntervalSince1970 * 1000) })
    }
}

// MARK: - 条件の行

struct ConditionRow: View {
    @Binding var condition: FlowCondition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PartIcon(symbol: FlowText.conditionSymbol(condition.kind), tint: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(FlowText.conditionTitle(condition.kind))
                    Text(FlowText.condition(condition)).font(.caption).foregroundStyle(.secondary)
                }
            }
            params
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var params: some View {
        switch condition.kind {
        case .dataBelow, .dataAbove:
            ValuePicker(title: "残量", value: orDefault($condition.gb, 1), options: TriggerParams.gbOptions) { FlowEngine.gbText($0) }
        case .hoursLeftBelow, .outingWithin:
            ValuePicker(title: "時間", value: orDefault($condition.hours, 3), options: TriggerParams.hourOptions) { FlowEngine.hoursText($0) }
        case .batteryBelow:
            ValuePicker(title: "電池", value: orDefault($condition.percent, 20), options: TriggerParams.percentOptions) { "\($0)%以下" }
        case .usedTodayAbove:
            ValuePicker(title: "今日の使用量", value: orDefault($condition.mb, 1000), options: TriggerParams.mbOptions) { "\($0)MB 以上" }
        case .timeBetween:
            HStack {
                ValuePicker(title: "から", value: orDefault($condition.from, 7), options: Array(0...23)) { "\($0)時から" }
                ValuePicker(title: "まで", value: orDefault($condition.to, 23), options: Array(1...24)) { "\($0)時まで" }
            }
        case .weekdays:
            WeekdayPicker(days: $condition.weekdays)
        case .hasCodes:
            TextField("タグ(空ならどれでも)", text: orDefault($condition.tag, ""))
        default:
            EmptyView()
        }
    }
}

// MARK: - アクションの行

struct ActionRow: View {
    @EnvironmentObject var store: AppStore
    let index: Int
    @Binding var action: FlowAction
    let count: Int
    let selfID: String
    let move: (Int, Int) -> Void
    let remove: () -> Void

    static let unlimitedOptions = [0, 1, 24, 72, 168]
    static let dataOptions: [Double?] = [nil, 1, 3, 5]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                PartIcon(symbol: FlowText.actionSymbol(action.kind), tint: action.touchesPovo ? Theme.ok : .purple)
                Text(FlowText.actionTitle(action.kind))
                Spacer(minLength: 0)
                Menu {
                    if index > 0 { Button { move(index, index - 1) } label: { Label("上へ", systemImage: "arrow.up") } }
                    if index < count - 1 { Button { move(index, index + 2) } label: { Label("下へ", systemImage: "arrow.down") } }
                    Button(role: .destructive) { remove() } label: { Label("削除", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
            params
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var params: some View {
        switch action.kind {
        case .applyCode:
            TextField("タグ(空なら手持ちのどれか)", text: orDefault($action.tag, ""))
        case .buyUnlimited:
            ValuePicker(title: "長さ", value: orDefault($action.hours, 24), options: Self.unlimitedOptions) { h in
                h == 0 ? "予定の長さに合わせる" : DayPlanner.durationName(h)
            }
        case .buyData:
            ValuePicker(title: "量", value: $action.gb, options: Self.dataOptions) { g in
                g.map { FlowEngine.gbText($0) } ?? "一番小さいもの"
            }
        case .notify:
            TextField("タイトル", text: orDefault($action.title, ""))
            TextField("本文", text: orDefault($action.body, ""), axis: .vertical)
                .lineLimit(1...4)
            Text("差し込み: {残量} {あと} {今日} {時刻} {予定} {開始} {場所} {使い放題}")
                .font(.caption2).foregroundStyle(.secondary)
        case .dayBrief:
            ValuePicker(title: "どの日", value: orDefault($action.day, "auto"), options: ["auto", "today", "tomorrow"]) { d in
                switch d {
                case "today": return "今日"
                case "tomorrow": return "明日"
                default: return "18時までは今日、そのあとは明日"
                }
            }
        case .setPurchaseMode, .setCodeMode:
            ValuePicker(title: "しかた", value: orDefault($action.mode, "confirm"), options: ["off", "confirm", "auto"]) { FlowText.modeLabel($0) }
        case .setFlowEnabled:
            let others = store.flows.filter { $0.id != selfID }
            Picker("オートメーション", selection: $action.flowID) {
                Text("選ぶ").tag(String?.none)
                ForEach(others) { f in Text(f.name).tag(String?.some(f.id)) }
            }
            .pickerStyle(.menu)
            Toggle("オンにする", isOn: orDefault($action.on, true))
        case .log:
            TextField("メモ", text: orDefault($action.body, ""))
        }
    }
}
