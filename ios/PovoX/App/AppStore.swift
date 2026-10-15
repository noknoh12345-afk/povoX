import Foundation
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case home, activity, rules, codes, settings
}

struct ChallengePage: Identifiable {
    let id = UUID()
    let url: URL
    let label: String
}

/// 画面の状態。povo への操作はエンジン(別スレッド)に任せ、結果だけを持つ。
@MainActor
final class AppStore: ObservableObject {
    @Published var status: EngineStatus?
    @Published var snapshot: Snapshot?
    @Published var insights: UsageInsights?
    @Published var history: [UsageSample] = []
    @Published var catalog: Catalog?
    @Published var codes: [CodeEntry] = []
    @Published var runs: [RunRecord] = []
    @Published var pending: [PendingAction] = []
    @Published var logs: [LogEntry] = []
    @Published var ledger: [LedgerEntry] = []
    @Published var busy: Set<String> = []
    @Published var alert: AlertMessage?
    @Published var toast: String?
    @Published var tab: AppTab = .home
    @Published var challenge: ChallengePage?
    @Published var onboardingDone: Bool
    @Published var rule: String
    @Published var ruleTemplateID: String?
    @Published var ruleRecipeID: String?

    let services: AppServices
    private var foregroundTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(services: AppServices = .shared) {
        self.services = services
        onboardingDone = services.settings.onboardingDone
        rule = RuleLibrary.currentSource(settings: services.settings)
        ruleTemplateID = services.settings.ruleSource == nil ? RuleLibrary.defaultID : services.settings.ruleTemplateID
        ruleRecipeID = services.settings.ruleRecipeID
        if let t = services.launch.tab, let tab = AppTab(rawValue: t) { self.tab = tab }
        observers.append(NotificationCenter.default.addObserver(forName: .povoxDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .povoxOpenRoute, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor in self?.open(info) }
        })
    }

    var client: EngineClient { services.client }
    var loggedIn: Bool { status?.loggedIn == true }
    var mock: Bool { status?.mock ?? services.settings.mockMode }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    private func work<T>(_ key: String, _ body: () async throws -> T) async -> T? {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            return try await body()
        } catch {
            alert = AlertMessage(error)
            return nil
        }
    }

    // MARK: - 読み込み(通信なし)

    func reload() async {
        let c = client
        let r = await c.value { e in
            (e.status(), e.cachedSnapshot(), e.insights(), e.history(hours: 72), e.cachedCatalog(), e.codes(),
             e.runs(limit: 100), e.pendingActions(), e.logs(limit: 200), e.ledger(limit: 100))
        }
        status = r.0
        snapshot = r.1
        insights = r.2
        history = r.3
        catalog = r.4
        codes = r.5
        runs = r.6
        pending = r.7
        logs = r.8
        ledger = r.9
    }

    // MARK: - 残量・一覧(通信あり)

    func refresh(force: Bool = true) async {
        guard loggedIn else { return }
        _ = await work("refresh") { try await client.call { try $0.snapshot(force: force) } }
        await reload()
        await WidgetBridge.update(client: client, lastSummary: runs.first?.summary)
    }

    func loadCatalog(force: Bool) async {
        _ = await work("catalog") { try await client.call { try $0.catalog(force: force) } }
        await reload()
    }

    // MARK: - ログイン

    func loginStart(email: String, phone: String) async -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        let p = phone.trimmingCharacters(in: .whitespaces)
        let step = await work("login") { try await client.call { try $0.loginStart(email: e.isEmpty ? nil : e, phone: p.isEmpty ? nil : p) } }
        await reload()
        if let s = step { toast = "\(s.sent ?? "コード")を送りました" }
        return step != nil
    }

    func loginResend() async {
        if let s = await work("login", { try await client.call { try $0.loginResend() } }) {
            toast = "\(s.sent ?? "コード")を送り直しました"
        }
        await reload()
    }

    func loginOTP(_ code: String) async {
        let step = await work("login") { try await client.call { try $0.loginOtp(code: code) } }
        await reload()
        guard let step else { return }
        if step.done {
            toast = "ログインしました"
            await refresh(force: true)
            await loadCatalog(force: false)
        } else {
            toast = "続けて\(step.sent ?? "次のコード")を入力してください"
        }
    }

    func loginCancel() async {
        await client.value { $0.loginCancel() }
        await reload()
    }

    func logout() async {
        await client.value { $0.logout() }
        await reload()
    }

    func unhalt() async {
        await client.value { $0.unhalt() }
        await reload()
    }

    func setMock(_ on: Bool) async {
        services.setMock(on)
        await reload()
    }

    func finishOnboarding() async {
        if !services.launch.uiTest {
            _ = await services.notifications.requestAuthorization()
        }
        services.settings.onboardingDone = true
        onboardingDone = true
    }

    // MARK: - 購入・コード(手動)

    func order(_ p: Product, confirm: String) async {
        let r = await work("order") { try await client.call { try $0.order(sku: p.sku, confirm: confirm) } }
        await reload()
        guard let r else { return }
        if r.needs3ds, let u = r.challengeUrl.flatMap(URL.init(string:)) {
            challenge = ChallengePage(url: u, label: p.name)
        } else {
            toast = "\(p.name) を注文しました"
            await refresh(force: true)
        }
    }

    func applyCode(id: String? = nil, raw: String? = nil, confirm: String) async {
        let r = await work("code") { try await client.call { try $0.applyCode(id: id, raw: raw, confirm: confirm) } }
        await reload()
        guard let r else { return }
        toast = r.valid ? "適用しました: \(r.title ?? r.masked)" : "受け付けられませんでした: \(r.title ?? "")"
        if r.valid { await refresh(force: true) }
    }

    func addCodes(_ text: String) async -> AddCodesResult {
        let r = await client.value { $0.addCodes(text: text, defaultTag: nil) }
        await reload()
        return r
    }

    func removeCode(_ id: String) async {
        _ = await work("code") { try await client.call { try $0.removeCode(id: id) } }
        await reload()
    }

    func resetCode(_ id: String) async {
        _ = await work("code") { try await client.call { try $0.resetCode(id: id) } }
        await reload()
    }

    func updateCode(_ id: String, tag: String, note: String) async {
        _ = await work("code") { try await client.call { try $0.updateCode(id: id, tag: tag, note: note) } }
        await reload()
    }

    // MARK: - 設定

    func updateSettings(_ change: (inout Settings) -> Void) async {
        guard var s = status?.settings else { return }
        change(&s)
        let target = s
        _ = await client.value { $0.updateSettings(settings: target) }
        await reload()
        let delay = await client.value { $0.nextCheckDelayMin() }
        if !services.launch.uiTest {
            BackgroundScheduler.schedule(afterMinutes: delay, enabled: services.settings.backgroundEnabled)
        }
    }

    func clearLogs() async {
        await client.value { $0.clearLogs() }
        await reload()
    }

    // MARK: - ルール

    /// ルールを確かめて保存する。問題があればその内容を返す(保存しない)。
    func saveRule(_ source: String, templateID: String?) -> String? {
        if let err = RuleEngine.check(rule: source, prelude: RuleLibrary.prelude(), settings: services.settings) {
            return err
        }
        services.settings.ruleSource = source
        services.settings.ruleTemplateID = templateID
        services.settings.ruleRecipeID = nil
        rule = source
        ruleTemplateID = templateID
        ruleRecipeID = nil
        return nil
    }

    /// レシピ(プリセット)を今のルールにする。問題があればその内容を返す。
    func applyRecipe(_ recipe: Recipe) -> String? {
        let source = recipe.rule
        if let err = RuleEngine.check(rule: source, prelude: RuleLibrary.prelude(), settings: services.settings) {
            return err
        }
        services.settings.ruleSource = source
        services.settings.ruleTemplateID = nil
        services.settings.ruleRecipeID = recipe.id
        rule = source
        ruleTemplateID = nil
        ruleRecipeID = recipe.id
        return nil
    }

    var ruleTitle: String {
        if let id = ruleRecipeID, let r = RecipeLibrary.recipe(id) { return r.title }
        if let id = ruleTemplateID, let t = RuleLibrary.template(id) { return t.title }
        return "カスタム"
    }

    // MARK: - 自動チェック

    func runNow(dry: Bool) async -> RunRecord? {
        busy.insert("run")
        defer { busy.remove("run") }
        let r = await services.automation.run(trigger: dry ? "試運転" : "manual", mode: dry ? .dry : .live)
        await reload()
        if let r, !dry {
            toast = r.error.map { "エラー: \($0)" } ?? r.summary
        }
        if r == nil {
            if status?.halted != nil {
                alert = AlertMessage(title: "通信を止めています", message: "安全のため povo への通信を止めています。原因を確認してから「通信を再開」を押してください。")
            } else if !loggedIn {
                alert = AlertMessage(title: "ログインしていません", message: "先にログインしてください。")
            } else {
                toast = "前の自動チェックがまだ動いています"
            }
        }
        return r
    }

    func simulate(_ sim: SimInput, device: DeviceState, trigger: String, rule: String? = nil) async -> RunRecord {
        await services.automation.simulate(sim, device: device, trigger: trigger, rule: rule)
    }

    func confirm(_ p: PendingAction) async {
        let out = await work("pending") { try await client.call { try $0.confirmPending(id: p.id) } }
        services.notifications.removeConfirmation(pendingID: p.id)
        await services.afterChange(summary: out.map { "\($0.label): \($0.message)" })
        guard let out else { return }
        if let u = out.challengeUrl.flatMap(URL.init(string:)) {
            challenge = ChallengePage(url: u, label: out.label)
        } else {
            toast = "\(out.label): \(out.message)"
        }
        await refresh(force: true)
    }

    func dismiss(_ p: PendingAction) async {
        await client.value { $0.dismissPending(id: p.id) }
        services.notifications.removeConfirmation(pendingID: p.id)
        await services.afterChange(summary: nil)
    }

    // MARK: - アプリ表示中の自動チェック

    func startForeground() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
        guard services.settings.foregroundEnabled, !services.launch.uiTest else { return }
        Task {
            let minutes = await client.value { $0.nextCheckDelayMin() }
            let interval = TimeInterval(max(15, minutes)) * 60
            foregroundTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in _ = await self?.services.automation.run(trigger: "foreground") }
            }
            // 長く開いていなかったら、すぐ1回動かす
            if let last = services.settings.lastRun, Date().timeIntervalSince(last) < interval { return }
            _ = await services.automation.run(trigger: "foreground")
        }
    }

    func stopForeground() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    // MARK: - 通知から

    func open(_ info: [AnyHashable: Any]) {
        if let s = info["challenge_url"] as? String, let u = URL(string: s) {
            challenge = ChallengePage(url: u, label: info["label"] as? String ?? "3Dセキュア")
            tab = .home
            return
        }
        if let r = info["route"] as? String, let t = AppTab(rawValue: r) {
            tab = t
        }
    }
}
