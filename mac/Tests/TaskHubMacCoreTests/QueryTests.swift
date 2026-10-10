//
//  QueryTests.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import XCTest
@testable import TaskHubMacCore

final class QueryTests: XCTestCase {
    func testUnfilteredAndBlankSearchReturnAllRecordsInIDOrder() throws {
        var snapshot = try loadSnapshotFixture()
        snapshot.tasks.reverse()
        snapshot.decisions.reverse()
        let query = SnapshotQuery(snapshot: snapshot)
        XCTAssertEqual(query.tasks().map(\.id), snapshot.tasks.map(\.id).sorted())
        XCTAssertEqual(query.decisions().map(\.id), snapshot.decisions.map(\.id).sorted())
        XCTAssertEqual(query.tasks(matching: .init(text: " \n\t")).count, 8)
        XCTAssertTrue(query.tasks().allSatisfy { $0.matches.isEmpty })
    }

    func testUnicodeCompatibilityCaseFoldingAndCanonicalComposition() throws {
        let query = SnapshotQuery(snapshot: try loadSnapshotFixture())
        XCTAssertEqual(query.tasks(matching: .init(text: "cli")).count, 3)
        XCTAssertEqual(query.tasks(matching: .init(text: "ＣｌＩ")).count, 3)
        XCTAssertEqual(query.tasks(matching: .init(text: "STRASSE")).count, 1)
        XCTAssertEqual(query.tasks(matching: .init(text: "re\u{301}sume\u{301}")).count, 1)
        XCTAssertEqual(query.tasks(matching: .init(text: "café")).count, 1)
        XCTAssertEqual(query.tasks(matching: .init(text: "ガイド")).count, 1)
        XCTAssertTrue(query.tasks(matching: .init(text: "resume")).isEmpty)
    }

    func testTaskFieldsAndCompletionEvidenceAreSearchable() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        for (needle, field) in [("Unicode検索", "body"), ("unittest", "method"), ("外部送信", "rationale")] {
            let results = query.tasks(matching: .init(text: needle))
            XCTAssertEqual(results.map(\.id), [snapshot.tasks[0].id])
            XCTAssertTrue(results[0].matches.contains(SearchMatch(field: field)))
        }
        let evidence = query.tasks(matching: .init(text: "終了コード0"))
        XCTAssertEqual(evidence.map(\.id), [snapshot.tasks[4].id])
        XCTAssertEqual(evidence[0].matches, [SearchMatch(field: "completion.evidence")])
    }

    func testDecisionFieldsOptionsAnswerAndApplicationEvidenceAreSearchable() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        for (needle, index, field) in [("ユーザー認証", 0, "title"), ("範囲を選んで", 0, "body"),
                                       ("同期許可", 0, "options"), ("本人の同意", 0, "reason"),
                                       ("ローカル限定", 1, "answer.text"), ("オフライン手順", 2, "application.evidence")] {
            let results = query.decisions(matching: .init(text: needle))
            XCTAssertEqual(results.map(\.id), [snapshot.decisions[index].id])
            XCTAssertTrue(results[0].matches.contains(SearchMatch(field: field)))
            XCTAssertTrue(query.tasks(matching: .init(text: needle)).isEmpty)
        }
    }

    func testCommentsAndAttachmentsAggregateUnderTheirTaskOrDecision() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        let taskComment = query.tasks(matching: .init(text: "描画ログ"))
        XCTAssertEqual(taskComment.map(\.id), [snapshot.tasks[1].id])
        XCTAssertEqual(taskComment[0].matches, [SearchMatch(field: "body", commentID: snapshot.comments[0].id)])
        let taskAttachment = query.tasks(matching: .init(text: "結果.txt"))
        XCTAssertEqual(taskAttachment.map(\.id), [snapshot.tasks[1].id])
        XCTAssertEqual(taskAttachment[0].matches, [SearchMatch(field: "filename", attachmentID: snapshot.attachments[0].id)])
        let commentAttachment = query.tasks(matching: .init(text: "追記経由"))
        XCTAssertEqual(commentAttachment.map(\.id), [snapshot.tasks[1].id])
        XCTAssertEqual(commentAttachment[0].matches,
                       [SearchMatch(field: "description", commentID: snapshot.comments[0].id, attachmentID: snapshot.attachments[2].id)])
        let decisionAttachment = query.decisions(matching: .init(text: "比較表"))
        XCTAssertEqual(decisionAttachment.map(\.id), [snapshot.decisions[0].id])
        XCTAssertEqual(decisionAttachment[0].matches,
                       [SearchMatch(field: "description", attachmentID: snapshot.attachments[1].id)])
        let decisionCommentAttachment = query.decisions(matching: .init(text: "補足資料"))
        XCTAssertEqual(decisionCommentAttachment.map(\.id), [snapshot.decisions[0].id])
        XCTAssertEqual(decisionCommentAttachment[0].matches,
                       [SearchMatch(field: "description", commentID: snapshot.comments[1].id, attachmentID: snapshot.attachments[3].id)])
    }

    func testMultipleMatchingSourcesProduceOneResultWithDeduplicatedFields() throws {
        var snapshot = try loadSnapshotFixture()
        snapshot.tasks[1].title = "café"
        snapshot.decisions[0].options = ["same", "SAME", "ｓａｍｅ"]
        let query = SnapshotQuery(snapshot: snapshot)
        let result = try XCTUnwrap(query.tasks(matching: .init(text: "café")).first)
        XCTAssertEqual(result.id, snapshot.tasks[1].id)
        XCTAssertEqual(result.matches.count, 3)
        XCTAssertEqual(query.decisions(matching: .init(text: "same")).first?.matches, [SearchMatch(field: "options")])
    }

    func testLaneStatusesAndExactAssigneeFiltersCombine() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        let filter = TaskFilter(text: "CLI", laneID: snapshot.lanes[0].id,
                                statuses: [.todo, .inProgress], assignee: "agent-mac")
        XCTAssertEqual(query.tasks(matching: filter).map(\.id), [snapshot.tasks[1].id])
        XCTAssertTrue(query.tasks(matching: .init(laneID: "not-a-lane")).isEmpty)
        XCTAssertTrue(query.tasks(matching: .init(assignee: "AGENT-MAC")).isEmpty)
        XCTAssertEqual(query.tasks(matching: .init(statuses: [.done])).map(\.id), [snapshot.tasks[4].id])
        XCTAssertEqual(query.tasks(matching: .init(laneID: snapshot.lanes[1].id)).count, 2)
    }

    func testDecisionAssigneeUsesRelatedTaskNotRecorder() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        XCTAssertEqual(query.decisions(matching: .init(assignee: "agent-mac")).map(\.id), [snapshot.decisions[0].id])
        XCTAssertEqual(query.decisions(matching: .init(statuses: [.answered], assignee: "agent-server")).map(\.id),
                       [snapshot.decisions[1].id])
        XCTAssertEqual(query.decisions(matching: .init(statuses: [.pending, .answered])).count, 2)
        XCTAssertTrue(query.decisions(matching: .init(laneID: snapshot.lanes[1].id)).isEmpty)
        XCTAssertTrue(query.decisions(matching: .init(assignee: "yuki")).isEmpty)
    }

    func testUpdatedDateRangeIsHalfOpenForTasksAndDecisions() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        let task = snapshot.tasks[1]
        XCTAssertEqual(query.tasks(matching: .init(updatedSince: task.updatedAt,
                                                  updatedUntil: task.updatedAt.addingTimeInterval(1))).map(\.id), [task.id])
        XCTAssertFalse(query.tasks(matching: .init(updatedUntil: task.updatedAt)).contains { $0.id == task.id })
        let decision = snapshot.decisions[1]
        XCTAssertEqual(query.decisions(matching: .init(updatedSince: decision.updatedAt,
                                                       updatedUntil: decision.updatedAt.addingTimeInterval(1))).map(\.id), [decision.id])
        XCTAssertFalse(query.decisions(matching: .init(updatedUntil: decision.updatedAt)).contains { $0.id == decision.id })
        XCTAssertTrue(query.tasks(matching: .init(updatedSince: task.updatedAt, updatedUntil: task.updatedAt)).isEmpty)
        XCTAssertTrue(query.decisions(matching: .init(updatedSince: task.updatedAt,
                                                      updatedUntil: task.updatedAt.addingTimeInterval(-1))).isEmpty)
    }

    func testDateFilterUsesEntityUpdateNotMatchedCommentDate() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        let oldCommentTime = snapshot.comments[0].createdAt
        XCTAssertTrue(query.tasks(matching: .init(text: "描画ログ", updatedUntil: oldCommentTime.addingTimeInterval(1))).isEmpty)
        XCTAssertEqual(query.tasks(matching: .init(text: "描画ログ", updatedSince: snapshot.tasks[1].updatedAt)).count, 1)
    }

    func testDigestDeadlineAndStalenessBoundariesAndClosedExclusion() throws {
        var snapshot = try loadSnapshotFixture()
        let now = fixtureDate("2026-10-10T12:00:00Z")
        snapshot.tasks[0].updatedAt = now.addingTimeInterval(-7 * 86_400)
        snapshot.tasks[2].updatedAt = now.addingTimeInterval(-7 * 86_400 + 1)
        let digest = SnapshotQuery(snapshot: snapshot).digest(now: now)
        XCTAssertEqual(Set(digest.overdue.map(\.id)), [snapshot.tasks[0].id, snapshot.decisions[0].id])
        XCTAssertEqual(Set(digest.upcoming.map(\.id)),
                       [snapshot.tasks[1].id, snapshot.tasks[2].id, snapshot.decisions[1].id])
        XCTAssertTrue(digest.stale.contains { $0.id == snapshot.tasks[0].id })
        XCTAssertFalse(digest.stale.contains { $0.id == snapshot.tasks[2].id })
        XCTAssertFalse(digest.upcoming.contains { $0.id == snapshot.tasks[5].id })
        let included = digest.overdue + digest.upcoming + digest.stale + digest.openDecisions
        XCTAssertFalse(included.contains { $0.id == snapshot.tasks[4].id || $0.id == snapshot.decisions[2].id })
        XCTAssertEqual(digest.openDecisions.map(\.id), [snapshot.decisions[0].id, snapshot.decisions[1].id])
        XCTAssertEqual(digest.openDecisions[0].taskID, snapshot.tasks[2].id)
    }

    func testDigestDuplicatesNormalizeWhitespaceCaseAndWidthWithinLaneOnly() throws {
        var snapshot = try loadSnapshotFixture()
        let now = fixtureDate("2026-10-10T12:00:00Z")
        snapshot.tasks[1].title = "  CLI\u{3000}検証  "
        snapshot.tasks[4].title = "cli 検証"
        let groups = SnapshotQuery(snapshot: snapshot).digest(now: now).duplicateTitles
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].normalizedTitle, "cli 検証")
        XCTAssertEqual(groups[0].laneID, snapshot.lanes[0].id)
        XCTAssertEqual(groups[0].tasks.map(\.id), [snapshot.tasks[0].id, snapshot.tasks[1].id])
    }

    func testDigestSortsByDeadlineThenIDWithNilLastAndIsDeterministic() throws {
        var snapshot = try loadSnapshotFixture()
        let now = fixtureDate("2026-10-10T12:00:00Z")
        let first = SnapshotQuery(snapshot: snapshot).digest(now: now)
        snapshot.tasks.reverse()
        snapshot.decisions.reverse()
        snapshot.comments.reverse()
        snapshot.attachments.reverse()
        let second = SnapshotQuery(snapshot: snapshot).digest(now: now)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.japaneseSummary, second.japaneseSummary)
        XCTAssertEqual(first.overdue.map(\.kind), [.decision, .task])
        let staleDates = first.stale.compactMap(\.dueAt)
        XCTAssertEqual(staleDates, staleDates.sorted())
        XCTAssertNil(first.stale.last?.dueAt)
        let headings = first.japaneseSummary.split(separator: "\n").filter { !$0.hasPrefix("-") && !$0.hasPrefix(" ") }
        XCTAssertEqual(headings.count, 5)
        XCTAssertTrue(headings[0].hasPrefix("期限切れ:"))
        XCTAssertTrue(headings[1].hasPrefix("期限間近:"))
        XCTAssertTrue(headings[2].hasPrefix("停滞:"))
        XCTAssertTrue(headings[3].hasPrefix("重複候補:"))
        XCTAssertTrue(headings[4].hasPrefix("ユーザー裁定:"))
    }

    func testEmptyDigestIncludesAllZeroCounts() throws {
        let snapshot = try loadSnapshotFixture("empty-v1")
        let digest = SnapshotQuery(snapshot: snapshot).digest(now: fixtureDate("2026-10-10T12:00:00Z"))
        XCTAssertEqual(digest.japaneseSummary,
                       "期限切れ: 0件\n期限間近: 0件\n停滞: 0件\n重複候補: 0件\nユーザー裁定: 0件")
    }

    func testQueriesAndDigestDoNotMutateSnapshot() throws {
        let snapshot = try loadSnapshotFixture()
        let query = SnapshotQuery(snapshot: snapshot)
        _ = query.tasks(matching: .init(text: "CLI"))
        _ = query.decisions(matching: .init(statuses: [.pending, .answered]))
        _ = query.digest(now: fixtureDate("2026-10-10T12:00:00Z"))
        XCTAssertEqual(query.snapshot, snapshot)
    }
}
