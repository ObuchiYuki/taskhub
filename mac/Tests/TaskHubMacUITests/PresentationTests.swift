//
//  PresentationTests.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import AppKit
import SwiftUI
import TaskHubDesignSystem
import TaskHubMacCore
import XCTest
@testable import TaskHubMacUI

final class PresentationTests: XCTestCase {
    private func snapshot() throws -> Snapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "snapshot-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Snapshot.decode(Data(contentsOf: url))
    }

    func testAllStatusesMapToDesignSystem() throws {
        XCTAssertEqual(TaskStatus.allCases.map(\.presentation), [.notStarted, .inProgress, .needsReview, .blocked, .completed, .onHold])
        XCTAssertEqual(DecisionStatus.allCases.map(\.presentation), [.pending, .answered, .applied])
        let data = try snapshot()
        for task in data.tasks {
            let summary = data.summary(task)
            XCTAssertEqual(summary.title, task.title)
            XCTAssertEqual(summary.updatedBy, task.updatedBy)
            XCTAssertEqual(summary.evidence, task.completion?.evidence)
            XCTAssertEqual(summary.subtaskCount, data.tasks.filter { $0.parentID == task.id }.count)
        }
        for decision in data.decisions {
            XCTAssertEqual(data.summary(decision).reply, decision.answer?.text)
            XCTAssertEqual(data.summary(decision).registeredBy, decision.createdBy)
        }
    }

    @MainActor func testRowsRenderWithLongContentAndAllAppearances() throws {
        let data = try snapshot()
        for width in [340.0, 720.0] {
            for scheme in [ColorScheme.light, .dark] {
                for typeSize in [DynamicTypeSize.large, .accessibility5] {
                    let content = VStack(alignment: .leading, spacing: HubSpacing.md) {
                        ForEach(data.tasks) { task in HubTaskRow(task: data.summary(task), now: Date(timeIntervalSince1970: 1_791_633_600)) }
                        ForEach(data.decisions) { decision in HubDecisionCard(decision: data.summary(decision)) }
                        ForEach(data.attachments) { attachment in HubAttachmentRow(attachment: attachment.presentation) }
                    }
                    .padding(HubSpacing.md).frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(HubColor.canvas).hubTheme()
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    let renderer = ImageRenderer(content: content)
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(width))
                    XCTAssertGreaterThan(image.height, 500)
                    if let folder = ProcessInfo.processInfo.environment["TASKHUB_RENDER_DIR"] {
                        let directory = URL(fileURLWithPath: folder)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        try png.write(to: directory.appendingPathComponent("rows-\(Int(width))-\(scheme)-\(typeSize).png"))
                    }
                }
            }
        }
    }

    @MainActor func testDetailViewsHaveFiniteLayout() throws {
        let data = try snapshot()
        let store = HubStore(cache: SnapshotCache(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        for width in [340.0, 720.0] {
            let task = try XCTUnwrap(data.tasks.first)
            let decision = try XCTUnwrap(data.decisions.first)
            for content in [
                AnyView(TaskDetail(task: task, snapshot: data, store: store, now: .now, navigate: { _ in })),
                AnyView(DecisionDetail(decision: decision, snapshot: data, store: store, now: .now, navigate: { _ in }))
            ] {
                let host = NSHostingView(rootView: content.frame(width: width, height: 900).hubTheme())
                host.setFrameSize(NSSize(width: width, height: 900))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.width, width)
                XCTAssertTrue(host.fittingSize.height.isFinite)
            }
        }
    }
}
