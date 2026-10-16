import SwiftUI

/// 編集する対象(シートに渡す)。
struct FlowEditTarget: Identifiable {
    let flow: Flow
    let isNew: Bool
    var id: String { flow.id }
}

/// 「自動化」タブ: ショートカット(ボタンで実行)・オートメーション(きっかけで実行)・ギャラリー・ルール。
struct AutomationsView: View {
    @EnvironmentObject var store: AppStore
    @State private var pane: Pane = .shortcuts
    @State private var editing: FlowEditTarget?

    enum Pane: String, CaseIterable, Identifiable {
        case shortcuts, automations, gallery
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shortcuts: return "ショートカット"
            case .automations: return "オートメーション"
            case .gallery: return "ギャラリー"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusBanners()
                    Picker("表示", selection: $pane) {
                        ForEach(Pane.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("flows.pane")
                    switch pane {
                    case .shortcuts: ShortcutsPane(editing: $editing)
                    case .automations: AutomationsPane(editing: $editing)
                    case .gallery: GalleryPane(added: { pane = $0.trigger.kind == .manual ? .shortcuts : .automations })
                    }
                    AdvancedRulesCard()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("自動化")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = FlowEditTarget(flow: FlowEditorView.blank(manual: true), isNew: true) } label: {
                            Label("新しいショートカット(ボタン)", systemImage: "hand.tap")
                        }
                        Button { editing = FlowEditTarget(flow: FlowEditorView.blank(manual: false), isNew: true) } label: {
                            Label("新しいオートメーション(きっかけ)", systemImage: "clock.arrow.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("flows.add")
                }
            }
            .sheet(item: $editing) { t in
                FlowEditorView(flow: t.flow, isNew: t.isNew).environmentObject(store)
            }
        }
    }
}

// MARK: - ショートカット(ボタンで実行)

struct ShortcutsPane: View {
    @EnvironmentObject var store: AppStore
    @Binding var editing: FlowEditTarget?
    @State private var confirm: Flow?

    private var manual: [Flow] { store.flows.filter { $0.trigger.kind == .manual } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(manual) { f in
                    ShortcutTileButton(flow: f, confirm: $confirm, editing: $editing)
                }
                Button {
                    editing = FlowEditTarget(flow: FlowEditorView.blank(manual: true), isNew: true)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                        Text("ショートカットを作る").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flows.newShortcut")
            }
            Text("タップで実行、長押しで編集。Siri やショートカット App(「povoXのオートメーションを実行」)からも動かせます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .flowRunConfirmation($confirm)
    }
}

/// 1つのタイル(タップで実行・長押しメニュー)。
struct ShortcutTileButton: View {
    @EnvironmentObject var store: AppStore
    let flow: Flow
    @Binding var confirm: Flow?
    @Binding var editing: FlowEditTarget?
    var compact = false
    @State private var running = false

    var body: some View {
        Button {
            if flow.spends { confirm = flow } else { Task { await run() } }
        } label: {
            FlowTile(flow: flow, busy: running, compact: compact)
        }
        .buttonStyle(.plain)
        .disabled(running)
        .contextMenu {
            Button { editing = FlowEditTarget(flow: flow, isNew: false) } label: { Label("編集", systemImage: "slider.horizontal.3") }
            Button {
                var f = flow
                f.showOnHome.toggle()
                store.saveFlow(f)
            } label: {
                Label(flow.showOnHome ? "ホームから外す" : "ホームに置く", systemImage: flow.showOnHome ? "rectangle.badge.minus" : "rectangle.badge.plus")
            }
            Button(role: .destructive) { store.deleteFlow(flow.id) } label: { Label("削除", systemImage: "trash") }
        }
        .accessibilityIdentifier("flowTile.\(flow.galleryID ?? flow.id)")
    }

    private func run() async {
        running = true
        await store.runFlow(flow)
        running = false
    }
}

extension View {
    /// お金が動くショートカットを押したときの確認。
    func flowRunConfirmation(_ flow: Binding<Flow?>) -> some View {
        modifier(FlowRunConfirmation(flow: flow))
    }
}

private struct FlowRunConfirmation: ViewModifier {
    @EnvironmentObject var store: AppStore
    @Binding var flow: Flow?

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { flow != nil }, set: { if !$0 { flow = nil } }), titleVisibility: .visible) {
            if let f = flow {
                Button("実行する") { Task { await store.runFlow(f) } }
                    .accessibilityIdentifier("flowConfirm.run")
            }
            Button("やめる", role: .cancel) { flow = nil }
        } message: {
            Text(message)
        }
    }

    private var title: String { flow.map { "「\($0.name)」を実行しますか?" } ?? "" }

    private var message: String {
        guard let f = flow else { return "" }
        let what = f.actions.map { FlowText.action($0) }.joined(separator: "→")
        let ask = f.ask ? "\n購入・コードは、このあと通知で確認します。" : ""
        return "\(what)\n上限・回数などの安全装置は通ります。\(ask)"
    }
}

// MARK: - オートメーション(きっかけで実行)

struct AutomationsPane: View {
    @EnvironmentObject var store: AppStore
    @Binding var editing: FlowEditTarget?

    private var automations: [Flow] { store.flows.filter { $0.trigger.kind != .manual } }

    var body: some View {
        VStack(spacing: 10) {
            if automations.isEmpty {
                Card {
                    Text("まだありません。右上の「+」か、ギャラリーから追加できます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(automations) { f in
                AutomationRow(flow: f, editing: $editing)
            }
            Text("povoX が残量を確かめるたび(バックグラウンド更新・アプリ表示中・ショートカット・位置情報)に見ます。時刻と予定のものは、その時刻に通知でお知らせします。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AutomationRow: View {
    @EnvironmentObject var store: AppStore
    let flow: Flow
    @Binding var editing: FlowEditTarget?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { editing = FlowEditTarget(flow: flow, isNew: false) } label: {
                HStack(alignment: .top, spacing: 12) {
                    FlowIcon(symbol: flow.symbol, color: flow.color, size: 42)
                        .opacity(flow.enabled ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(flow.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            if flow.ask && flow.touchesPovo {
                                Image(systemName: "bell.badge").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(FlowText.summary(flow))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                        FlowLastRun(flow: flow, memory: store.flowMemory)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { flow.enabled }, set: { store.setFlowEnabled(flow.id, $0) }))
                .labelsHidden()
                .accessibilityIdentifier("flowToggle.\(flow.galleryID ?? flow.id)")
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: - ギャラリー

struct GalleryPane: View {
    @EnvironmentObject var store: AppStore
    let added: (Flow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(FlowGallery.categories, id: \.self) { cat in
                VStack(alignment: .leading, spacing: 8) {
                    Text(cat).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(FlowGallery.all.filter { $0.category == cat }) { t in
                        GalleryCard(template: t, added: added)
                    }
                }
            }
        }
    }
}

struct GalleryCard: View {
    @EnvironmentObject var store: AppStore
    let template: FlowTemplate
    let added: (Flow) -> Void

    var body: some View {
        let sample = template.make()
        let have = store.flows.contains { $0.galleryID == template.id }
        HStack(alignment: .top, spacing: 12) {
            FlowIcon(symbol: sample.symbol, color: sample.color, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(sample.name).font(.subheadline.weight(.semibold))
                Text(template.blurb).font(.caption).foregroundStyle(.secondary)
                Text(FlowText.summary(sample)).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                added(store.addFromGallery(template))
            } label: {
                Text(have ? "もう1つ" : "追加")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(have ? Color.primary : Color.black)
                    .background(have ? AnyShapeStyle(Theme.groove) : AnyShapeStyle(Theme.yellow), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gallery.add.\(template.id)")
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: - ルール(上級者向け)

struct AdvancedRulesCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationLink { RulesContent() } label: {
            Card {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.groove).frame(width: 46, height: 46)
                        Image(systemName: "curlybraces.square").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ルール(JavaScript)・レシピ・シミュレーター").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(store.ruleEnabled ? "今のルール「\(store.ruleTitle)」もオートメーションと一緒に動いています" : "ルールは止めています(オートメーションだけ)")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flows.rules")
    }
}
