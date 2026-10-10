//
//  GalleryUITests.swift
//  TaskHubGalleryUITests
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import XCTest

final class GalleryUITests: XCTestCase {
    @MainActor
    func testSearchNoResultsResetAndAttachmentNames() {
        let app = launch()
        selectSection("tasks", in: app)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "6件")

        let search = app.textFields["タスク・裁定を検索"].firstMatch
        reveal(search, in: app)
        activate(search)
        search.typeText("no-matching-gallery-item")
        XCTAssertTrue(app.staticTexts["一致する項目がありません"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "0件")

        activate(element("filters.reset", in: app))
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "6件")
        activate(search)
        search.typeText("T-102")
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "1件")
        XCTAssertTrue(element("task.T-102", in: app).exists)
        XCTAssertFalse(element("task.T-101", in: app).exists)

        activate(element("filters.reset", in: app))
        activate(search)
        search.typeText("2026-10-10.txt")
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "3件")
        XCTAssertTrue(element("task.T-101", in: app).exists)
        activate(app.buttons["検索をクリア"].firstMatch)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "6件")
        activate(search)
        search.typeText("   ")
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "6件")
    }

    @MainActor
    func testLaneFiltersAreOwnedByTheGallery() {
        let app = launch()
        selectSection("tasks", in: app)
        selectLane("client", in: app)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "3件")
        XCTAssertTrue(element("task.T-102", in: app).exists)
        XCTAssertFalse(element("task.T-101", in: app).exists)
        XCTAssertEqual(element("lane.client", in: app).value as? String, "選択中")

        selectLane("all", in: app)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "6件")
        selectLane("design", in: app)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "3件")
        XCTAssertTrue(element("task.T-101", in: app).exists)
        XCTAssertFalse(element("task.T-102", in: app).exists)

        selectSection("decisions", in: app)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "2件")
        XCTAssertTrue(element("decision.D-201", in: app).exists)
        XCTAssertFalse(element("decision.D-202", in: app).exists)
        selectLane("all", in: app)
        XCTAssertEqual(element("gallery.resultCount", in: app).label, "3件")
    }

    @MainActor
    func testTaskDetailShowsAttachmentsAndAppendOnlyHistory() {
        let app = launch()
        selectSection("tasks", in: app)
        let task = element("task.T-101", in: app)
        reveal(task, in: app)
        activate(task)
        XCTAssertTrue(element("task.detail.title", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("task.detail.title", in: app).label, "共通コンポーネントのアクセシビリティを確認する")

        let attachment = element("attachment.attachment-review", in: app)
        reveal(attachment, in: app)
        XCTAssertTrue(attachment.label.contains("アクセシビリティ確認結果"))
        let history = element("history.history-review", in: app)
        reveal(history, in: app)
        XCTAssertTrue(history.label.contains("UI確認エージェント"))
        XCTAssertTrue(app.staticTexts["追記・変更履歴"].exists)
        attachScreenshot(app, name: "Task detail attachments and history")
    }

    @MainActor
    func testDecisionReplyIsLocalAndLinksToItsTask() {
        let app = launch()
        selectSection("decisions", in: app)
        let decision = element("decision.D-201", in: app)
        reveal(decision, in: app)
        activate(decision)
        XCTAssertTrue(element("decision.detail.title", in: app).waitForExistence(timeout: 5))

        let save = element("decision.reply.save", in: app)
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        activate(save)
        let recorded = element("decision.reply.recorded", in: app)
        XCTAssertTrue(recorded.waitForExistence(timeout: 5))
        XCTAssertEqual(recorded.label, "案A：状態名とアイコンを併記する方針で進めてください。")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(element("decision.status", in: app).label.contains("回答済み"))
        let history = element("history.local-reply-D-201", in: app)
        reveal(history, in: app)
        XCTAssertTrue(history.label.contains("Yuki（サンプル）"))

        let taskLink = element("decision.task", in: app)
        reveal(taskLink, in: app, upwards: true)
        activate(taskLink)
        XCTAssertTrue(element("task.detail.title", in: app).waitForExistence(timeout: 5))
        let relatedDecision = element("task.decision.D-201", in: app)
        reveal(relatedDecision, in: app)
        XCTAssertTrue(relatedDecision.label.contains("回答済み"))
        XCTAssertTrue(relatedDecision.label.contains("案A：状態名とアイコンを併記する方針で進めてください。"))
        activate(relatedDecision)
        XCTAssertTrue(recorded.waitForExistence(timeout: 5))
        reveal(save, in: app)
        XCTAssertFalse(save.isEnabled)

        app.terminate()
        app.launch()
        selectSection("decisions", in: app)
        reveal(decision, in: app)
        activate(decision)
        reveal(save, in: app)
        XCTAssertTrue(save.isEnabled)
        XCTAssertFalse(recorded.exists)
    }

    @MainActor
    func testOfflineAndSyncErrorRetry() {
        let app = launch()
        selectSection("components", in: app)
        let offline = element("sync.offline", in: app)
        reveal(offline, in: app)
        activate(offline)
        XCTAssertTrue(element("demo.sync.status", in: app).label.contains("オフライン"))
        selectSection("tasks", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "オフライン")).firstMatch.exists)
        selectSection("decisions", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "オフライン")).firstMatch.exists)
        selectSection("components", in: app)
        let retry = element("sync.retry", in: app)
        reveal(retry, in: app, upwards: true)
        activate(retry)
        XCTAssertTrue(element("demo.sync.status", in: app).label.contains("同期済み"))

        let error = element("sync.error", in: app)
        reveal(error, in: app)
        activate(error)
        XCTAssertTrue(element("demo.sync.status", in: app).label.contains("同期に失敗"))
        reveal(retry, in: app, upwards: true)
        activate(retry)
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(element("demo.sync.status", in: app).label.contains("同期済み"))
    }

    @MainActor
    func testErrorRetryAndDisabledButtons() {
        let app = launch()
        selectSection("components", in: app)
        let retry = app.buttons["再試行"].firstMatch
        reveal(retry, in: app)
        activate(retry)
        XCTAssertTrue(element("demo.error.recovered", in: app).waitForExistence(timeout: 5))

        let primary = element("demo.button.primary", in: app)
        reveal(primary, in: app)
        activate(primary)
        XCTAssertEqual(element("demo.button.result", in: app).label, "実行しました")
        let disabled = element("demo.button.disabled", in: app)
        reveal(disabled, in: app)
        XCTAssertFalse(disabled.isEnabled)
        let loading = element("demo.button.loading", in: app)
        reveal(loading, in: app)
        XCTAssertFalse(loading.isEnabled)
        XCTAssertEqual(loading.value as? String, "処理中")
    }

    @MainActor
    func testDarkNarrowAccessibilityTextKeepsTheFullJapaneseTitle() {
        let app = launch(arguments: ["--gallery-dark", "--gallery-narrow", "--gallery-accessibility"])
        selectSection("tasks", in: app)
        XCTAssertTrue(element("gallery.preview", in: app).label.contains("ダーク・アクセシビリティ文字・狭幅"))
        #if os(macOS)
        XCTAssertLessThanOrEqual(app.windows.firstMatch.frame.width, 480)
        #endif

        let search = app.textFields["タスク・裁定を検索"].firstMatch
        reveal(search, in: app)
        activate(search)
        search.typeText("T-103")
        let task = element("task.T-103", in: app)
        reveal(task, in: app)
        attachScreenshot(app, name: "Dark accessibility search results")
        activate(task)
        attachScreenshot(app, name: "Dark accessibility task navigation")
        let title = element("task.detail.title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(title.label, "日本語の長いタイトルでも省略せず、担当者・期限・レーンと判断に必要な情報を大きな文字で確認できるようにする")
        XCTAssertTrue(title.isHittable)
        attachScreenshot(app, name: "Dark narrow accessibility text")
    }

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP", "-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func selectSection(_ section: String, in app: XCUIApplication) {
        let sidebar = element("sidebar.\(section)", in: app)
        if sidebar.exists && sidebar.isHittable {
            activate(sidebar)
        } else {
            let menu = element("navigation.sections", in: app)
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            activate(menu)
            let item = element("navigation.\(section)", in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            activate(item)
        }
        XCTAssertTrue(element("gallery.section.title", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func selectLane(_ lane: String, in app: XCUIApplication) {
        let chip = element("lane.\(lane)", in: app)
        let lanes = app.scrollViews["gallery.lanes"].firstMatch
        if !chip.isHittable {
            #if os(macOS)
            lanes.scroll(byDeltaX: lane == "all" ? 400 : -400, deltaY: 0)
            #else
            if lane == "all" { lanes.swipeRight() } else { lanes.swipeLeft() }
            #endif
        }
        XCTAssertTrue(chip.isHittable)
        activate(chip)
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication, upwards: Bool = false) {
        let page = app.scrollViews["gallery.page"].firstMatch
        for _ in 0..<24 {
            var viewport = page.frame.intersection(app.windows.firstMatch.frame)
            #if os(iOS)
            let navigationBar = app.navigationBars.firstMatch
            if navigationBar.exists {
                let top = max(viewport.minY, navigationBar.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                viewport.size.height = max(0, min(viewport.maxY, keyboard.frame.minY - 48) - viewport.minY)
            }
            #endif
            var scrollUpwards = upwards
            if target.exists {
                let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
                if viewport.insetBy(dx: 4, dy: 12).contains(center) && (target.isHittable || !target.isEnabled) { return }
                scrollUpwards = center.y < viewport.midY
            }
            #if os(macOS)
            page.scroll(byDeltaX: 0, deltaY: scrollUpwards ? 250 : -250)
            #else
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let top = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.2))
            let bottom = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * 0.8))
            if scrollUpwards {
                top.press(forDuration: 0.05, thenDragTo: bottom)
            } else {
                bottom.press(forDuration: 0.05, thenDragTo: top)
            }
            #endif
        }
        XCTFail("Could not reveal \(target)")
    }

    @MainActor
    private func activate(_ target: XCUIElement) {
        #if os(macOS)
        target.click()
        #else
        target.tap()
        #endif
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
