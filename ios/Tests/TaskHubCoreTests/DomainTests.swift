//
//  DomainTests.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import CryptoKit
import Foundation
import XCTest
@testable import TaskHubCore

final class DomainTests: XCTestCase {
    func testServerCLIFixtureAndRoundTrip() throws {
        let snapshot = try fixture()
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.lanes.count, 2)
        XCTAssertEqual(snapshot.tasks.count, 10)
        XCTAssertEqual(Set(snapshot.tasks.map { $0.status.rawValue }), Set(TaskStatus.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(snapshot.tasks.map { $0.priority.rawValue }), Set(Priority.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(snapshot.decisions.map { $0.status.rawValue }), Set(DecisionStatus.allCases.map(\.rawValue)))
        XCTAssertTrue(snapshot.tasks.contains { $0.parentID != nil })
        XCTAssertTrue(snapshot.tasks.contains { $0.amount?.value == "1200.50" })
        XCTAssertTrue(snapshot.decisions.contains { $0.application?.resumedTask == true })
        XCTAssertEqual(Set(snapshot.comments.map(\.targetType)), ["task", "decision"])
        XCTAssertEqual(Set(snapshot.attachments.map(\.targetType)), ["task", "decision", "comment"])
        let attachment = try XCTUnwrap(snapshot.attachments.first)
        XCTAssertEqual(attachment.filename, "evidence.txt")
        XCTAssertEqual(attachment.mediaType, "text/plain")
        XCTAssertEqual(attachment.sizeBytes, 0)
        XCTAssertEqual(attachment.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let encoded = try Snapshot.makeEncoder().encode(snapshot)
        XCTAssertEqual(try Snapshot.decode(encoded, previous: snapshot), snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertTrue(tasks.allSatisfy { $0["parent_id"] != nil && $0["completion"] != nil && $0["due_at"] != nil })
        XCTAssertNil(object["storeID"])
        XCTAssertTrue((object["generated_at"] as? String)?.hasSuffix("Z") == true)
    }

    func testFinalServerExampleAndAttachment() throws {
        let snapshot = try fixture("server-release-snapshot")
        XCTAssertEqual(snapshot.lastEventSeq, 12)
        XCTAssertEqual(snapshot.tasks.count, 2)
        XCTAssertEqual(snapshot.decisions.count, 2)
        XCTAssertEqual(snapshot.tasks.first { $0.title == "CLIを検証" }?.status, .done)
        let attachment = try XCTUnwrap(snapshot.attachments.first)
        let url = try XCTUnwrap(Bundle.module.url(forResource: "server-release-result", withExtension: "txt", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, attachment.sizeBytes)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), attachment.sha256)
        XCTAssertEqual(try Snapshot.decode(Snapshot.makeEncoder().encode(snapshot)), snapshot)
    }

    func testEmptyStoreAndZeroDigest() throws {
        let snapshot = try fixture("empty-snapshot")
        XCTAssertEqual(snapshot.lastEventSeq, 0)
        XCTAssertNil(snapshot.lastEventHash)
        XCTAssertNil(snapshot.generatedAt)
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertEqual(try Snapshot.decode(Snapshot.makeEncoder().encode(snapshot)), snapshot)
        let sections = snapshot.digest(now: date("2026-10-10T12:00:00Z"))
        XCTAssertEqual(sections.map(\.id), ["overdue", "upcoming", "stale", "duplicates", "decisions"])
        XCTAssertTrue(sections.allSatisfy { $0.taskIDs.isEmpty && $0.decisionIDs.isEmpty && $0.summary.contains("0") })
        var malformed = snapshot
        malformed.lastEventHash = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try malformed.validated())
        malformed = snapshot
        malformed.generatedAt = date("2026-10-10T12:00:00Z")
        XCTAssertThrowsError(try malformed.validated())
    }

    func testUnknownSchemaIsRejectedBeforeRecordDecoding() throws {
        XCTAssertThrowsError(try Snapshot.decode(resource("unknown-schema"))) { error in
            XCTAssertEqual(error as? SnapshotValidationError, .unsupportedSchema(2))
        }
        XCTAssertThrowsError(try Snapshot.decode(Data("{\"schema_version\":1}".utf8)))
    }

    func testByteLimitIncludesWhitespaceAtExactBoundary() throws {
        var data = try resource("empty-snapshot")
        data.append(Data(repeating: 32, count: Snapshot.maximumByteCount - data.count))
        XCTAssertEqual(data.count, 33_554_432)
        XCTAssertEqual(try Snapshot.decode(data).lastEventSeq, 0)
        data.append(32)
        XCTAssertThrowsError(try Snapshot.decode(data)) { error in
            XCTAssertEqual(error as? SnapshotValidationError, .tooLarge(33_554_433))
        }
    }

    func testMissingNullableAndRequiredKeysFailButUnknownKeysAreIgnored() throws {
        var document = try jsonDocument()
        document["future_metadata"] = ["extra": true]
        var tasks = try XCTUnwrap(document["tasks"] as? [[String: Any]])
        tasks[0]["new_field"] = "ignored"
        document["tasks"] = tasks
        XCTAssertEqual(try Snapshot.decode(JSONSerialization.data(withJSONObject: document)), try fixture())
        for key in ["last_event_hash", "generated_at", "tasks", "comments", "attachments"] {
            var missing = document
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: missing)), key)
        }
        for key in ["parent_id", "due_at", "completion", "assignee", "amount", "title"] {
            var missing = document
            var records = tasks
            records[0].removeValue(forKey: key)
            missing["tasks"] = records
            XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: missing)), key)
        }
        for key in ["due_at", "answer", "application"] {
            var missing = document
            var records = try XCTUnwrap(document["decisions"] as? [[String: Any]])
            records[0].removeValue(forKey: key)
            missing["decisions"] = records
            XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: missing)), key)
        }
    }

    func testStrictDatesEnumsAndTypes() throws {
        for value in ["2026-10-10", "2026-10-10T12:00:00+00:00", "2026-10-10T12:00:00.123Z",
                      "2026-02-30T12:00:00Z", "2026-10-10T25:00:00Z"] {
            var document = try jsonDocument()
            document["generated_at"] = value
            XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: document)), value)
        }
        for (key, value) in [("status", "future"), ("priority", "critical")] {
            var document = try jsonDocument()
            var records = try XCTUnwrap(document["tasks"] as? [[String: Any]])
            records[0][key] = value
            document["tasks"] = records
            XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: document)))
        }
        for value: Any in [true, "1", -1] {
            var document = try jsonDocument()
            document["last_event_seq"] = value
            XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: document)))
        }
        XCTAssertThrowsError(try Snapshot.decode(Data([0xff, 0xfe, 0xfd])))
        XCTAssertThrowsError(try Snapshot.decode(Data("not JSON".utf8)))
    }

    func testDuplicateAndTypedIDs() throws {
        XCTAssertThrowsError(try fixture("duplicate-id"))
        try invalid { $0.lanes.append($0.lanes[0]) }
        try invalid { $0.decisions.append($0.decisions[0]) }
        try invalid { $0.comments.append($0.comments[0]) }
        try invalid { $0.attachments.append($0.attachments[0]) }
        try invalid { $0.tasks[0].id = "t_11111111111111118111111111111111" }
        try invalid { $0.tasks[0].id = $0.tasks[0].id.uppercased() }
        try invalid { $0.tasks[0].id = $0.lanes[0].id }
        try invalid { $0.storeID = "not-a-uuid" }
    }

    func testReferencesAndParentCycles() throws {
        try invalid { $0.tasks[0].laneID = "l_11111111111141118111111111111111" }
        try invalid { $0.tasks[0].parentID = "t_11111111111141118111111111111111" }
        try invalid { $0.tasks[0].parentID = $0.tasks[0].id }
        try invalid { snapshot in
            let indices = snapshot.tasks.indices.filter { snapshot.tasks[$0].laneID == snapshot.tasks[0].laneID }
            snapshot.tasks[indices[0]].parentID = snapshot.tasks[indices[1]].id
            snapshot.tasks[indices[1]].parentID = snapshot.tasks[indices[0]].id
        }
        try invalid { snapshot in
            snapshot.tasks[0].parentID = snapshot.tasks.first { $0.laneID != snapshot.tasks[0].laneID }!.id
        }
        try invalid { $0.decisions[0].taskID = $0.lanes[0].id }
        try invalid { snapshot in
            snapshot.decisions[0].laneID = snapshot.lanes.first { $0.id != snapshot.decisions[0].laneID }!.id
        }
        try invalid { $0.comments[0].targetType = "lane" }
        try invalid { $0.comments[0].targetID = $0.lanes[0].id }
        try invalid { $0.attachments[0].targetType = "attachment" }
        try invalid { $0.attachments[0].targetID = $0.attachments[0].id }
    }

    func testCompletionDecisionAndAuditConsistency() throws {
        try invalid { snapshot in
            let index = snapshot.tasks.firstIndex { $0.status == .done }!
            snapshot.tasks[index].completion = nil
        }
        try invalid { snapshot in
            let index = snapshot.tasks.firstIndex { $0.status == .done }!
            snapshot.tasks[index].status = .todo
        }
        try invalid { snapshot in
            let index = snapshot.tasks.firstIndex { $0.status == .done }!
            snapshot.tasks[index].completion?.evidence = " \n "
        }
        try invalid { snapshot in
            let index = snapshot.decisions.firstIndex { $0.status == .answered }!
            snapshot.decisions[index].answer = nil
        }
        try invalid { snapshot in
            let index = snapshot.decisions.firstIndex { $0.status == .applied }!
            snapshot.decisions[index].application = nil
        }
        try invalid { snapshot in
            let answer = snapshot.decisions.first { $0.answer != nil }!.answer
            let index = snapshot.decisions.firstIndex { $0.status == .pending }!
            snapshot.decisions[index].answer = answer
        }
        try invalid { $0.tasks[0].revision = 0 }
        try invalid { $0.lanes[0].revision = $0.lastEventSeq + 1 }
        try invalid { $0.comments[0].eventSeq = 0 }
        try invalid { $0.attachments[0].eventSeq = $0.lastEventSeq + 1 }
        try invalid { $0.tasks[0].createdBy = "agent\ninvalid" }
        try invalid { $0.tasks[0].title = " " }
        try invalid { $0.lanes[1].name = $0.lanes[0].name }
        try invalid { $0.lastEventHash = nil }
        try invalid { $0.generatedAt = nil }
    }

    func testMoneyAndAttachmentValidation() throws {
        for value in ["-1", "01", "1.0000001", "1e2", ".1"] {
            try invalid { $0.tasks[0].amount = Money(value: value, currency: "JPY") }
        }
        try invalid { $0.tasks[0].amount = Money(value: "1", currency: "jpy") }
        try invalid { $0.attachments[0].sha256 = String(repeating: "A", count: 64) }
        try invalid { $0.attachments[0].sha256 = "abc" }
        for path in ["../evidence.txt", "/blobs/sha256/file", "https://example.com/file", "blobs/sha256/aa/invalid"] {
            try invalid { $0.attachments[0].blobPath = path }
        }
        for size in [-1, Snapshot.maximumByteCount + 1] {
            try invalid { $0.attachments[0].sizeBytes = size }
        }
        try invalid { $0.attachments[0].sizeBytes = 1 }
        for filename in ["../evidence.txt", "a\\b.txt", ".", "..", "a\nb.txt"] {
            try invalid { $0.attachments[0].filename = filename }
        }
        try invalid { $0.attachments[0].mediaType = "text/plain; charset=utf-8" }
        var snapshot = try fixture()
        snapshot.attachments = [snapshot.attachments[0]]
        snapshot.attachments[0].sizeBytes = Snapshot.maximumByteCount
        snapshot.attachments[0].sha256 = String(repeating: "a", count: 64)
        snapshot.attachments[0].blobPath = "blobs/sha256/aa/" + String(repeating: "a", count: 64)
        XCTAssertNoThrow(try snapshot.validated())
    }

    func testPreviousSnapshotPreventsStoreSwitchRollbackAndSameSequenceEdits() throws {
        let snapshot = try fixture()
        XCTAssertNoThrow(try snapshot.validated(previous: snapshot))
        var changed = snapshot
        changed.storeID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try changed.validated(previous: snapshot)) { error in
            XCTAssertEqual(error as? SnapshotValidationError, .storeChanged)
        }
        var older = try fixture("empty-snapshot")
        older.storeID = snapshot.storeID
        XCTAssertThrowsError(try older.validated(previous: snapshot)) { error in
            XCTAssertEqual(error as? SnapshotValidationError, .rollback(previous: snapshot.lastEventSeq, received: 0))
        }
        changed = snapshot
        changed.lastEventHash = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try changed.validated(previous: snapshot)) { error in
            XCTAssertEqual(error as? SnapshotValidationError, .historyChanged)
        }
        changed = snapshot
        changed.tasks[0].body += " changed without event"
        XCTAssertThrowsError(try Snapshot.decode(Snapshot.makeEncoder().encode(changed), previous: snapshot)) { error in
            XCTAssertEqual(error as? SnapshotValidationError, .historyChanged)
        }
        changed.lastEventSeq += 1
        changed.lastEventHash = String(repeating: "b", count: 64)
        XCTAssertNoThrow(try changed.validated(previous: snapshot))
    }

    func testSearchNormalizesUnicodeAndFindsPrimaryFields() throws {
        var snapshot = try fixture()
        snapshot.tasks[0].title = "ＳＴＲＡＳＳＥ café カタカナ"
        var filter = BrowseFilter()
        for query in ["strasse", "Straße", "cafe\u{301}", "ｶﾀｶﾅ"] {
            filter.query = query
            XCTAssertTrue(snapshot.filteredTasks(filter).contains { $0.id == snapshot.tasks[0].id }, query)
        }
        filter.query = "cafe"
        XCTAssertFalse(snapshot.filteredTasks(filter).contains { $0.id == snapshot.tasks[0].id })
        for field in ["body", "method", "rationale", "completion"] {
            var candidate = snapshot
            let marker = "unique-" + field
            switch field {
            case "body": candidate.tasks[0].body = marker
            case "method": candidate.tasks[0].method = marker
            case "rationale": candidate.tasks[0].rationale = marker
            default: candidate.tasks[0].completion = Completion(evidence: marker, verifiedBy: "tester", verifiedAt: .now)
            }
            filter.query = marker
            XCTAssertEqual(candidate.filteredTasks(filter).map(\.id), [candidate.tasks[0].id])
        }
        filter.query = " \n\t "
        XCTAssertEqual(snapshot.filteredTasks(filter).count, snapshot.tasks.count)
    }

    func testSearchCommentsAndAllAttachmentAncestryWithoutLeakingDecisionMatchesToTasks() throws {
        let source = try fixture()
        for comment in source.comments {
            var snapshot = source
            let index = snapshot.comments.firstIndex { $0.id == comment.id }!
            snapshot.comments[index].body = "unique-comment-needle"
            var filter = BrowseFilter()
            filter.query = "unique-comment-needle"
            if comment.targetType == "task" {
                XCTAssertEqual(snapshot.filteredTasks(filter).map(\.id), [comment.targetID])
                XCTAssertTrue(snapshot.filteredDecisions(filter).isEmpty)
            } else {
                XCTAssertEqual(snapshot.filteredDecisions(filter).map(\.id), [comment.targetID])
                XCTAssertTrue(snapshot.filteredTasks(filter).isEmpty)
            }
        }
        for attachment in source.attachments {
            for field in ["filename", "description"] {
                var snapshot = source
                let index = snapshot.attachments.firstIndex { $0.id == attachment.id }!
                if field == "filename" { snapshot.attachments[index].filename = "UNIQUE-ATTACHMENT.txt" }
                else { snapshot.attachments[index].description = "UNIQUE-ATTACHMENT" }
                var type = attachment.targetType
                var id = attachment.targetID
                if type == "comment" {
                    let owner = try XCTUnwrap(source.comments.first { $0.id == id })
                    type = owner.targetType
                    id = owner.targetID
                }
                var filter = BrowseFilter()
                filter.query = "unique-attachment"
                XCTAssertEqual(snapshot.filteredTasks(filter).map(\.id), type == "task" ? [id] : [])
                XCTAssertEqual(snapshot.filteredDecisions(filter).map(\.id), type == "decision" ? [id] : [])
            }
        }
    }

    func testDecisionFieldsAndAssigneeFilterUseOwnRecordAndSourceTask() throws {
        var snapshot = try fixture()
        let index = try XCTUnwrap(snapshot.decisions.firstIndex { $0.status == .applied })
        snapshot.decisions[index].options = ["unique-option"]
        snapshot.decisions[index].reason = "unique-reason"
        snapshot.decisions[index].answer?.text = "unique-answer"
        snapshot.decisions[index].application?.evidence = "unique-application"
        var filter = BrowseFilter()
        for query in ["unique-option", "unique-reason", "unique-answer", "unique-application"] {
            filter.query = query
            XCTAssertEqual(snapshot.filteredDecisions(filter).map(\.id), [snapshot.decisions[index].id])
            XCTAssertTrue(snapshot.filteredTasks(filter).isEmpty)
        }
        filter = BrowseFilter()
        filter.assignee = "agent-ops"
        let decisions = snapshot.filteredDecisions(filter)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertTrue(decisions.allSatisfy { snapshot.task(id: $0.taskID)?.assignee == "agent-ops" })
    }

    func testFiltersUseHalfOpenUpdatedPeriodAndDueThenIDOrder() throws {
        var snapshot = try fixture()
        let now = date("2026-10-10T12:00:00Z")
        for index in snapshot.tasks.indices { snapshot.tasks[index].updatedAt = now }
        snapshot.tasks[0].updatedAt = now.addingTimeInterval(-1)
        var filter = BrowseFilter()
        filter.since = now
        filter.until = now.addingTimeInterval(1)
        XCTAssertEqual(snapshot.filteredTasks(filter).count, snapshot.tasks.count - 1)
        filter.until = now
        XCTAssertTrue(snapshot.filteredTasks(filter).isEmpty)
        filter = BrowseFilter()
        filter.laneID = snapshot.tasks[0].laneID
        filter.taskStatus = snapshot.tasks[0].status
        filter.assignee = snapshot.tasks[0].assignee
        XCTAssertTrue(snapshot.filteredTasks(filter).allSatisfy {
            $0.laneID == filter.laneID && $0.status == filter.taskStatus && $0.assignee == filter.assignee
        })
        filter = BrowseFilter()
        filter.decisionStatus = .pending
        XCTAssertTrue(snapshot.filteredDecisions(filter).allSatisfy { $0.status == .pending })
        for index in snapshot.tasks.indices { snapshot.tasks[index].dueAt = nil }
        let ids = snapshot.tasks.map(\.id).sorted()
        snapshot.tasks[0].dueAt = now
        let sorted = snapshot.filteredTasks(BrowseFilter()).map(\.id)
        XCTAssertEqual(sorted, [snapshot.tasks[0].id] + ids.filter { $0 != snapshot.tasks[0].id })
        XCTAssertEqual(snapshot.task(id: snapshot.tasks[0].id), snapshot.tasks[0])
        XCTAssertEqual(snapshot.lane(id: snapshot.lanes[0].id), snapshot.lanes[0])
        XCTAssertEqual(snapshot.decision(id: snapshot.decisions[0].id), snapshot.decisions[0])
        XCTAssertNil(snapshot.task(id: "missing"))
        let comment = snapshot.comments[0]
        XCTAssertTrue(snapshot.comments(targetType: comment.targetType, targetID: comment.targetID).contains(comment))
        let attachment = snapshot.attachments[0]
        XCTAssertTrue(snapshot.attachments(targetType: attachment.targetType, targetID: attachment.targetID).contains(attachment))
    }

    func testDigestMatchesActualServerCLI() throws {
        let snapshot = try fixture()
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: resource("server-digest")) as? [String: Any])
        let expected = try XCTUnwrap(response["data"] as? [String: Any])
        let digest = snapshot.digest(now: date("2026-10-10T12:00:00Z"))
        for section in digest where section.id != "duplicates" {
            let rows = try XCTUnwrap(expected[section.id] as? [[String: Any]])
            XCTAssertEqual(section.taskIDs, rows.filter { $0["type"] as? String == "task" }.compactMap { $0["id"] as? String })
            XCTAssertEqual(section.decisionIDs, rows.filter { $0["type"] as? String == "decision" }.compactMap { $0["id"] as? String })
        }
        let groups = try XCTUnwrap(expected["duplicates"] as? [[String: Any]])
        let duplicateIDs = groups.flatMap { $0["tasks"] as? [[String: Any]] ?? [] }.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(digest[3].taskIDs), Set(duplicateIDs))
        XCTAssertEqual(digest.map(\.title), ["期限切れ", "期限間近", "停滞", "重複候補", "ユーザー裁定"])
        XCTAssertTrue(digest[4].summary.contains("未対応2件・回答済み1件"))
    }

    func testDigestBoundariesAndResolvedExclusion() throws {
        var snapshot = try fixture()
        let now = date("2026-10-10T12:00:00Z")
        for index in snapshot.tasks.indices {
            snapshot.tasks[index].status = .todo
            snapshot.tasks[index].dueAt = nil
            snapshot.tasks[index].updatedAt = now
            snapshot.tasks[index].title = "unique-\(index)"
        }
        for index in snapshot.decisions.indices { snapshot.decisions[index].status = .applied }
        snapshot.tasks[0].dueAt = now.addingTimeInterval(-1)
        snapshot.tasks[1].dueAt = now
        snapshot.tasks[2].dueAt = now.addingTimeInterval(72 * 3_600)
        snapshot.tasks[3].dueAt = now.addingTimeInterval(72 * 3_600 + 1)
        snapshot.tasks[4].updatedAt = now.addingTimeInterval(-7 * 86_400)
        snapshot.tasks[5].updatedAt = now.addingTimeInterval(-7 * 86_400 + 1)
        snapshot.tasks[6].dueAt = now.addingTimeInterval(-1)
        snapshot.tasks[6].updatedAt = now.addingTimeInterval(-8 * 86_400)
        snapshot.tasks[6].status = .done
        let sections = snapshot.digest(now: now)
        XCTAssertEqual(sections[0].taskIDs, [snapshot.tasks[0].id])
        XCTAssertEqual(sections[1].taskIDs, [snapshot.tasks[1].id, snapshot.tasks[2].id])
        XCTAssertEqual(sections[2].taskIDs, [snapshot.tasks[4].id])
        XCTAssertTrue(sections.allSatisfy { !$0.taskIDs.contains(snapshot.tasks[6].id) && $0.decisionIDs.isEmpty })
        XCTAssertEqual(snapshot.digest(now: now), sections)
        let sameLane = snapshot.tasks.indices.filter { snapshot.tasks[$0].laneID == snapshot.tasks[0].laneID }
        snapshot.tasks[sameLane[0]].title = "Ｓｙｎｃ   Ｒｅｖｉｅｗ"
        snapshot.tasks[sameLane[1]].title = "sync review"
        let otherLane = try XCTUnwrap(snapshot.tasks.indices.first { snapshot.tasks[$0].laneID != snapshot.tasks[0].laneID })
        snapshot.tasks[otherLane].title = "sync review"
        XCTAssertEqual(Set(snapshot.digest(now: now)[3].taskIDs), Set([snapshot.tasks[sameLane[0]].id, snapshot.tasks[sameLane[1]].id]))
    }

    private func resource(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func fixture(_ name: String = "server-snapshot") throws -> Snapshot {
        try Snapshot.decode(resource(name))
    }

    private func jsonDocument() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: resource("server-snapshot")) as? [String: Any])
    }

    private func invalid(_ mutate: (inout Snapshot) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        var snapshot = try fixture()
        mutate(&snapshot)
        XCTAssertThrowsError(try snapshot.validated(), file: file, line: line)
        XCTAssertThrowsError(try Snapshot.decode(Snapshot.makeEncoder().encode(snapshot)), file: file, line: line)
    }

    private func date(_ value: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(value)
    }
}
