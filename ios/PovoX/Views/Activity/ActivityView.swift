import SwiftUI

/// 自動チェックの記録・注文の記録・ログ。
struct ActivityView: View {
    @EnvironmentObject var store: AppStore
    @State private var segment = 0

    var body: some View {
        NavigationStack {
            List {
                if !store.pending.isEmpty {
                    Section("確認待ち") {
                        ForEach(store.pending) { p in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(p.label).font(.headline)
                                Text(p.detail).font(.caption).foregroundStyle(.secondary)
                                Text("\(Fmt.when(ms: p.expiresMs)) まで有効").font(.caption2).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Button("やめる") { Task { await store.dismiss(p) } }
                                        .buttonStyle(SecondaryButtonStyle())
                                    Button("実行する") { Task { await store.confirm(p) } }
                                        .buttonStyle(PrimaryButtonStyle())
                                        .accessibilityIdentifier("activity.execute")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    Picker("表示", selection: $segment) {
                        Text("自動チェック").tag(0)
                        Text("注文").tag(1)
                        Text("ログ").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch segment {
                case 0: runs
                case 1: orders
                default: logs
                }
            }
            .textCase(nil)
            .navigationTitle("履歴")
            .refreshable { await store.reload() }
            .toolbar {
                if segment == 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("消去") { Task { await store.clearLogs() } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var runs: some View {
        Section {
            if store.runs.isEmpty {
                Text("まだありません。ホームの「今すぐチェック」か、バックグラウンド更新・ショートカットで記録されます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.runs) { r in
                NavigationLink {
                    RunDetailView(run: r)
                } label: {
                    RunRow(run: r)
                }
            }
        }
    }

    @ViewBuilder private var orders: some View {
        Section {
            if store.ledger.isEmpty {
                Text("まだありません。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.ledger, id: \.self) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(e.name ?? e.sku).font(.subheadline.weight(.medium))
                        Spacer()
                        if let p = e.priceYen { Text(Fmt.yen(p)).font(.subheadline).monospacedDigit() }
                    }
                    HStack(spacing: 6) {
                        Chip(text: e.source == .rule ? "ルール" : "手動", tint: e.source == .rule ? Theme.warn : .secondary)
                        Chip(text: ledgerLabel(e.status), tint: e.status == .ok ? Theme.ok : (e.status == .error ? Theme.danger : .secondary))
                        Spacer()
                        Text(Fmt.when(ms: e.timeMs)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let m = e.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 2)
            }
        } footer: {
            if let b = store.status?.budget {
                Text("今月: ルールによる購入 \(Fmt.yen(b.ruleSpentYen)) / 上限 \(Fmt.yen(b.capYen))(手動を含む合計 \(Fmt.yen(b.allSpentYen)))")
            }
        }
    }

    @ViewBuilder private var logs: some View {
        Section {
            ForEach(Array(store.logs.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(l.level)).foregroundStyle(color(l.level)).font(.caption).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.message).font(.caption)
                        Text(Fmt.when(ms: l.timeMs)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ledgerLabel(_ s: LedgerStatus) -> String {
        switch s {
        case .ok: return "注文完了"
        case .needs3ds: return "3DS待ち"
        case .error: return "失敗(要確認)"
        case .sent: return "結果不明"
        }
    }

    private func icon(_ l: LogLevel) -> String {
        switch l {
        case .action: return "bolt.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "circle.fill"
        }
    }

    private func color(_ l: LogLevel) -> Color {
        switch l {
        case .action: return Theme.warn
        case .warn: return .yellow
        case .error: return Theme.danger
        case .info: return .secondary
        }
    }
}

struct RunRow: View {
    let run: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(run.iconTint.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: run.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(run.iconTint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(run.summary).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    Text(Fmt.when(ms: run.startedMs))
                    Text("・")
                    Text(RunText.trigger(run.trigger))
                    if run.mode == .dry { Text("・試運転") }
                    if let l = run.leftKb { Text("・残り\(Fmt.data(kb: l))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RunDetailView: View {
    let run: RunRecord

    var body: some View {
        List {
            Section("結果") {
                Text(run.summary).font(.headline)
                if let e = run.error {
                    Text(e).font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
            }
            if !run.outcomes.isEmpty {
                Section("ルールの判断と安全装置") {
                    ForEach(Array(run.outcomes.enumerated()), id: \.offset) { _, o in
                        OutcomeRow(outcome: o)
                    }
                }
            }
            Section("そのときの状態") {
                LabeledContent("きっかけ", value: RunText.trigger(run.trigger))
                LabeledContent("時刻", value: Fmt.when(ms: run.startedMs))
                if let l = run.leftKb { LabeledContent("残り", value: Fmt.data(kb: l)) }
                if let u = run.unlimited { LabeledContent("使い放題", value: u ? "中" : "なし") }
                LabeledContent("電池", value: run.batteryLevel.map { "\($0)%\(run.charging ? "(充電中)" : "")" } ?? "不明")
                LabeledContent("ネットワーク", value: NetworkText.label(run.network))
            }
            if !run.logs.isEmpty {
                Section("ルールのログ") {
                    ForEach(Array(run.logs.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("自動チェック")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct OutcomeRow: View {
    let outcome: ActionOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.status.icon).foregroundStyle(outcome.status.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(outcome.label).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(outcome.status.label).font(.caption.weight(.semibold)).foregroundStyle(outcome.status.tint)
                }
                if !outcome.message.isEmpty && outcome.message != outcome.label {
                    Text(outcome.message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum NetworkText {
    static func label(_ n: String) -> String {
        switch n {
        case "wifi": return "Wi-Fi"
        case "cellular": return "モバイル通信"
        case "wired": return "有線"
        case "none": return "圏外"
        default: return "不明"
        }
    }
}
