import SwiftUI

/// レシピ: 書かずに「選ぶだけ」で使えるプリセット(数百)。カテゴリ → 一覧 → 下見 → 使う。
struct RecipePickerView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""

    private var groups: [(category: String, recipes: [Recipe])] { RecipeLibrary.grouped() }
    private var total: Int { groups.reduce(0) { $0 + $1.recipes.count } }

    private var hits: [Recipe] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return RecipeLibrary.all().filter { $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    ForEach(groups, id: \.category) { g in
                        NavigationLink {
                            RecipeListView(category: g.category, recipes: g.recipes)
                        } label: {
                            HStack {
                                Image(systemName: icon(for: g.category)).foregroundStyle(Theme.accent).frame(width: 26)
                                Text(g.category)
                                Spacer()
                                Text("\(g.recipes.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .accessibilityIdentifier("recipeCat.\(g.category)")
                    }
                } header: {
                    Text("カテゴリ")
                } footer: {
                    Text("全 \(total) 個のレシピから選べます。選ぶ前に「下見」で何をするか確かめられます。安全装置(上限・回数・間隔・3DS除外)は必ずかかります。")
                }
            } else {
                Section("「\(query)」の結果 \(hits.count) 件") {
                    ForEach(hits) { r in
                        NavigationLink { RecipeDetailView(recipe: r) } label: { RecipeRow(recipe: r) }
                    }
                }
            }
        }
        .navigationTitle("レシピ")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "レシピを探す")
    }

    private func icon(for category: String) -> String {
        switch category {
        case "残量ライン": return "gauge.with.dots.needle.33percent"
        case "なくなる前に": return "hourglass"
        case "夜は買わない": return "moon.stars"
        case "電池を節約": return "battery.25"
        case "Wi-Fiが切れたら": return "wifi.slash"
        case "時間帯で動く": return "clock"
        case "使い放題の見張り": return "infinity"
        case "使いすぎを見張る": return "chart.line.uptrend.xyaxis"
        case "知らせるだけ": return "bell"
        default: return "square.grid.2x2"
        }
    }
}

struct RecipeListView: View {
    let category: String
    let recipes: [Recipe]

    var body: some View {
        List {
            ForEach(recipes) { r in
                NavigationLink { RecipeDetailView(recipe: r) } label: { RecipeRow(recipe: r) }
                    .accessibilityIdentifier("recipe.\(r.id)")
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecipeRow: View {
    @EnvironmentObject var store: AppStore
    let recipe: Recipe

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.ruleRecipeID == recipe.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(store.ruleRecipeID == recipe.id ? Theme.ok : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(recipe.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecipeDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let recipe: Recipe
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recipe.category).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(recipe.title).font(.title3.weight(.bold))
                    Text(recipe.summary).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                NavigationLink {
                    SimulatorView(ruleOverride: recipe.rule, overrideTitle: recipe.title)
                } label: {
                    Label("下見する(シミュレーターで試す)", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("recipe.preview")

                Button {
                    confirm = true
                } label: {
                    if store.ruleRecipeID == recipe.id {
                        Label("今のルールです", systemImage: "checkmark").frame(maxWidth: .infinity)
                    } else {
                        Text("このレシピを使う").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.ruleRecipeID == recipe.id)
                .accessibilityIdentifier("recipe.use")

                DisclosureGroup("作られるルール(JavaScript)を見る") {
                    Text(recipe.rule)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.groove.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .font(.footnote)

                Text("選んだあとも「ルール → 編集」で数字や条件を自由に変えられます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("レシピ")
        .navigationBarTitleDisplayMode(.inline)
        .alert("このレシピを使いますか?", isPresented: $confirm) {
            Button("使う") {
                if let err = store.applyRecipe(recipe) {
                    store.alert = AlertMessage(title: "設定できませんでした", message: err)
                } else {
                    store.toast = "「\(recipe.title)」にしました"
                    dismiss()
                }
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("今のルールは置き換わります(あとで変えられます)。")
        }
    }
}
