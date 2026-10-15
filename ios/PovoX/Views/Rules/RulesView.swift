import SwiftUI

/// ルール: 今のルール・シミュレーター・テンプレート・安全装置のまとめ。
struct RulesView: View {
    @EnvironmentObject var store: AppStore
    @State private var lastRun: RunRecord?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusBanners()
                    Card("今のルール", systemImage: "curlybraces.square", accessory: AnyView(Chip(text: store.ruleTitle, tint: .secondary))) {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.groove.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        HStack(spacing: 10) {
                            NavigationLink { TemplatePickerView() } label: { Text("テンプレート") }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityIdentifier("rules.templates")
                            NavigationLink { RuleEditorView() } label: { Text("編集") }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityIdentifier("rules.edit")
                        }
                    }
                    NavigationLink { SimulatorView() } label: {
                        Card {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.yellow).frame(width: 46, height: 46)
                                    Image(systemName: "slider.horizontal.3").font(.title3.weight(.semibold)).foregroundStyle(.black)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("シミュレーター").font(.headline).foregroundStyle(.primary)
                                    Text("残量・電池・Wi-Fi などを動かして、ルールが何をするかを確かめる(povo には通信しません)")
                                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rules.simulator")

                    Card("今の状態で試す", systemImage: "testtube.2") {
                        Text("本物の残量でルールを動かします。「試運転」は判断を記録するだけで、確認も実行もしません。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                Task { lastRun = await store.runNow(dry: true) }
                            } label: { Text("試運転") }
                                .buttonStyle(SecondaryButtonStyle())
                                .accessibilityIdentifier("rules.dryRun")
                            Button {
                                Task { lastRun = await store.runNow(dry: false) }
                            } label: {
                                if store.isBusy("run") { ProgressView() } else { Text("本番で実行") }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("rules.runLive")
                        }
                        if let r = lastRun {
                            RunResultView(run: r)
                        }
                    }

                    if let s = store.status?.settings {
                        NavigationLink { SafetyView() } label: {
                            Card("安全装置(ルールからは外せません)", systemImage: "shield.lefthalf.filled") {
                                safetyRow("購入", s.purchaseMode.label)
                                safetyRow("コード", s.codeMode.label)
                                safetyRow("月の上限", Fmt.yen(s.monthlyCapYen))
                                safetyRow("1日", "\(s.maxRuleOrdersPerDay)回まで・\(s.orderGapMin)分あける")
                                if s.dryRun { safetyRow("試運転", "オン(記録だけ)") }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    NavigationLink { RuleHelpView() } label: {
                        Label("ルールの書き方", systemImage: "book")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("ルール")
        }
    }

    private var preview: String {
        store.rule.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("// title:") && !$0.hasPrefix("// summary:") }
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    private func safetyRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).fontWeight(.medium).foregroundStyle(.primary)
        }
        .font(.subheadline)
    }
}

/// 1回の実行結果(試運転・シミュレーションの結果表示)。
struct RunResultView: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(run.summary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(run.error != nil ? Theme.danger : .primary)
                .accessibilityIdentifier("run.summary")
            ForEach(Array(run.outcomes.enumerated()), id: \.offset) { _, o in
                OutcomeRow(outcome: o)
            }
            if let e = run.error, e != run.summary {
                Text(e).font(.caption).foregroundStyle(Theme.danger)
            }
            if !run.logs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(run.logs.enumerated()), id: \.offset) { _, l in
                        Text("› \(l)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.groove.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
