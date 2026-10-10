//
//  TaskHubUITests.swift
//  TaskHubUITests
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import XCTest

@MainActor
final class TaskHubUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    }

    private func tapVisible(_ element: XCUIElement, maxSwipes: Int = 18) {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable && app.frame.insetBy(dx: 0, dy: 70).contains(element.frame.center) {
                let label = element.staticTexts.firstMatch
                if label.exists && label.isHittable { label.tap() }
                else { element.tap() }
                return
            }
            app.swipeUp()
        }
        XCTFail("操作対象が画面内に見つからない: \(element)")
    }

    private func openSection(_ title: String) {
        let tab = app.tabBars.buttons[title]
        if tab.exists { tab.tap(); return }
        let sidebar = app.buttons["サイドバー"]
        if sidebar.exists && !app.staticTexts[title].isHittable { sidebar.tap() }
        let item = app.descendants(matching: .any).matching(identifier: "section-\(title)").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    private func sample() {
        app.launch()
        tapVisible(app.buttons["サンプルを見る"])
        XCTAssertTrue(app.navigationBars["ユーザー裁定"].waitForExistence(timeout: 5))
    }

    private func search(_ value: String) {
        let field = app.textFields["タイトル・本文・追記・添付を検索"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(value)
        let close = app.buttons["キーボードを閉じる"]
        if close.exists { close.tap() }
        else { field.typeText("\n") }
    }

    func testSearchClearTaskEvidenceAndAttachment() {
        sample()
        openSection("タスク")
        search("evidence.txt")
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-'")).firstMatch
        tapVisible(task)
        XCTAssertTrue(app.navigationBars["タスク詳細"].waitForExistence(timeout: 5))
        tapVisible(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'")).firstMatch)
        XCTAssertTrue(app.navigationBars["添付"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["取得してプレビュー"])
        XCTAssertTrue(app.staticTexts["empty-file-preview"].waitForExistence(timeout: 5))
        app.navigationBars["添付"].buttons.element(boundBy: 0).tap()
        app.navigationBars["タスク詳細"].buttons.element(boundBy: 0).tap()
        for _ in 0..<8 { if app.buttons["検索をクリア"].isHittable { break }; app.swipeDown() }
        app.buttons["検索をクリア"].tap()
        search("該当しない文字列xyz")
        XCTAssertTrue(app.staticTexts["一致する項目なし"].waitForExistence(timeout: 3))
        tapVisible(app.buttons["条件を解除"])
        XCTAssertFalse(app.staticTexts["一致する項目なし"].exists)
    }

    func testDecisionParentNavigationAndStatusFilter() {
        sample()
        search("同期先リポジトリ")
        tapVisible(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'decision-'")).firstMatch)
        XCTAssertTrue(app.navigationBars["裁定詳細"].waitForExistence(timeout: 5))
        tapVisible(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'related-'")).firstMatch)
        XCTAssertTrue(app.navigationBars["タスク詳細"].waitForExistence(timeout: 5))
        app.navigationBars["タスク詳細"].buttons.element(boundBy: 0).tap()
        app.navigationBars["裁定詳細"].buttons.element(boundBy: 0).tap()
        for _ in 0..<8 { if app.buttons["検索をクリア"].isHittable { break }; app.swipeDown() }
        app.buttons["検索をクリア"].tap()
        tapVisible(app.buttons["絞り込み"])
        app.buttons["decision-status-filter"].tap()
        app.buttons["反映済み"].tap()
        app.buttons["完了"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '表示言語を日本語に統一する'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testLaneFilterDigestAndSampleDoesNotPersist() {
        sample()
        openSection("タスク")
        app.buttons["lane-filter"].tap()
        app.buttons["運用・リサーチ"].tap()
        search("スナップショット契約")
        XCTAssertTrue(app.staticTexts["一致する項目なし"].waitForExistence(timeout: 3))
        openSection("整理")
        XCTAssertTrue(app.staticTexts["全レーンの日本語ダイジェスト"].waitForExistence(timeout: 3))
        tapVisible(app.staticTexts["重複候補"])
        openSection("設定")
        XCTAssertTrue(app.staticTexts["接続設定"].waitForExistence(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["はじめる"].waitForExistence(timeout: 5))
    }

    func testSyncUpdatesAllSurfacesAndOfflineCacheSurvivesRelaunch() {
        app.launchArguments.append("--ui-sync-fixture")
        app.launch()
        app.textFields["owner"].tap()
        app.textFields["owner"].typeText("ui-fixture")
        app.textFields["repository"].tap()
        app.textFields["repository"].typeText("taskhub")
        app.secureTextFields["token"].tap()
        app.secureTextFields["token"].typeText("fixture-read-token")
        tapVisible(app.buttons["接続して同期"])
        XCTAssertTrue(app.navigationBars["ユーザー裁定"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["同期"].tap()
        XCTAssertTrue(app.staticTexts["1件・レーン横断で確認"].waitForExistence(timeout: 8))
        openSection("タスク")
        search("同期方式の最終確認")
        tapVisible(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-'")).firstMatch)
        tapVisible(app.buttons.matching(NSPredicate(format: "label CONTAINS '同期先リポジトリを選んでほしい・回答済み'")).firstMatch)
        XCTAssertTrue(app.navigationBars["裁定詳細"].waitForExistence(timeout: 5))
        tapVisible(app.staticTexts["回答の記録"])
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == '回答者、fixture-user'")).firstMatch.exists)
        openSection("整理")
        tapVisible(app.staticTexts["ユーザー裁定"])
        openSection("裁定")
        app.navigationBars.buttons["同期"].tap()
        XCTAssertTrue(app.staticTexts["オフライン・保存済みデータを表示"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.append("--ui-restore")
        app.launch()
        XCTAssertTrue(app.navigationBars["ユーザー裁定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["オフライン・保存済みデータを表示"].exists)
        XCTAssertTrue(app.staticTexts["1件・レーン横断で確認"].exists)
    }

    func testInvalidConnectionShowsErrorAndSampleStillWorks() {
        app.launch()
        app.textFields["owner"].tap()
        app.textFields["owner"].typeText("https://github.com")
        app.textFields["repository"].tap()
        app.textFields["repository"].typeText("example")
        app.buttons["キーボードを閉じる"].tap()
        tapVisible(app.buttons["接続して同期"])
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'GitHubの所有者・リポジトリ名・ブランチ名を確認'")).firstMatch
        for _ in 0..<8 { if error.exists { break }; app.swipeDown() }
        XCTAssertTrue(error.exists)
        tapVisible(app.buttons["サンプルを見る"])
        XCTAssertTrue(app.navigationBars["ユーザー裁定"].waitForExistence(timeout: 5))
    }

    func testSectionSwitchPreservesSearchAndDetail() {
        sample()
        openSection("タスク")
        search("スナップショット契約")
        tapVisible(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-'")).firstMatch)
        XCTAssertTrue(app.navigationBars["タスク詳細"].waitForExistence(timeout: 5))
        openSection("整理")
        XCTAssertTrue(app.staticTexts["全レーンの日本語ダイジェスト"].waitForExistence(timeout: 5))
        openSection("タスク")
        XCTAssertTrue(app.navigationBars["タスク詳細"].waitForExistence(timeout: 5))
        app.navigationBars["タスク詳細"].buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.textFields["タイトル・本文・追記・添付を検索"].value as? String, "スナップショット契約")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "検索条件を保持したタスク一覧"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLargeTypeDarkModeNavigation() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "--ui-dark"]
        sample()
        openSection("タスク")
        search("スナップショット契約")
        tapVisible(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-'")).firstMatch)
        XCTAssertTrue(app.navigationBars["タスク詳細"].waitForExistence(timeout: 5))
        tapVisible(app.staticTexts["完了証拠"])
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "最大文字サイズ・ダーク・タスク詳細"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
