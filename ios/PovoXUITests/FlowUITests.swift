import XCTest

/// シミュレータで本物のアプリを操作し、各画面を確かめてスクリーンショットを残す。
/// povo には通信しない(モック)。スクリーンショットは環境変数 SHOT_DIR(xcodebuild の TEST_RUNNER_SHOT_DIR)に保存する。
final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + (reset ? ["-reset"] : []) + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        // アニメーションが落ち着くのを少し待つ
        Thread.sleep(forTimeInterval: 0.8)
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @discardableResult
    private func wait(_ e: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "見つからない: \(e)", file: file, line: line)
        return e
    }

    private func login(_ app: XCUIApplication, screenshots: Bool = false) {
        let email = wait(app.textFields["login.email"])
        if screenshots { shot(app, "02-login") }
        email.tap()
        // 改行で送信(キーボードでボタンが隠れても進めるように)
        email.typeText("demo@example.com\n")
        if !app.textFields["login.code"].waitForExistence(timeout: 5) {
            app.buttons["login.send"].tap()
        }
        let code = wait(app.textFields["login.code"])
        code.tap()
        code.typeText("000000")
        if screenshots { shot(app, "03-login-code") }
        app.buttons["login.submit"].tap()
        wait(app.buttons["home.runNow"], 20)
    }

    private func tab(_ app: XCUIApplication, _ label: String) {
        app.tabBars.buttons[label].tap()
    }

    // 1. 初回の案内 → ログイン → ホーム → 自動チェック(確認待ち)→ 実行 → 履歴
    func test1_OnboardingLoginAndConfirmFlow() {
        let app = launch(["-mockScenario", "low", "-deviceBattery", "15", "-deviceNetwork", "cellular"])
        wait(app.buttons["onboarding.next"])
        shot(app, "01-onboarding-1")
        app.buttons["onboarding.next"].tap()
        app.buttons["onboarding.next"].tap()
        wait(app.buttons["onboarding.start"])
        shot(app, "01-onboarding-3")
        app.buttons["onboarding.start"].tap()

        login(app, screenshots: true)
        shot(app, "04-home-low")

        // 自動チェック: 残りわずか・電池15% → 1時間の使い放題を「確認待ち」にするはず
        app.buttons["home.runNow"].tap()
        let execute = wait(app.buttons["pending.execute"], 20)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1時間")).firstMatch.exists)
        shot(app, "05-home-pending")
        execute.tap()
        // 実行後は使い放題中になる
        wait(app.staticTexts["使い放題中"], 20)
        shot(app, "06-home-unlimited")
        app.swipeUp()
        shot(app, "07-home-scrolled")

        tab(app, "履歴")
        wait(app.navigationBars["履歴"])
        shot(app, "08-activity")
        app.cells.element(boundBy: 1).tap()
        shot(app, "09-run-detail")
    }

    // 2. ルール: シミュレーター・テンプレート・エディタ
    func test2_RulesSimulatorEditor() {
        let app = launch(["-skipOnboarding", "-deviceBattery", "80", "-deviceNetwork", "cellular"])
        login(app)
        shot(app, "10-home-normal")
        tab(app, "ルール")
        wait(app.buttons["rules.simulator"])
        shot(app, "11-rules")
        app.buttons["rules.dryRun"].tap()
        wait(app.staticTexts["run.summary"], 20)
        shot(app, "12-rules-dryrun")

        app.buttons["rules.simulator"].tap()
        wait(app.buttons["sim.run"])
        shot(app, "13-simulator")
        app.buttons["sim.run"].tap()
        let summary = wait(app.staticTexts["run.summary"], 20)
        XCTAssertTrue(summary.label.contains("1時間") || summary.label.contains("見送り") || summary.label.contains("通知"), summary.label)
        app.swipeUp()
        shot(app, "14-simulator-result")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["rules.templates"].tap()
        wait(app.buttons["template.standard"])
        shot(app, "15-templates")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["rules.edit"].tap()
        wait(app.textViews["editor.text"])
        shot(app, "16-editor")
    }

    // 3. コード・トッピング・設定・ウィジェット
    func test3_CodesShopSettings() {
        let app = launch(["-skipOnboarding"])
        login(app)

        tab(app, "コード")
        shot(app, "17-codes-empty")
        app.buttons["codes.empty.add"].tap()
        let text = wait(app.textViews["codes.text"])
        text.tap()
        text.typeText("MOCKOK1 1gb 7日間\nMOCKUNL1H 1h 使い放題\nMOCKOK2")
        shot(app, "18-codes-add")
        app.buttons["codes.save"].tap()
        wait(app.staticTexts["1gb"], 10)
        shot(app, "19-codes-list")

        tab(app, "ホーム")
        app.buttons["home.shop"].tap()
        wait(app.buttons["shop.MOCK_UNLIMITED_1H"], 20)
        shot(app, "20-shop")
        app.buttons["shop.MOCK_UNLIMITED_1H"].tap()
        wait(app.alerts.firstMatch)
        shot(app, "21-shop-confirm")
        app.alerts.buttons["やめる"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tab(app, "設定")
        wait(app.navigationBars["設定"])
        shot(app, "22-settings")
        app.staticTexts["上限・回数・間隔"].tap()
        shot(app, "23-safety")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["自動チェックのきっかけ"].tap()
        shot(app, "24-triggers")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        let gallery = app.staticTexts["ウィジェットの見た目(開発用)"]
        if gallery.waitForExistence(timeout: 3) {
            gallery.tap()
            shot(app, "25-widgets")
        }
    }

    // 5. 通知の「実行する」ボタン(ロック画面・バナーから実行する流れ)
    func test5_NotificationConfirm() {
        let app = launch(["-skipOnboarding", "-uitestNotifications", "-mockScenario", "low", "-deviceBattery", "15", "-deviceNetwork", "cellular"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["許可", "Allow"])).firstMatch
        if allow.waitForExistence(timeout: 10) {
            shot(app, "40-notification-permission")
            allow.tap()
        }
        login(app)
        app.buttons["home.runNow"].tap()
        // 確認の通知(アプリを開いていてもバナーで出る)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "購入しますか")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "確認の通知が出ない")
        shot(app, "41-notification-banner")
        banner.press(forDuration: 1.5)
        let execute = springboard.buttons["実行する"]
        XCTAssertTrue(execute.waitForExistence(timeout: 10), "通知のボタンが出ない")
        shot(app, "42-notification-actions")
        execute.tap()
        // アプリ側: 確認待ちが消え、使い放題中になる
        XCTAssertTrue(app.staticTexts["使い放題中"].waitForExistence(timeout: 25), "通知から実行されていない")
        XCTAssertFalse(app.buttons["pending.execute"].exists)
        shot(app, "43-after-notification")
        // 結果の通知(「購入しました」)
        let done = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "購入しました")).firstMatch
        if done.waitForExistence(timeout: 10) {
            shot(app, "44-result-notification")
        }
    }

    // 4. ダークモード
    func test4_DarkMode() {
        let app = launch(["-skipOnboarding", "-forceDark", "-mockScenario", "low", "-deviceBattery", "60"])
        login(app)
        shot(app, "30-dark-home")
        app.buttons["home.runNow"].tap()
        wait(app.buttons["pending.execute"], 20)
        shot(app, "31-dark-pending")
        tab(app, "ルール")
        shot(app, "32-dark-rules")
        tab(app, "履歴")
        shot(app, "33-dark-activity")
    }
}
