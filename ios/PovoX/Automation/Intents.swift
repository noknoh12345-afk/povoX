import AppIntents
import Foundation

/// ショートカット用: 自動チェック(スクリプト)を1回動かす。
struct RunCheckIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXの自動チェック"
    static var description = IntentDescription("povo の残量を取得し、povoX のルール(スクリプト)を実行します。購入・コード適用は povoX の安全装置の範囲内だけで行います。")
    static var openAppWhenRun = false

    @Parameter(title: "きっかけ", description: "スクリプトの ctx.trigger に入る文字(例: battery-low)", default: "shortcut")
    var trigger: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let report = await Automation.shared.run(trigger: trigger.isEmpty ? "shortcut" : trigger)
        let text = report.ok ? report.summary : "エラー: \(report.summary)"
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// ショートカット用: データ残量(GB)を返す。
struct RemainingDataIntent: AppIntent {
    static var title: LocalizedStringResource = "povoXのデータ残量"
    static var description = IntentDescription("povo のデータ残量を GB で返します(30秒以内に取得していればその値)。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let result: Result<Snapshot, CoreError> = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: Core.shared.decode("snapshot", ["force": false], as: Snapshot.self))
            }
        }
        switch result {
        case .success(let s):
            guard let gb = s.leftGB else {
                throw IntentFailure(message: "残量を読めませんでした")
            }
            let unl = s.unlimitedActive == true ? "(使い放題中)" : ""
            return .result(value: (gb * 100).rounded() / 100,
                           dialog: IntentDialog(stringLiteral: String(format: "残り %.2fGB", gb) + unl))
        case .failure(let e):
            throw IntentFailure(message: e.message)
        }
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
    }
}
