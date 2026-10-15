import Foundation

/// レシピ: ルール(JavaScript)を書かずに「選ぶだけ」で使えるプリセット。
///
/// レシピはパラメータだけを持ち、実際のルールはここ(`RecipeCompiler`)が組み立てる。
/// 一覧(数百個)は Resources/recipes.json にあり、`tools/gen-recipes.py` で作る。
/// 安全装置(上限・回数・間隔・3DS 除外)はエンジンが必ずかけるので、レシピは「何をするか」だけ。
struct Recipe: Identifiable, Hashable {
    let id: String
    let category: String
    let title: String
    let summary: String
    let params: RecipeParams

    /// このレシピから作るルール(JavaScript)。
    var rule: String { RecipeCompiler.rule(for: self) }
}

/// レシピのパラメータ(recipes.json の `params`)。
struct RecipeParams: Hashable {
    struct Low: Hashable {
        /// "gb"(残量GB)か "hours"(あと何時間)。
        let kind: String
        let value: Double
    }
    var low: Low?
    var act: [String] = []
    var wifiSkip = false
    var night = false
    var trigger: String?
    var batteryLow: Int?
    var window: [Int]?
    var unlimitedEndingMin: Int?
    var usedTodayMB: Int?
}

enum RecipeLibrary {
    /// recipes.json を読む。
    static func all(in bundle: Bundle = .main) -> [Recipe] {
        guard let url = bundle.url(forResource: "recipes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["recipes"] as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    static func categoryOrder(in bundle: Bundle = .main) -> [String] {
        guard let url = bundle.url(forResource: "recipes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let order = root["categoryOrder"] as? [String] else { return [] }
        return order
    }

    /// カテゴリ名 → そのレシピ(一覧の順を保つ)。
    static func grouped(in bundle: Bundle = .main) -> [(category: String, recipes: [Recipe])] {
        let recipes = all(in: bundle)
        var map: [String: [Recipe]] = [:]
        for r in recipes { map[r.category, default: []].append(r) }
        let order = categoryOrder(in: bundle)
        let cats = order.isEmpty ? Array(map.keys).sorted() : order
        return cats.compactMap { c in map[c].map { (c, $0) } }
    }

    static func recipe(_ id: String, in bundle: Bundle = .main) -> Recipe? {
        all(in: bundle).first { $0.id == id }
    }

    private static func parse(_ d: [String: Any]) -> Recipe? {
        guard let id = d["id"] as? String, let cat = d["category"] as? String,
              let title = d["title"] as? String, let p = d["params"] as? [String: Any] else { return nil }
        var params = RecipeParams()
        if let low = p["low"] as? [String: Any], let kind = low["kind"] as? String,
           let value = (low["value"] as? NSNumber)?.doubleValue {
            params.low = .init(kind: kind, value: value)
        }
        params.act = (p["act"] as? [String]) ?? []
        params.wifiSkip = (p["wifiSkip"] as? Bool) ?? false
        params.night = (p["night"] as? Bool) ?? false
        params.trigger = p["trigger"] as? String
        params.batteryLow = (p["batteryLow"] as? NSNumber)?.intValue
        params.window = (p["window"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
        params.unlimitedEndingMin = (p["unlimitedEndingMin"] as? NSNumber)?.intValue
        params.usedTodayMB = (p["usedTodayMB"] as? NSNumber)?.intValue
        return Recipe(id: id, category: cat, title: title, summary: (d["summary"] as? String) ?? "", params: params)
    }
}
