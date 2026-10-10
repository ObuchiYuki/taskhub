//
//  ApplicationUITests.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import XCTest

@MainActor final class ApplicationUITests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var cache: URL!
    private var snapshot: [String: Any]!
    private var app: XCUIApplication!
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("taskhub-mac-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("data")
        cache = root.appendingPathComponent("cache")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [project.appendingPathComponent("Scripts/make-server-fixture.py").path, "--destination", source.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("snapshot.json"))) as? [String: Any]
        app = XCUIApplication()
        app.launchEnvironment["TASKHUB_TEST_CACHE"] = cache.path
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func record(_ collection: String, title: String) throws -> [String: Any] {
        try XCTUnwrap((snapshot[collection] as? [[String: Any]])?.first { $0["title"] as? String == title })
    }

    private func id(_ collection: String, title: String) throws -> String {
        try XCTUnwrap(record(collection, title: title)["id"] as? String)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func click(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), identifier)
        target.click()
    }

    private func launchConnected() {
        app.launchEnvironment["TASKHUB_TEST_SOURCE"] = source.path
        app.launch()
        XCTAssertTrue(element("section.decisions").waitForExistence(timeout: 15))
    }

    func testConnectSearchFilterAndRelatedNavigation() throws {
        app.launch()
        click("connection.open")
        let local = app.buttons["ローカルフォルダ"]
        if local.exists { local.click() } else { app.radioButtons["ローカルフォルダ"].click() }
        let field = app.textFields["connection.directory"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(source.path)
        click("connection.connect")
        let pending = try id("decisions", title: "同期方式を決める")
        click("row.\(pending)")
        XCTAssertTrue(element("decision.detail.title").exists)
        click("decision.task")
        XCTAssertTrue(element("task.detail.title").waitForExistence(timeout: 5))
        let search = app.textFields["本文・追記・添付を検索"]
        search.click()
        search.typeText("抹茶チェック")
        let parent = try id("tasks", title: "Macアプリの同期検証")
        XCTAssertTrue(element("row.\(parent)").exists)
        XCTAssertFalse(element("row.\(try id("tasks", title: "完了した検証"))").exists)
        app.buttons["検索をクリア"].click()
        click("filters.toggle")
        app.popUpButtons["filter.lane"].click()
        app.menuItems["個人"].click()
        XCTAssertTrue(element("row.\(try id("tasks", title: "別レーンの作業"))").exists)
        XCTAssertFalse(element("row.\(parent)").exists)
        click("section.decisions")
        XCTAssertTrue(element("row.\(pending)").exists)
        app.popUpButtons["filter.status"].click()
        app.menuItems["回答済み"].click()
        click("row.\(try id("decisions", title: "保存期間の確認"))")
        XCTAssertTrue(element("decision.answer").exists)
        click("section.digest")
        XCTAssertTrue(element("digest.text").waitForExistence(timeout: 5))
        click("section.history")
        click("history.load")
        XCTAssertTrue(app.staticTexts["全履歴の検証が完了した。"].waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Mac navigation and verified history"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSyncUpdatesDecisionAndOfflineCacheSurvivesRelaunch() throws {
        launchConnected()
        let pending = try id("decisions", title: "同期方式を決める")
        click("row.\(pending)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.currentDirectoryURL = project.deletingLastPathComponent().appendingPathComponent("server")
        process.arguments = ["-m", "taskhub", "--data-dir", source.path, "--actor", "agent-ui-test", "decision", "answer", pending,
                             "--answer", "GitHub private を採用", "--respondent", "user-fixture"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(element("decision.answer").waitForExistence(timeout: 15))
        XCTAssertFalse(element("row.\(pending)").exists)
        click("section.tasks")
        click("row.\(try id("tasks", title: "Macアプリの同期検証"))")
        XCTAssertTrue(element("task.decision.\(pending)").exists)
        try FileManager.default.moveItem(at: source.appendingPathComponent("snapshot.json"), to: root.appendingPathComponent("offline-snapshot.json"))
        click("sync.refresh")
        XCTAssertTrue(element("task.detail.title").exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "TASKHUB_TEST_SOURCE")
        app.launch()
        click("section.tasks")
        click("row.\(try id("tasks", title: "Macアプリの同期検証"))")
        XCTAssertTrue(element("task.detail.title").exists)
        XCTAssertTrue(element("sync.banner").exists)
    }
}
