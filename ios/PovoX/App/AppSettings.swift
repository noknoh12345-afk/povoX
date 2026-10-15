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

    var backgroundEnabled: Bool {
        get { bool("bg.enabled", true) }
        set { defaults.set(newValue, forKey: "bg.enabled") }
    }

    var foregroundEnabled: Bool {
        get { bool("fg.enabled", true) }
        set { defaults.set(newValue, forKey: "fg.enabled") }
    }

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
