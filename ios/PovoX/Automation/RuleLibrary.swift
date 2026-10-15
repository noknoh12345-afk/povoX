import Foundation

/// ルールのテンプレート(Resources/templates/*.js)と下ごしらえ(rule-prelude.js)。
struct RuleTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let source: String
}

enum RuleLibrary {
    static let templateIDs = ["standard", "codes-only", "forecast", "night-guard", "notify-only"]
    static let defaultID = "standard"

    static func resource(_ name: String, in bundle: Bundle = .main) -> String? {
        let url = bundle.url(forResource: name, withExtension: "js")
            ?? bundle.url(forResource: name, withExtension: "js", subdirectory: "templates")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static func prelude(in bundle: Bundle = .main) -> String {
        resource("rule-prelude", in: bundle) ?? ""
    }

    static func templates(in bundle: Bundle = .main) -> [RuleTemplate] {
        templateIDs.compactMap { id in resource(id, in: bundle).map { parse(id: id, source: $0) } }
    }

    static func template(_ id: String, in bundle: Bundle = .main) -> RuleTemplate? {
        resource(id, in: bundle).map { parse(id: id, source: $0) }
    }

    /// 先頭の「// title: …」「// summary: …」を読む。
    static func parse(id: String, source: String) -> RuleTemplate {
        var title = id
        var summary = ""
        for line in source.split(separator: "\n").prefix(5) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// title:") { title = String(t.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("// summary:") { summary = String(t.dropFirst(11)).trimmingCharacters(in: .whitespaces) }
        }
        return RuleTemplate(id: id, title: title, summary: summary, source: source)
    }

    /// 今のルール(未設定なら標準テンプレート)。
    static func currentSource(settings: AppSettings = .shared, bundle: Bundle = .main) -> String {
        if let s = settings.ruleSource, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        return template(defaultID, in: bundle)?.source ?? ""
    }
}
