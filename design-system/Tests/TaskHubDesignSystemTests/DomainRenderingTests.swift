//
//  DomainRenderingTests.swift
//  TaskHubDesignSystemTests
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import XCTest
@testable import TaskHubDesignSystem
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class DomainRenderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lane = HubLane(id: "lane-1", name: "複数エージェント共有プロジェクト")

    @MainActor
    func testDomainViewsRenderInEverySizeAndAppearance() throws {
        let task = HubTaskSummary(
            id: "TASK-123456789", title: "利用者確認後に長い日本語の依頼内容と添付の証拠を確認する",
            status: .needsReview, lane: lane, priority: .urgent, assignee: "agent-reviewer",
            dueDate: now.addingTimeInterval(-1), updatedBy: "agent-worker", updatedAt: now,
            subtaskCount: 12, completedSubtaskCount: 9,
            evidence: "動作確認結果と日本語ファイル名を含む根拠。長い説明も折り返して表示。"
        )
        let decision = HubDecisionSummary(
            id: "DECISION-42", title: "作業方針と費用について判断してほしい",
            taskID: task.id, lane: lane,
            options: ["現在の構成を維持して調査を継続する", "費用と制約を確認して新しい構成を試す"],
            reason: "次の作業に進むにはユーザーの確認が必要。理由と選択肢を省略せずに表示する。",
            dueDate: now.addingTimeInterval(3600), registeredBy: "agent-worker", registeredAt: now
        )
        let attachment = HubAttachment(
            id: "file-1", fileName: "[確認結果]_非常に長い日本語のファイル名_2026-10-10.png",
            description: "検証結果のスクリーンショット", registeredBy: "agent-worker", registeredAt: now,
            systemImage: "photo"
        )
        let history = HubHistoryEntry(
            id: "history-1", actor: "agent-worker", timestamp: now,
            message: "作業を記録し、ユーザー確認待ちへ更新。", evidence: "比較結果を添付。", attachments: [attachment]
        )
        for width in [320.0, 900.0] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility5] {
                    let content = VStack(alignment: .leading, spacing: HubSpacing.md) {
                        HubCard { HubTaskRow(task: task, now: now) }
                        HubDecisionCard(decision: decision, now: now)
                        HubHistoryRow(entry: history)
                    }
                    .padding(HubSpacing.md)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(HubColor.canvas)
                    .hubTheme()
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(width))
                    XCTAssertGreaterThan(image.height, 600)
                    if let path = ProcessInfo.processInfo.environment["TASKHUB_RENDER_DIR"] {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        #if os(macOS)
                        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        #else
                        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
                        #endif
                        try data.write(to: directory.appendingPathComponent("domain-\(Int(width))-\(scheme)-\(size).png"))
                    }
                }
            }
        }
    }

    @MainActor
    func testDomainSymbolsExistOnHostPlatform() {
        let symbols = Set(HubTaskStatus.allCases.map(\.systemImage)
            + HubDecisionStatus.allCases.map(\.systemImage)
            + HubPriority.allCases.map(\.systemImage)
            + ["rectangle.3.group", "doc", "person", "number", "person.crop.circle", "checklist", "checkmark.seal", "text.bubble", "paperclip"])
        for symbol in symbols {
            #if os(macOS)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
            #else
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
            #endif
        }
    }
}
