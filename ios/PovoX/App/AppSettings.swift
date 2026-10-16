import Foundation

/// アプリ側だけで使う設定(安全装置の設定はエンジン側 = `Settings`)。
final class AppSettings {
    static var shared = AppSettings(defaults: .standard)

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    /// ルールの本文。未設定なら標準のテンプレート。
    var ruleSource: String? {
        get { defaults.string(forKey: "rule.source") }
        set { defaults.set(newValue, forKey: "rule.source") }
    }

    /// テンプレートから作って手を加えていないときのテンプレート ID。
    var ruleTemplateID: String? {
        get { defaults.string(forKey: "rule.template") }
        set { defaults.set(newValue, forKey: "rule.template") }
    }

    /// レシピから作ったときのレシピ ID(編集・テンプレート選択で消える)。
    var ruleRecipeID: String? {
        get { defaults.string(forKey: "rule.recipe") }
        set { defaults.set(newValue, forKey: "rule.recipe") }
    }

    var backgroundEnabled: Bool {
        get { bool("bg.enabled", true) }
        set { defaults.set(newValue, forKey: "bg.enabled") }
    }

    var foregroundEnabled: Bool {
        get { bool("fg.enabled", true) }
        set { defaults.set(newValue, forKey: "fg.enabled") }
    }

    /// 位置が動いたときに残量チェックを動かす(「常に許可」が要る)。既定はオフ。
    var locationEnabled: Bool {
        get { bool("location.enabled", false) }
        set { defaults.set(newValue, forKey: "location.enabled") }
    }

    /// ルール(JavaScript)も、オートメーションと一緒に動かす。
    var ruleEnabled: Bool {
        get { bool("rule.enabled", true) }
        set { defaults.set(newValue, forKey: "rule.enabled") }
    }

    /// 予定から見積もる使い方の濃さ: 0 控えめ / 1 ふつう / 2 たくさん。
    var usageIntensity: Int {
        get { defaults.object(forKey: "plan.intensity") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "plan.intensity") }
    }

    var intensityFactor: Double { [0.5, 1.0, 1.8][max(0, min(2, usageIntensity))] }

    var notifyErrors: Bool {
        get { bool("notify.errors", true) }
        set { defaults.set(newValue, forKey: "notify.errors") }
    }

    var notifyActions: Bool {
        get { bool("notify.actions", true) }
        set { defaults.set(newValue, forKey: "notify.actions") }
    }

    var onboardingDone: Bool {
        get { bool("onboarding.done", false) }
        set { defaults.set(newValue, forKey: "onboarding.done") }
    }

    var mockMode: Bool {
        get { bool("mock.mode", false) }
        set { defaults.set(newValue, forKey: "mock.mode") }
    }

    var lastRun: Date? {
        get { defaults.object(forKey: "run.last") as? Date }
        set { defaults.set(newValue, forKey: "run.last") }
    }

    /// ルールの `state.get/set` の保存先。
    func scriptState(_ key: String) -> String? {
        (defaults.dictionary(forKey: "rule.state") as? [String: String])?[key]
    }

    func setScriptState(_ key: String, _ value: String) {
        var d = (defaults.dictionary(forKey: "rule.state") as? [String: String]) ?? [:]
        d[key] = value
        if d.count > 200 { d.removeValue(forKey: d.keys.sorted().first ?? key) }
        defaults.set(d, forKey: "rule.state")
    }
}
