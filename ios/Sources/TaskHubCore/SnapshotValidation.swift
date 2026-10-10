//
//  SnapshotValidation.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public enum SnapshotValidationError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge(Int)
    case unsupportedSchema(Int)
    case invalid(String)
    case storeChanged
    case rollback(previous: Int, received: Int)
    case historyChanged

    public var errorDescription: String? {
        switch self {
        case .tooLarge:
            return "スナップショットが32MiBの上限を超えています。"
        case .unsupportedSchema(let version):
            return "未対応のデータ形式です（schema_version: \(version)）。"
        case .invalid(let field):
            return "スナップショットの整合性を確認できません（\(field)）。"
        case .storeChanged:
            return "保存済みデータとストアIDが一致しません。"
        case .rollback:
            return "保存済みデータより古いイベント列は読み込めません。"
        case .historyChanged:
            return "同じイベント番号のデータが変更されています。"
        }
    }
}

private let utcFormat = Date.ISO8601FormatStyle(
    includingFractionalSeconds: false, timeZone: TimeZone(secondsFromGMT: 0)!
)

extension Snapshot {
    public static let maximumByteCount = 32 * 1_024 * 1_024

    public static func decode(_ data: Data, previous: Snapshot? = nil) throws -> Snapshot {
        guard data.count <= maximumByteCount else {
            throw SnapshotValidationError.tooLarge(data.count)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SnapshotValidationError.invalid("UTF-8")
        }
        struct SchemaHeader: Decodable {
            let schemaVersion: Int
            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
            }
        }
        let decoder = makeDecoder()
        let header = try decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion == 1 else {
            throw SnapshotValidationError.unsupportedSchema(header.schemaVersion)
        }
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        try snapshot.validated(previous: previous)
        return snapshot
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard matches(value, "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"),
                  let date = try? utcFormat.parse(value), utcFormat.format(date) == value else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected UTC YYYY-MM-DDTHH:MM:SSZ."
                )
            }
            return date
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try validateDate(date, field: "date")
            try container.encode(utcFormat.format(date))
        }
        return encoder
    }

    public func validated(previous: Snapshot? = nil) throws {
        try require(schemaVersion == 1, "schema_version")
        try require(UUID(uuidString: storeID)?.uuidString.lowercased() == storeID, "store_id")
        try require(lastEventSeq >= 0, "last_event_seq")
        if lastEventSeq == 0 {
            try require(lastEventHash == nil && generatedAt == nil, "empty store metadata")
            try require(lanes.isEmpty && tasks.isEmpty && decisions.isEmpty && comments.isEmpty && attachments.isEmpty,
                        "empty store records")
        } else {
            try require(lastEventHash.map { matches($0, "[0-9a-f]{64}") } == true, "last_event_hash")
            try require(generatedAt != nil && !lanes.isEmpty, "generated_at / lanes")
        }
        if let generatedAt { try validateDate(generatedAt, field: "generated_at") }

        var ids = Set<String>()
        for (prefix, values) in [("l", lanes.map(\.id)), ("t", tasks.map(\.id)),
                                 ("d", decisions.map(\.id)), ("c", comments.map(\.id)),
                                 ("a", attachments.map(\.id))] {
            for id in values {
                try require(matches(id, prefix + "_[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}"), "id")
                try require(ids.insert(id).inserted, "duplicate id")
            }
        }
        let laneIDs = Set(lanes.map(\.id))
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let decisionsByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
        let commentsByID = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })

        var laneNames = Set<String>()
        for lane in lanes {
            try text(lane.name, field: "lane.name", limit: 512, singleLine: true)
            try text(lane.description, field: "lane.description", required: false)
            try require(laneNames.insert(normalizedForSearch(lane.name)).inserted, "duplicate lane name")
            try audit(lane.createdAt, lane.createdBy, lane.updatedAt, lane.updatedBy, lane.revision)
        }
        for task in tasks {
            try require(laneIDs.contains(task.laneID), "task.lane_id")
            if let parentID = task.parentID {
                try require(tasksByID[parentID]?.laneID == task.laneID, "task.parent_id")
            }
            try text(task.title, field: "task.title", limit: 512, singleLine: true)
            for value in [task.body, task.method, task.rationale] {
                try text(value, field: "task text", required: false)
            }
            if let assignee = task.assignee { try actor(assignee) }
            if let dueAt = task.dueAt { try validateDate(dueAt, field: "task.due_at") }
            if let amount = task.amount {
                try text(amount.value, field: "amount.value")
                try require(matches(amount.value, "(0|[1-9][0-9]*)(\\.[0-9]{1,6})?"), "amount.value")
                try require(matches(amount.currency, "[A-Z]{3}"), "amount.currency")
            }
            try require((task.status == .done) == (task.completion != nil), "task.completion")
            if let completion = task.completion {
                try text(completion.evidence, field: "completion.evidence")
                try actor(completion.verifiedBy)
                try validateDate(completion.verifiedAt, field: "completion.verified_at")
            }
            try audit(task.createdAt, task.createdBy, task.updatedAt, task.updatedBy, task.revision)
        }
        var visited = Set<String>()
        for task in tasks where !visited.contains(task.id) {
            var path = Set<String>()
            var currentID: String? = task.id
            while let id = currentID, !visited.contains(id) {
                try require(path.insert(id).inserted, "task parent cycle")
                currentID = tasksByID[id]?.parentID
            }
            visited.formUnion(path)
        }
        for decision in decisions {
            try require(laneIDs.contains(decision.laneID) && tasksByID[decision.taskID]?.laneID == decision.laneID,
                        "decision task / lane")
            try text(decision.title, field: "decision.title", limit: 512, singleLine: true)
            for value in [decision.body, decision.reason] + decision.options {
                try text(value, field: "decision text")
            }
            if let dueAt = decision.dueAt { try validateDate(dueAt, field: "decision.due_at") }
            switch decision.status {
            case .pending:
                try require(decision.answer == nil && decision.application == nil, "pending decision")
            case .answered:
                try require(decision.answer != nil && decision.application == nil, "answered decision")
            case .applied:
                try require(decision.answer != nil && decision.application != nil, "applied decision")
            }
            if let answer = decision.answer {
                try text(answer.text, field: "answer.text")
                try actor(answer.respondent)
                try actor(answer.recordedBy)
                try validateDate(answer.recordedAt, field: "answer.recorded_at")
            }
            if let application = decision.application {
                try text(application.evidence, field: "application.evidence")
                try actor(application.appliedBy)
                try validateDate(application.appliedAt, field: "application.applied_at")
            }
            try audit(decision.createdAt, decision.createdBy, decision.updatedAt, decision.updatedBy, decision.revision)
        }

        func ownerRevision(type: String, id: String) -> Int? {
            switch type {
            case "task": return tasksByID[id]?.revision
            case "decision": return decisionsByID[id]?.revision
            default: return nil
            }
        }
        for comment in comments {
            try require(ownerRevision(type: comment.targetType, id: comment.targetID).map { $0 >= comment.eventSeq } == true,
                        "comment target")
            try text(comment.body, field: "comment.body")
            try eventAudit(comment.createdAt, comment.createdBy, comment.eventSeq)
        }
        var blobSizes: [String: Int] = [:]
        for attachment in attachments {
            let revision: Int?
            if attachment.targetType == "comment", let comment = commentsByID[attachment.targetID] {
                revision = ownerRevision(type: comment.targetType, id: comment.targetID)
                try require(attachment.eventSeq > comment.eventSeq, "attachment comment sequence")
            } else {
                revision = ownerRevision(type: attachment.targetType, id: attachment.targetID)
            }
            try require(revision.map { $0 >= attachment.eventSeq } == true, "attachment target")
            try text(attachment.filename, field: "attachment.filename", limit: 255, singleLine: true)
            try require(![".", ".."].contains(attachment.filename) && !attachment.filename.contains("/") &&
                        !attachment.filename.contains("\\"), "attachment.filename")
            try text(attachment.description, field: "attachment.description", required: false)
            try text(attachment.mediaType, field: "attachment.media_type", limit: 255, singleLine: true)
            let token = "[A-Za-z0-9!#$%&'*+.^_`|~-]+"
            try require(matches(attachment.mediaType, token + "/" + token), "attachment.media_type")
            try require((0...Self.maximumByteCount).contains(attachment.sizeBytes), "attachment.size_bytes")
            try require(matches(attachment.sha256, "[0-9a-f]{64}"), "attachment.sha256")
            let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            try require((attachment.sizeBytes == 0) == (attachment.sha256 == emptySHA256), "empty blob hash / size")
            try require(attachment.blobPath == "blobs/sha256/\(attachment.sha256.prefix(2))/\(attachment.sha256)",
                        "attachment.blob_path")
            if let size = blobSizes[attachment.sha256] {
                try require(size == attachment.sizeBytes, "blob size mismatch")
            }
            blobSizes[attachment.sha256] = attachment.sizeBytes
            try eventAudit(attachment.createdAt, attachment.createdBy, attachment.eventSeq)
        }
        if let previous {
            guard storeID == previous.storeID else { throw SnapshotValidationError.storeChanged }
            guard lastEventSeq >= previous.lastEventSeq else {
                throw SnapshotValidationError.rollback(previous: previous.lastEventSeq, received: lastEventSeq)
            }
            if lastEventSeq == previous.lastEventSeq && self != previous {
                throw SnapshotValidationError.historyChanged
            }
        }
    }

    private func audit(_ createdAt: Date, _ createdBy: String, _ updatedAt: Date, _ updatedBy: String,
                       _ revision: Int) throws {
        try eventAudit(createdAt, createdBy, revision)
        try validateDate(updatedAt, field: "updated_at")
        try actor(updatedBy)
    }

    private func eventAudit(_ date: Date, _ createdBy: String, _ sequence: Int) throws {
        try validateDate(date, field: "created_at")
        try actor(createdBy)
        try require(sequence >= 1 && sequence <= lastEventSeq, "revision / event_seq")
    }
}

private func require(_ condition: Bool, _ field: String) throws {
    guard condition else { throw SnapshotValidationError.invalid(field) }
}

private func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
}

private func validateDate(_ date: Date, field: String) throws {
    let seconds = date.timeIntervalSince1970
    try require(seconds.isFinite && seconds.rounded() == seconds &&
                seconds >= -62_135_596_800 && seconds <= 253_402_300_799, field)
}

private func actor(_ value: String) throws {
    try text(value, field: "actor", limit: 128, singleLine: true)
}

private func text(_ value: String, field: String, required: Bool = true, limit: Int = 65_536,
                  singleLine: Bool = false) throws {
    try require(!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field)
    try require(value.utf8.count <= limit, field)
    try require(!value.unicodeScalars.contains { scalar in
        let isControl = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .surrogate
        return isControl && (singleLine || ![10, 13, 9].contains(scalar.value))
    }, field)
}
