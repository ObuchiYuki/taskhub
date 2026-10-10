//
//  DomainTests.swift
//  TaskHubDesignSystemTests
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import XCTest
import TaskHubDesignSystem

final class DomainTests: XCTestCase {
    private let lane = HubLane(id: "lane-native", name: "Mac・iOS アプリ")
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testTaskStatusesHaveStableIdentityAndJapanesePresentation() {
        let statuses: [HubTaskStatus] = [.notStarted, .inProgress, .needsReview, .blocked, .completed, .onHold]
        XCTAssertEqual(HubTaskStatus.allCases, statuses)
        XCTAssertEqual(statuses.map(\.id), ["notStarted", "inProgress", "needsReview", "blocked", "completed", "onHold"])
        XCTAssertEqual(statuses.map(\.title), ["未着手", "進行中", "ユーザー確認待ち", "ブロック", "完了", "保留"])
        XCTAssertEqual(statuses.map(\.tone), [.neutral, .info, .warning, .danger, .success, .neutral])
        XCTAssertEqual(Set(statuses.map(\.systemImage)).count, statuses.count)
        XCTAssertTrue(statuses.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(requireSendable(statuses), statuses)
    }

    func testDecisionStatusesHaveStableIdentityAndJapanesePresentation() {
        let statuses: [HubDecisionStatus] = [.pending, .answered, .applied]
        XCTAssertEqual(HubDecisionStatus.allCases, statuses)
        XCTAssertEqual(statuses.map(\.id), ["pending", "answered", "applied"])
        XCTAssertEqual(statuses.map(\.title), ["未対応", "回答済み", "反映済み"])
        XCTAssertEqual(statuses.map(\.tone), [.warning, .info, .success])
        XCTAssertEqual(Set(statuses.map(\.systemImage)).count, statuses.count)
        XCTAssertTrue(statuses.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(requireSendable(statuses), statuses)
    }

    func testPrioritiesHaveStableIdentityAndJapanesePresentation() {
        let priorities: [HubPriority] = [.low, .normal, .high, .urgent]
        XCTAssertEqual(HubPriority.allCases, priorities)
        XCTAssertEqual(priorities.map(\.id), ["low", "normal", "high", "urgent"])
        XCTAssertEqual(priorities.map(\.title), ["低", "通常", "高", "緊急"])
        XCTAssertEqual(priorities.map(\.tone), [.neutral, .neutral, .warning, .danger])
        XCTAssertEqual(Set(priorities.map(\.systemImage)).count, priorities.count)
        XCTAssertTrue(priorities.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(requireSendable(priorities), priorities)
    }

    func testLaneIdentityAndValueEquality() {
        XCTAssertEqual(lane.id, "lane-native")
        XCTAssertEqual(lane.name, "Mac・iOS アプリ")
        XCTAssertEqual(lane, HubLane(id: lane.id, name: lane.name))
        XCTAssertNotEqual(lane, HubLane(id: lane.id, name: "別の表示名"))
        XCTAssertEqual(requireSendable(lane), lane)
    }

    func testTaskDefaultsDoNotInventMetadata() {
        let task = HubTaskSummary(id: "task-1", title: "表示を確認する", lane: lane)
        XCTAssertEqual(task.id, "task-1")
        XCTAssertEqual(task.title, "表示を確認する")
        XCTAssertEqual(task.status, .notStarted)
        XCTAssertEqual(task.lane, lane)
        XCTAssertEqual(task.priority, .normal)
        XCTAssertNil(task.assignee)
        XCTAssertNil(task.dueDate)
        XCTAssertNil(task.updatedBy)
        XCTAssertNil(task.updatedAt)
        XCTAssertEqual(task.subtaskCount, 0)
        XCTAssertEqual(task.completedSubtaskCount, 0)
        XCTAssertNil(task.evidence)
    }

    func testTaskPreservesSuppliedMetadata() {
        let task = HubTaskSummary(
            id: "task-2",
            title: "task-2 日本語の長いタイトル\n改行を含む",
            status: .needsReview,
            lane: lane,
            priority: .urgent,
            assignee: "Yuki",
            dueDate: date,
            updatedBy: "Agent A",
            updatedAt: date.addingTimeInterval(-60),
            subtaskCount: 5,
            completedSubtaskCount: 3,
            evidence: "macOS・iOS の検証結果"
        )
        XCTAssertEqual(task.status, .needsReview)
        XCTAssertEqual(task.priority, .urgent)
        XCTAssertEqual(task.assignee, "Yuki")
        XCTAssertEqual(task.dueDate, date)
        XCTAssertEqual(task.updatedBy, "Agent A")
        XCTAssertEqual(task.updatedAt, date.addingTimeInterval(-60))
        XCTAssertEqual(task.subtaskCount, 5)
        XCTAssertEqual(task.completedSubtaskCount, 3)
        XCTAssertEqual(task.evidence, "macOS・iOS の検証結果")
        XCTAssertEqual(task.title, "task-2 日本語の長いタイトル\n改行を含む")
        XCTAssertEqual(requireSendable(task), task)
        XCTAssertNotEqual(task, HubTaskSummary(id: task.id, title: task.title, lane: lane))
    }

    func testCompletedTaskCanRepresentMissingEvidenceWithoutValidatingWorkflow() {
        let task = HubTaskSummary(id: "task-3", title: "既存データの表示", status: .completed, lane: lane)
        XCTAssertEqual(task.status, .completed)
        XCTAssertNil(task.evidence)
    }

    func testDecisionDefaultsDoNotInventReplyOrActor() {
        let decision = HubDecisionSummary(
            id: "decision-1", title: "方針の確認", taskID: "task-1", lane: lane, reason: "ユーザー判断が必要"
        )
        XCTAssertEqual(decision.id, "decision-1")
        XCTAssertEqual(decision.taskID, "task-1")
        XCTAssertEqual(decision.lane, lane)
        XCTAssertEqual(decision.status, .pending)
        XCTAssertTrue(decision.options.isEmpty)
        XCTAssertEqual(decision.reason, "ユーザー判断が必要")
        XCTAssertNil(decision.dueDate)
        XCTAssertNil(decision.registeredBy)
        XCTAssertNil(decision.registeredAt)
        XCTAssertNil(decision.reply)
    }

    func testDecisionPreservesOptionsOrderAndRecordedReply() {
        let options = ["現状を維持する", "新しい方針へ変更する\n補足", "現状を維持する"]
        let decision = HubDecisionSummary(
            id: "decision-2",
            title: "採用する方針",
            taskID: "task-2",
            lane: lane,
            status: .answered,
            options: options,
            reason: "依存タスクの再開に必要",
            dueDate: date,
            registeredBy: "Agent B",
            registeredAt: date.addingTimeInterval(-120),
            reply: "2番を採用する"
        )
        XCTAssertEqual(decision.options, options)
        XCTAssertEqual(decision.status, .answered)
        XCTAssertEqual(decision.dueDate, date)
        XCTAssertEqual(decision.registeredBy, "Agent B")
        XCTAssertEqual(decision.registeredAt, date.addingTimeInterval(-120))
        XCTAssertEqual(decision.reply, "2番を採用する")
        XCTAssertEqual(requireSendable(decision), decision)
        XCTAssertNotEqual(decision, HubDecisionSummary(
            id: decision.id, title: decision.title, taskID: decision.taskID, lane: lane, reason: decision.reason
        ))
    }

    func testAttachmentPreservesLiteralFileNameAndMetadata() {
        let fileName = "[検証結果](https://example.invalid)/画像_最終版.png"
        let attachment = HubAttachment(
            id: "attachment-1",
            fileName: fileName,
            description: "ダークモードの確認結果\n説明を追記",
            registeredBy: "Agent A",
            registeredAt: date,
            systemImage: "photo"
        )
        XCTAssertEqual(attachment.id, "attachment-1")
        XCTAssertEqual(attachment.fileName, fileName)
        XCTAssertEqual(attachment.description, "ダークモードの確認結果\n説明を追記")
        XCTAssertEqual(attachment.registeredBy, "Agent A")
        XCTAssertEqual(attachment.registeredAt, date)
        XCTAssertEqual(attachment.systemImage, "photo")
        XCTAssertEqual(requireSendable(attachment), attachment)
        XCTAssertNotEqual(attachment, HubAttachment(id: attachment.id, fileName: fileName))
    }

    func testAttachmentDefaultsContainNoAcquisitionMetadata() {
        let attachment = HubAttachment(id: "attachment-2", fileName: "結果.txt")
        XCTAssertNil(attachment.description)
        XCTAssertNil(attachment.registeredBy)
        XCTAssertNil(attachment.registeredAt)
        XCTAssertEqual(attachment.systemImage, "doc")
    }

    func testHistoryPreservesActorTimestampEvidenceAndAttachmentOrder() {
        let attachments = [
            HubAttachment(id: "attachment-2", fileName: "先に表示する.txt"),
            HubAttachment(id: "attachment-1", fileName: "次に表示する.txt")
        ]
        let entry = HubHistoryEntry(
            id: "history-1",
            actor: "Agent A",
            timestamp: date,
            message: "検証を実行した。\n次の確認を依頼する。",
            evidence: "テスト成功",
            attachments: attachments
        )
        XCTAssertEqual(entry.id, "history-1")
        XCTAssertEqual(entry.actor, "Agent A")
        XCTAssertEqual(entry.timestamp, date)
        XCTAssertEqual(entry.message, "検証を実行した。\n次の確認を依頼する。")
        XCTAssertEqual(entry.evidence, "テスト成功")
        XCTAssertEqual(entry.attachments, attachments)
        XCTAssertEqual(requireSendable(entry), entry)
        XCTAssertNotEqual(entry, HubHistoryEntry(
            id: entry.id, actor: entry.actor, timestamp: entry.timestamp, message: entry.message
        ))
    }

    func testHistoryDefaultsRepresentAnUnattachedNote() {
        let entry = HubHistoryEntry(id: "history-2", actor: "Yuki", timestamp: date, message: "確認した")
        XCTAssertNil(entry.evidence)
        XCTAssertTrue(entry.attachments.isEmpty)
    }

    private func requireSendable<Value: Sendable>(_ value: Value) -> Value {
        value
    }
}
