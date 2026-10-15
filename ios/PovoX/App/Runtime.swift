import Foundation

/// 動いている場所と、使える機能を見分ける。
///
/// povoX は iPhone 実機のほか、Mac(PlayCover など)や LiveContainer でも動かせる。
/// それぞれ使えない機能があるので、名前で決め打ちせず「その機能が実際に使えるか」で出し分ける。
/// (LiveContainer: ウィジェットなどの拡張が動かない。Mac: バックグラウンド更新・位置情報が
///  実機とは違う。)
enum Runtime {
    /// Mac で動いている(PlayCover / Apple Silicon の「iPhone 用」実行)。
    static let onMac: Bool = {
        if #available(iOS 14.0, *) {
            if ProcessInfo.processInfo.isiOSAppOnMac { return true }
        }
        return ProcessInfo.processInfo.isMacCatalystApp
    }()

    /// LiveContainer の中で動いている(ゲストアプリとして起動されている)。
    /// 公開情報にある環境変数 `LC_HOME_PATH` を主な手がかりにし、保険でバンドルの場所も見る。
    static let inLiveContainer: Bool = {
        if getenv("LC_HOME_PATH") != nil { return true }
        let path = Bundle.main.bundlePath
        return path.contains("/LiveContainer") || path.contains("/Applications/") && path.contains("/Documents/")
    }()

    /// App Group の共有フォルダが使えるか(ウィジェットが残量を読めるか)。
    /// 署名方法や LiveContainer では使えないことがある。
    static var appGroupAvailable: Bool { SharedSnapshot.containerURL != nil }

    /// バックグラウンド更新(BGTaskScheduler)が使えるか。
    /// Info.plist に識別子があり、Mac でも LiveContainer でもないときだけ。
    static let backgroundTasksAvailable: Bool = {
        if onMac || inLiveContainer { return false }
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return !(ids?.isEmpty ?? true)
    }()

    /// ウィジェットが期待どおり動くか(= App Group が使えて、拡張が動く場所)。
    static var widgetsAvailable: Bool { appGroupAvailable && !inLiveContainer }

    /// 人に見せる、今の環境の短い名前。
    static var label: String {
        if inLiveContainer { return "LiveContainer" }
        if onMac { return "Mac" }
        return "iPhone"
    }

    /// 設定画面などに出す、この環境での注意(無ければ nil)。
    static var caveat: String? {
        if inLiveContainer {
            return "LiveContainer では、ホーム/ロック画面のウィジェットとバックグラウンド更新は動きません。アプリを開いている間の自動チェックと、ショートカット・位置情報での起動を使ってください。"
        }
        if onMac {
            return "Mac ではバックグラウンド更新と位置情報での起動は動きません。アプリを開いている間の自動チェックを使ってください。キーボードで操作できます(⌘1〜5 でタブ、⌘R で更新、⌘Return で今すぐチェック)。"
        }
        return nil
    }
}
