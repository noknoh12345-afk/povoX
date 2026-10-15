import SwiftUI

/// 料金最適化: この先◯時間を、最小の金額でまかなう買い方。設定なしで自動で出る。
struct OptimizeView: View {
    @EnvironmentObject var store: AppStore
    @State private var horizon: UInt32 = 24
    @State private var plan: OptimizePlan?
    @State private var showShop = false

    private let choices: [(UInt32, String)] = [(6, "6時間"), (24, "24時間"), (72, "3日")]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("期間", selection: $horizon) {
                    ForEach(choices, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)

                if let p = plan {
                    OptimizeResult(plan: p)
                    if p.best != nil {
                        Button { showShop = true } label: { Text("ショップで買う").frame(maxWidth: .infinity) }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("optimize.shop")
                    }
                    if store.catalog == nil {
                        Button("トッピング一覧を読み込む(povo に1回通信)") { Task { await reload(force: true) } }
                            .font(.callout)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("最安の買い方")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showShop) { ShopView() }
        .task(id: horizon) { await reload(force: false) }
    }

    private func reload(force: Bool) async {
        if force || store.catalog == nil { await store.loadCatalog(force: force) }
        plan = await store.optimize(horizon: horizon)
    }
}

/// Home に自動で出る「最安の買い方」カード。設定なしで、足りなくなりそうなときだけ出る。
struct HomeOptimizeCard: View {
    @EnvironmentObject var store: AppStore
    @State private var plan: OptimizePlan?

    var body: some View {
        Group {
            if let p = plan, !p.covered, let best = p.best {
                NavigationLink { OptimizeView() } label: {
                    Card("最安の買い方", systemImage: "sparkles",
                         accessory: AnyView(Chip(text: Fmt.yen(best.totalYen), tint: Theme.accent))) {
                        HStack(spacing: 8) {
                            Image(systemName: best.items.first?.kind == "unlimited" ? "infinity" : "square.stack.3d.up")
                                .foregroundStyle(Theme.accent)
                            Text(best.label).font(.subheadline).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        if p.codesOnHand > 0 {
                            Text("手持ちコード \(p.codesOnHand) 枚を先に試すと、もっと安いかも")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.optimize")
            }
        }
        .task(id: store.snapshot?.fetchedMs) {
            guard store.loggedIn, store.catalog != nil else { return }
            plan = await store.optimize(horizon: 24)
        }
    }
}

/// 最適化の結果の中身(Home のカードからも使う)。
struct OptimizeResult: View {
    @EnvironmentObject var store: AppStore
    let plan: OptimizePlan

    var body: some View {
        VStack(spacing: 12) {
            if plan.covered {
                Card {
                    Label(plan.note ?? "この先は追加購入なしで足ります。", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.ok)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let best = plan.best {
                Card("おすすめ(最安)", systemImage: "sparkles") {
                    if let need = plan.neededMb, need > 0 {
                        Text("この先\(plan.horizonHours)時間で、あと約 \(Fmt.data(kb: need * 1024)) 足りません。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(best.label).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Fmt.yen(best.totalYen)).font(.title3.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                    ForEach(Array(best.items.enumerated()), id: \.offset) { _, it in
                        HStack {
                            Image(systemName: it.kind == "unlimited" ? "infinity" : "square.stack.3d.up")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(it.qty > 1 ? "\(it.name) ×\(it.qty)" : it.name).font(.caption)
                            Spacer()
                            Text(Fmt.yen(it.priceYen * it.qty)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !best.withinBudget {
                        Label("今月の上限(残り \(Fmt.yen(plan.budgetRemainingYen)))を超えます", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let note = plan.note {
                        Text(note).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Card {
                    Label(plan.note ?? "最安の買い方を計算できませんでした。", systemImage: "questionmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 比較: ほかの候補
            let others = plan.options.filter { $0.label != plan.best?.label }
            if !others.isEmpty {
                Card("ほかの選択肢", systemImage: "list.bullet") {
                    ForEach(Array(others.enumerated()), id: \.offset) { _, o in
                        HStack {
                            Text(o.label).font(.caption)
                            if !o.covers { Text("まかなえない").font(.caption2).foregroundStyle(.orange) }
                            Spacer()
                            Text(Fmt.yen(o.totalYen)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if plan.codesOnHand > 0 {
                Label("手持ちのコード \(plan.codesOnHand) 枚を先に試すと、もっと安くなるかも", systemImage: "ticket")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
