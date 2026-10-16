import AppIntents
import Foundation

/// ショートカット: 自動チェックを1回動かす(オートメーションのきっかけに使う)。
struct RunCheckIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXの自動チェック"
    static var description = IntentDescription("povo の残量を取得し、povoX のルールを実行します。購入・コードは povoX の安全装置(確認・上限)の範囲だけで行います。")
    static var openAppWhenRun = false

    @Parameter(title: "きっかけ", description: "ルールの ctx.trigger に入る文字(例: battery-low)", default: "shortcut")
    var trigger: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        guard let record = await services.automation.run(trigger: trigger.isEmpty ? "shortcut" : trigger) else {
            let st = await services.client.value { $0.status() }
            let why = !st.loggedIn ? "ログインしていません" : (st.halted != nil ? "安全のため通信を止めています。アプリで確認してください" : "別の自動チェックが動いています")
            return .result(value: why, dialog: IntentDialog(stringLiteral: why))
        }
        let text = record.error.map { "エラー: \($0)" } ?? record.summary
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// ショートカット: データ残量(GB)を返す。
struct RemainingDataIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXのデータ残量"
    static var description = IntentDescription("povo のデータ残量を GB で返します(30秒以内に取得していればその値)。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let client = AppServices.shared.client
        do {
            let snap = try await client.call { try $0.snapshot(force: false) }
            guard let kb = snap.leftKb else { throw IntentFailure(message: "残量を読めませんでした") }
            let gb = (kb / Fmt.kbPerGB * 100).rounded() / 100
            let suffix = snap.unlimited.active == true ? "(使い放題中)" : ""
            return .result(value: gb, dialog: IntentDialog(stringLiteral: "残り \(Fmt.data(kb: kb))\(suffix)"))
        } catch let e as PovoXError {
            throw IntentFailure(message: e.message)
        }
    }
}

enum PurchaseModeOption: String, AppEnum {
    case off, confirm, auto

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "購入のしかた"
    static var caseDisplayRepresentations: [PurchaseModeOption: DisplayRepresentation] = [
        .off: "しない",
        .confirm: "通知で確認",
        .auto: "自動",
    ]

    var mode: ActionMode {
        switch self {
        case .off: return .off
        case .confirm: return .confirm
        case .auto: return .auto
        }
    }

    var label: String {
        switch self {
        case .off: return "しない"
        case .confirm: return "通知で確認"
        case .auto: return "自動"
        }
    }
}

/// ショートカット: ルールによる購入のしかたを切り替える(例: 旅行中だけ自動にする)。
struct SetPurchaseModeIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXの購入のしかたを変える"
    static var description = IntentDescription("ルールによるトッピング購入を「しない / 通知で確認 / 自動」に切り替えます。")
    static var openAppWhenRun = false

    @Parameter(title: "購入のしかた", default: .confirm)
    var mode: PurchaseModeOption

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = AppServices.shared.client
        let target = mode.mode
        _ = await client.value { e -> Settings in
            var s = e.settings()
            s.purchaseMode = target
            return e.updateSettings(settings: s)
        }
        await MainActor.run { NotificationCenter.default.post(name: .povoxDidChange, object: nil) }
        return .result(dialog: IntentDialog(stringLiteral: "ルールによる購入を「\(mode.label)」にしました"))
    }
}

// MARK: - オートメーション(内蔵のショートカット)をショートカット App・Siri から

/// povoX のオートメーション(ショートカット App で選べる形)。
struct FlowEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "povoXのオートメーション"
    static var defaultQuery = FlowEntityQuery()

    var id: String
    var name: String
    var summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    init(_ f: Flow) {
        id = f.id
        name = f.name
        summary = FlowText.summary(f)
    }
}

struct FlowEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FlowEntity] {
        let list = AppServices.shared.flows.flows()
        return identifiers.compactMap { id in list.first { $0.id == id }.map(FlowEntity.init) }
    }

    func suggestedEntities() async throws -> [FlowEntity] {
        // ボタンで実行するものを先に
        AppServices.shared.flows.flows()
            .sorted { ($0.trigger.kind == .manual ? 0 : 1, $0.createdMs) < ($1.trigger.kind == .manual ? 0 : 1, $1.createdMs) }
            .map(FlowEntity.init)
    }
}

/// ショートカット: povoX のオートメーションを1つ実行する(きっかけは見ない。条件と安全装置は通る)。
struct RunFlowIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXのオートメーションを実行"
    static var description = IntentDescription("povoX に作ったオートメーション(例: 1時間使い放題・いってきます)を実行します。購入は povoX の設定・上限の範囲だけで行います。")
    static var openAppWhenRun = false
    // お金が動くことがあるので、ロック中は解除してから
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "オートメーション")
    var flow: FlowEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        guard let record = await services.automation.run(trigger: "flow:\(flow.id)") else {
            let st = await services.client.value { $0.status() }
            let why = !st.loggedIn ? "ログインしていません" : (st.halted != nil ? "安全のため通信を止めています。アプリで確認してください" : "別の自動チェックが動いています")
            return .result(value: why, dialog: IntentDialog(stringLiteral: why))
        }
        let text = record.error.map { "エラー: \($0)" } ?? record.summary
        return .result(value: text, dialog: IntentDialog(stringLiteral: "\(flow.name): \(text)"))
    }
}

/// ショートカット: 今日(夕方からは明日)のプランを返す。
struct DayPlanIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXの今日のプラン"
    static var description = IntentDescription("カレンダーの予定と残量から、今日(18時からは明日)の外出に足りるか・何をしておくと楽かを返します。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        guard let f = await services.planFacts() else { throw IntentFailure(message: "ログインしていません") }
        guard f.calendarAuthorized else { throw IntentFailure(message: "povoX でカレンダーを許可してください") }
        let b = DayPlanner.brief(day: "auto", facts: f)
        let text = b.map { "\($0.title.replacingOccurrences(of: "povoX: ", with: "")): \($0.body)" } ?? "プランを作れませんでした"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

struct PovoXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunCheckIntent(),
                    phrases: ["\(.applicationName)で自動チェック", "\(.applicationName)をチェック"],
                    shortTitle: "自動チェック",
                    systemImageName: "bolt.fill")
        AppShortcut(intent: RemainingDataIntent(),
                    phrases: ["\(.applicationName)の残量", "\(.applicationName)であと何ギガ"],
                    shortTitle: "データ残量",
                    systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(intent: DayPlanIntent(),
                    phrases: ["\(.applicationName)の今日のプラン", "\(.applicationName)で今日の予定を確認"],
                    shortTitle: "今日のプラン",
                    systemImageName: "calendar.badge.checkmark")
    }
}
