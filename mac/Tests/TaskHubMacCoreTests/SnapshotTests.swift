//
//  SnapshotTests.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import XCTest
@testable import TaskHubMacCore

func snapshotFixtureData(_ name: String = "snapshot-v1") throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func loadSnapshotFixture(_ name: String = "snapshot-v1") throws -> Snapshot {
    try Snapshot.decode(snapshotFixtureData(name))
}

func fixtureDate(_ value: String) -> Date {
    SnapshotTimestamp.parse(value)!
}

final class SnapshotTests: XCTestCase {
    func testFixtureDecodesEveryRecordAndState() throws {
        let snapshot = try loadSnapshotFixture()
        XCTAssertEqual(snapshot.lanes.count, 2)
        XCTAssertEqual(snapshot.tasks.count, 8)
        XCTAssertEqual(snapshot.decisions.count, 3)
        XCTAssertEqual(snapshot.comments.count, 2)
        XCTAssertEqual(snapshot.attachments.count, 4)
        XCTAssertEqual(Set(snapshot.tasks.map(\.status)), Set(TaskStatus.allCases))
        XCTAssertEqual(Set(snapshot.decisions.map(\.status)), Set(DecisionStatus.allCases))
        XCTAssertEqual(snapshot.tasks[1].parentID, snapshot.tasks[0].id)
        XCTAssertEqual(snapshot.tasks[0].amount, Money(value: "1500.000001", currency: "JPY"))
        XCTAssertEqual(snapshot.decisions[1].answer?.respondent, "yuki")
        XCTAssertEqual(snapshot.decisions[1].answer?.recordedBy, "agent-mac")
        XCTAssertEqual(snapshot.decisions[2].application?.resumedTask, false)
        XCTAssertEqual(snapshot.lastEventSeq, 27)
    }

    func testCodableRoundTripUsesServerKeysAndExplicitNulls() throws {
        let snapshot = try loadSnapshotFixture()
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try Snapshot.decode(encoded), snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["store_id"])
        XCTAssertNil(object["storeID"])
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertTrue(tasks[0]["parent_id"] is NSNull)
        XCTAssertTrue(tasks[0]["completion"] is NSNull)
        XCTAssertEqual(tasks[0]["created_at"] as? String, "2026-10-01T09:00:00Z")
    }

    func testUnknownAdditiveKeysAreIgnored() throws {
        let data = try alteredJSON { object in
            object["future_root"] = ["new": true]
            var tasks = object["tasks"] as! [[String: Any]]
            tasks[0]["future_task"] = "accepted"
            var amount = tasks[0]["amount"] as! [String: Any]
            amount["future_money"] = 42
            tasks[0]["amount"] = amount
            object["tasks"] = tasks
        }
        XCTAssertEqual(try Snapshot.decode(data), try loadSnapshotFixture())
    }

    func testEmptySnapshotAndRootConsistency() throws {
        let empty = try loadSnapshotFixture("empty-v1")
        XCTAssertNil(empty.generatedAt)
        XCTAssertNil(empty.lastEventHash)
        XCTAssertNoThrow(try empty.validate())
        try assertInvalid(empty) { $0.lastEventHash = String(repeating: "a", count: 64) }
        try assertInvalid(empty) { $0.generatedAt = fixtureDate("2026-10-10T00:00:00Z") }
        let fixture = try loadSnapshotFixture()
        try assertInvalid(empty) { $0.lanes = fixture.lanes }
        try assertInvalid { $0.lastEventHash = nil }
        try assertInvalid { $0.generatedAt = nil }
        try assertInvalid { $0.lastEventSeq = -1 }
        try assertInvalid { $0.lastEventSeq = 0 }
        try assertInvalid { $0.lastEventSeq += 1 }
    }

    func testUnsupportedVersionIsReportedBeforeOtherMissingFields() throws {
        XCTAssertThrowsError(try Snapshot.decode(Data("{\"schema_version\":2}".utf8))) {
            XCTAssertEqual($0 as? SnapshotValidationError, .unsupportedSchemaVersion(2))
            XCTAssertTrue($0.localizedDescription.contains("未対応"))
        }
        try assertInvalid { $0.schemaVersion = 2 }
    }

    func testCapacityAcceptsExactLimitAndRejectsOneByteOver() throws {
        var data = try snapshotFixtureData("empty-v1")
        data.append(Data(repeating: 32, count: Snapshot.maximumByteCount - data.count))
        XCTAssertNoThrow(try Snapshot.decode(data))
        data.append(32)
        XCTAssertThrowsError(try Snapshot.decode(data)) {
            XCTAssertEqual($0 as? SnapshotValidationError, .tooLarge(limit: 33_554_432))
        }
    }

    func testMalformedJSONAndNonUTF8AreRejected() {
        for data in [Data([0xff]), Data("[".utf8), Data("null".utf8), Data("[]".utf8),
                     "{\"schema_version\":1}".data(using: .utf16)!] {
            XCTAssertThrowsError(try Snapshot.decode(data)) {
                XCTAssertTrue($0 is SnapshotValidationError)
            }
        }
    }

    func testMissingNullableKeysAreRejected() throws {
        for key in ["last_event_hash", "generated_at"] {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { $0.removeValue(forKey: key) }), key)
        }
        for key in ["parent_id", "due_at", "assignee", "amount", "completion"] {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { object in
                var tasks = object["tasks"] as! [[String: Any]]
                tasks[0].removeValue(forKey: key)
                object["tasks"] = tasks
            }), key)
        }
        for key in ["due_at", "answer", "application"] {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { object in
                var decisions = object["decisions"] as! [[String: Any]]
                decisions[0].removeValue(forKey: key)
                object["decisions"] = decisions
            }), key)
        }
    }

    func testMalformedTypesAndUnknownEnumsAreRejected() throws {
        for value: Any in [true, "27", 1.5, NSNull()] {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { $0["last_event_seq"] = value }))
        }
        for (key, value): (String, Any) in [("status", "unknown"), ("priority", "critical"),
                                           ("title", 123), ("body", NSNull()), ("amount", 3), ("revision", true)] {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { object in
                var tasks = object["tasks"] as! [[String: Any]]
                tasks[0][key] = value
                object["tasks"] = tasks
            }))
        }
        for (array, key, value) in [("decisions", "status", "done"), ("comments", "target_type", "comment"),
                                    ("attachments", "target_type", "lane")] {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { object in
                var records = object[array] as! [[String: Any]]
                records[0][key] = value
                object[array] = records
            }))
        }
        XCTAssertThrowsError(try Snapshot.decode(alteredJSON { object in
            var decisions = object["decisions"] as! [[String: Any]]
            var application = decisions[2]["application"] as! [String: Any]
            application["resumed_task"] = 1
            decisions[2]["application"] = application
            object["decisions"] = decisions
        }))
    }

    func testIntegerFieldsRejectDecimalAndExponentNotation() throws {
        let text = String(decoding: try snapshotFixtureData(), as: UTF8.self)
        for (key, value) in [("schema_version", "1"), ("last_event_seq", "27"), ("revision", "1"),
                             ("size_bytes", "0"), ("event_seq", "22")] {
            for suffix in [".0", "e0"] {
                let changed = text.replacingOccurrences(of: "\"\(key)\": \(value),", with: "\"\(key)\": \(value)\(suffix),")
                    .replacingOccurrences(of: "\"\(key)\": \(value)\n", with: "\"\(key)\": \(value)\(suffix)\n")
                XCTAssertNotEqual(changed, text)
                XCTAssertThrowsError(try Snapshot.decode(Data(changed.utf8)), key + suffix)
            }
        }
    }

    func testStrictUTCTimestampsAndCalendarValidity() throws {
        let invalid = ["2026-10-10", "2026-10-10T12:00:00+00:00", "2026-10-10T12:00:00.000Z",
                       "2026-10-10t12:00:00z", "2026-02-29T12:00:00Z", "2026-02-30T12:00:00Z", "1500-02-29T00:00:00Z",
                       "2026-10-10T24:00:00Z", "2026-10-10T12:60:00Z", "2026-10-10T12:00:60Z",
                       "0000-01-01T00:00:00Z", "2026-10-10T12:00:00Z\n", "２０２６-10-10T12:00:00Z"]
        for value in invalid {
            XCTAssertThrowsError(try Snapshot.decode(alteredJSON { object in
                var tasks = object["tasks"] as! [[String: Any]]
                tasks[0]["due_at"] = value
                object["tasks"] = tasks
            }), value)
        }
        for value in ["2024-02-29T23:59:59Z", "0001-01-01T00:00:00Z", "1582-10-10T00:00:00Z", "9999-12-31T23:59:59Z"] {
            XCTAssertNotNil(SnapshotTimestamp.parse(value), value)
        }
        try assertInvalid { $0.tasks[0].dueAt = Date(timeIntervalSince1970: 0.5) }
        try assertInvalid { $0.tasks[0].dueAt = Date(timeIntervalSince1970: .infinity) }
    }

    func testClockRegressionIsNotConfusedWithSequenceRollback() throws {
        var snapshot = try loadSnapshotFixture()
        snapshot.tasks[0].createdAt = fixtureDate("2026-11-01T00:00:00Z")
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testStoreAndRecordIdentifiersRequireCanonicalUUIDs() throws {
        for value in ["bad", "12345678123442348234123456789abc", "12345678-1234-4234-8234-123456789ABC"] {
            try assertInvalid { $0.storeID = value }
        }
        for value in ["t_bad", "t_00000000000110008000000000000001", "t_00000000000140007000000000000001",
                      "t_0000000000014000800000000000000A", "l_00000000000140008000000000000001"] {
            try assertInvalid { $0.tasks[0].id = value }
        }
    }

    func testDuplicateIdentifiersInEveryCollectionAreRejected() throws {
        try assertInvalid { $0.lanes.append($0.lanes[0]) }
        try assertInvalid { $0.tasks.append($0.tasks[0]) }
        try assertInvalid { $0.decisions.append($0.decisions[0]) }
        try assertInvalid { $0.comments.append($0.comments[0]) }
        try assertInvalid { $0.attachments.append($0.attachments[0]) }
    }

    func testLaneNamesUseCompatibilityCaseFolding() throws {
        try assertInvalid { $0.lanes[1].name = "ＴＡＳＫＨＵＢ" }
        try assertInvalid { $0.lanes[0].name = "Straße"; $0.lanes[1].name = "STRASSE" }
    }

    func testMissingAndWrongKindReferencesAreRejected() throws {
        try assertInvalid { $0.tasks[0].laneID = $0.tasks[1].id }
        try assertInvalid { $0.tasks[1].parentID = $0.lanes[0].id }
        try assertInvalid { $0.decisions[0].taskID = $0.lanes[0].id }
        try assertInvalid { $0.decisions[0].laneID = $0.lanes[1].id }
        try assertInvalid { $0.comments[0].targetID = $0.decisions[0].id }
        try assertInvalid { $0.attachments[0].targetID = $0.comments[0].id }
        try assertInvalid { $0.attachments[2].targetID = $0.tasks[0].id }
    }

    func testParentCyclesAndCrossLaneParentsAreRejected() throws {
        try assertInvalid { $0.tasks[0].parentID = $0.tasks[0].id }
        try assertInvalid { $0.tasks[0].parentID = $0.tasks[1].id }
        try assertInvalid { $0.tasks[1].parentID = $0.tasks[5].id }
        try assertInvalid { $0.tasks[0].parentID = $0.tasks[2].id; $0.tasks[2].parentID = $0.tasks[1].id }
    }

    func testCompletionRequiresDoneEvidenceAndVerifier() throws {
        try assertInvalid { $0.tasks[0].status = .done }
        try assertInvalid { $0.tasks[4].status = .todo }
        try assertInvalid { $0.tasks[4].completion = nil }
        try assertInvalid { $0.tasks[4].completion?.evidence = " \n" }
        try assertInvalid { $0.tasks[4].completion?.verifiedBy = "" }
    }

    func testDecisionStateMatrixAndRequiredAnswerApplicationFields() throws {
        try assertInvalid { $0.decisions[0].answer = $0.decisions[1].answer }
        try assertInvalid { $0.decisions[0].application = $0.decisions[2].application }
        try assertInvalid { $0.decisions[1].answer = nil }
        try assertInvalid { $0.decisions[1].application = $0.decisions[2].application }
        try assertInvalid { $0.decisions[2].answer = nil }
        try assertInvalid { $0.decisions[2].application = nil }
        try assertInvalid { $0.decisions[1].answer?.text = "\t" }
        try assertInvalid { $0.decisions[1].answer?.respondent = "" }
        try assertInvalid { $0.decisions[1].answer?.recordedBy = "bad\nactor" }
        try assertInvalid { $0.decisions[2].application?.evidence = "" }
        try assertInvalid { $0.decisions[2].application?.appliedBy = "" }
        try assertInvalid { $0.decisions[0].options = [""] }
        try assertInvalid { $0.decisions[0].reason = "" }
        try assertInvalid { $0.decisions[0].body = "" }
    }

    func testMoneyUsesExactNonnegativeDecimalStrings() throws {
        for value in ["-1", "+1", "01", "1.", ".1", "1.1234567", "1e6", "NaN", "１"] {
            try assertInvalid { $0.tasks[0].amount?.value = value }
        }
        for currency in ["jpy", "JP", "JPYY", "123"] {
            try assertInvalid { $0.tasks[0].amount?.currency = currency }
        }
        for value in ["0", "0.000001", "999999999999999999999.123456"] {
            var snapshot = try loadSnapshotFixture()
            snapshot.tasks[0].amount?.value = value
            XCTAssertNoThrow(try snapshot.validate())
        }
    }

    func testTextByteLimitsAndControlCharacters() throws {
        try assertInvalid { $0.tasks[0].title = String(repeating: "あ", count: 171) }
        try assertInvalid { $0.tasks[0].body = String(repeating: "a", count: 65_537) }
        try assertInvalid { $0.tasks[0].createdBy = String(repeating: "あ", count: 43) }
        try assertInvalid { $0.tasks[0].assignee = " " }
        try assertInvalid { $0.tasks[0].title = "bad\nname" }
        try assertInvalid { $0.tasks[0].body = "bad\u{0}body" }
        var snapshot = try loadSnapshotFixture()
        snapshot.tasks[0].body = "multiple\nlines\tallowed\rhere"
        XCTAssertNoThrow(try snapshot.validate())
    }

    func testSafeAttachmentFilenameHashPathAndSize() throws {
        for filename in ["", ".", "..", "../secret", "/tmp/name", "nested/name", "nested\\name", "a\n.txt",
                         "a\u{0}.txt", String(repeating: "a", count: 256), String(repeating: "あ", count: 86)] {
            try assertInvalid { $0.attachments[0].filename = filename }
        }
        for hash in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), "../x"] {
            try assertInvalid { $0.attachments[0].sha256 = hash }
            try assertInvalid { $0.lastEventHash = hash }
        }
        for path in ["../blob", "/blobs/sha256/a", "https://example.invalid/blob", "blobs/sha256/../blob", "blobs%2fsha256"] {
            try assertInvalid { $0.attachments[0].blobPath = path }
        }
        try assertInvalid { $0.attachments[0].sizeBytes = -1 }
        try assertInvalid { $0.attachments[0].sizeBytes = Snapshot.maximumByteCount + 1 }
        try assertInvalid { $0.attachments[0].mediaType = "text/plain; charset=utf-8" }
        try assertInvalid { $0.attachments[0].sizeBytes = 1 }
    }

    func testRevisionAndImmutableEventBoundsAndMetadata() throws {
        for revision in [0, 28] {
            try assertInvalid { $0.tasks[0].revision = revision }
            try assertInvalid { $0.lanes[0].revision = revision }
            try assertInvalid { $0.decisions[0].revision = revision }
        }
        for sequence in [0, 28] {
            try assertInvalid { $0.comments[0].eventSeq = sequence }
            try assertInvalid { $0.attachments[0].eventSeq = sequence }
        }
        try assertInvalid { $0.attachments[2].eventSeq = $0.comments[0].eventSeq }
        try assertInvalid { $0.tasks[1].revision = 21 }
        try assertInvalid { $0.decisions[0].updatedAt = fixtureDate("2026-10-10T10:06:00Z") }
        try assertInvalid { $0.attachments[3].createdBy = "different-actor" }
    }

    func testPreviousSnapshotRejectsDifferentStoreRollbackAndHashMismatch() throws {
        let snapshot = try loadSnapshotFixture()
        let empty = try loadSnapshotFixture("empty-v1")
        XCTAssertNoThrow(try snapshot.validate(previous: empty))
        XCTAssertNoThrow(try snapshot.validate(previous: snapshot))
        XCTAssertThrowsError(try empty.validate(previous: snapshot)) {
            XCTAssertEqual($0 as? SnapshotValidationError, .rollback(previous: 27, received: 0))
        }
        var changed = snapshot
        changed.storeID = "87654321-4321-4321-8321-cba987654321"
        XCTAssertThrowsError(try changed.validate(previous: snapshot)) {
            XCTAssertEqual($0 as? SnapshotValidationError, .differentStore)
        }
        changed = snapshot
        changed.lastEventHash = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try changed.validate(previous: snapshot)) {
            XCTAssertEqual($0 as? SnapshotValidationError, .sameSequenceHashMismatch)
        }
    }

    private func assertInvalid(_ source: Snapshot? = nil, file: StaticString = #filePath, line: UInt = #line,
                               _ change: (inout Snapshot) -> Void) throws {
        var snapshot = try source ?? loadSnapshotFixture()
        change(&snapshot)
        XCTAssertThrowsError(try snapshot.validate(), file: file, line: line) {
            XCTAssertTrue($0 is SnapshotValidationError, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    private func alteredJSON(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotFixtureData()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
