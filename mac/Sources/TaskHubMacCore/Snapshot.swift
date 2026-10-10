//
//  Snapshot.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public enum TaskStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case awaitingUser = "awaiting_user"
    case blocked, done
    case onHold = "on_hold"
}

public enum DecisionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case pending, answered, applied
}

public enum TaskPriority: String, Codable, Equatable, Sendable, CaseIterable {
    case low, normal, high, urgent
}

public enum CommentTargetType: String, Codable, Equatable, Sendable {
    case task, decision
}

public enum AttachmentTargetType: String, Codable, Equatable, Sendable {
    case task, decision, comment
}

public struct Money: Codable, Equatable, Sendable {
    public var value: String
    public var currency: String

    public init(
        value: String,
        currency: String
    ) {
        self.value = value
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case value
        case currency
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        currency = try container.decode(String.self, forKey: .currency)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(currency, forKey: .currency)
    }
}

public struct Completion: Codable, Equatable, Sendable {
    public var evidence: String
    public var verifiedBy: String
    public var verifiedAt: Date

    public init(
        evidence: String,
        verifiedBy: String,
        verifiedAt: Date
    ) {
        self.evidence = evidence
        self.verifiedBy = verifiedBy
        self.verifiedAt = verifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case evidence
        case verifiedBy = "verified_by"
        case verifiedAt = "verified_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        evidence = try container.decode(String.self, forKey: .evidence)
        verifiedBy = try container.decode(String.self, forKey: .verifiedBy)
        verifiedAt = try container.decodeUTC(forKey: .verifiedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(verifiedBy, forKey: .verifiedBy)
        try container.encodeUTC(verifiedAt, forKey: .verifiedAt)
    }
}

public struct Answer: Codable, Equatable, Sendable {
    public var text: String
    public var respondent: String
    public var recordedBy: String
    public var recordedAt: Date

    public init(
        text: String,
        respondent: String,
        recordedBy: String,
        recordedAt: Date
    ) {
        self.text = text
        self.respondent = respondent
        self.recordedBy = recordedBy
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case respondent
        case recordedBy = "recorded_by"
        case recordedAt = "recorded_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        respondent = try container.decode(String.self, forKey: .respondent)
        recordedBy = try container.decode(String.self, forKey: .recordedBy)
        recordedAt = try container.decodeUTC(forKey: .recordedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(respondent, forKey: .respondent)
        try container.encode(recordedBy, forKey: .recordedBy)
        try container.encodeUTC(recordedAt, forKey: .recordedAt)
    }
}

public struct Application: Codable, Equatable, Sendable {
    public var evidence: String
    public var appliedBy: String
    public var appliedAt: Date
    public var resumedTask: Bool

    public init(
        evidence: String,
        appliedBy: String,
        appliedAt: Date,
        resumedTask: Bool
    ) {
        self.evidence = evidence
        self.appliedBy = appliedBy
        self.appliedAt = appliedAt
        self.resumedTask = resumedTask
    }

    private enum CodingKeys: String, CodingKey {
        case evidence
        case appliedBy = "applied_by"
        case appliedAt = "applied_at"
        case resumedTask = "resumed_task"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        evidence = try container.decode(String.self, forKey: .evidence)
        appliedBy = try container.decode(String.self, forKey: .appliedBy)
        appliedAt = try container.decodeUTC(forKey: .appliedAt)
        resumedTask = try container.decode(Bool.self, forKey: .resumedTask)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(appliedBy, forKey: .appliedBy)
        try container.encodeUTC(appliedAt, forKey: .appliedAt)
        try container.encode(resumedTask, forKey: .resumedTask)
    }
}

public struct LaneRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var createdAt: Date
    public var createdBy: String
    public var updatedAt: Date
    public var updatedBy: String
    public var revision: Int

    public init(
        id: String,
        name: String,
        description: String,
        createdAt: Date,
        createdBy: String,
        updatedAt: Date,
        updatedBy: String,
        revision: Int
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        createdAt = try container.decodeUTC(forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        updatedAt = try container.decodeUTC(forKey: .updatedAt)
        updatedBy = try container.decode(String.self, forKey: .updatedBy)
        revision = try container.decode(Int.self, forKey: .revision)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeUTC(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encodeUTC(updatedAt, forKey: .updatedAt)
        try container.encode(updatedBy, forKey: .updatedBy)
        try container.encode(revision, forKey: .revision)
    }
}

public struct TaskRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var laneID: String
    public var parentID: String?
    public var title: String
    public var body: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var dueAt: Date?
    public var assignee: String?
    public var amount: Money?
    public var method: String
    public var rationale: String
    public var completion: Completion?
    public var createdAt: Date
    public var createdBy: String
    public var updatedAt: Date
    public var updatedBy: String
    public var revision: Int

    public init(
        id: String,
        laneID: String,
        parentID: String?,
        title: String,
        body: String,
        status: TaskStatus,
        priority: TaskPriority,
        dueAt: Date?,
        assignee: String?,
        amount: Money?,
        method: String,
        rationale: String,
        completion: Completion?,
        createdAt: Date,
        createdBy: String,
        updatedAt: Date,
        updatedBy: String,
        revision: Int
    ) {
        self.id = id
        self.laneID = laneID
        self.parentID = parentID
        self.title = title
        self.body = body
        self.status = status
        self.priority = priority
        self.dueAt = dueAt
        self.assignee = assignee
        self.amount = amount
        self.method = method
        self.rationale = rationale
        self.completion = completion
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case laneID = "lane_id"
        case parentID = "parent_id"
        case title
        case body
        case status
        case priority
        case dueAt = "due_at"
        case assignee
        case amount
        case method
        case rationale
        case completion
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        laneID = try container.decode(String.self, forKey: .laneID)
        parentID = try container.decode(String?.self, forKey: .parentID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        status = try container.decode(TaskStatus.self, forKey: .status)
        priority = try container.decode(TaskPriority.self, forKey: .priority)
        dueAt = try container.decodeNullableUTC(forKey: .dueAt)
        assignee = try container.decode(String?.self, forKey: .assignee)
        amount = try container.decode(Money?.self, forKey: .amount)
        method = try container.decode(String.self, forKey: .method)
        rationale = try container.decode(String.self, forKey: .rationale)
        completion = try container.decode(Completion?.self, forKey: .completion)
        createdAt = try container.decodeUTC(forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        updatedAt = try container.decodeUTC(forKey: .updatedAt)
        updatedBy = try container.decode(String.self, forKey: .updatedBy)
        revision = try container.decode(Int.self, forKey: .revision)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(laneID, forKey: .laneID)
        try container.encode(parentID, forKey: .parentID)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encodeUTC(dueAt, forKey: .dueAt)
        try container.encode(assignee, forKey: .assignee)
        try container.encode(amount, forKey: .amount)
        try container.encode(method, forKey: .method)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(completion, forKey: .completion)
        try container.encodeUTC(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encodeUTC(updatedAt, forKey: .updatedAt)
        try container.encode(updatedBy, forKey: .updatedBy)
        try container.encode(revision, forKey: .revision)
    }
}

public struct DecisionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var laneID: String
    public var taskID: String
    public var title: String
    public var body: String
    public var options: [String]
    public var reason: String
    public var dueAt: Date?
    public var status: DecisionStatus
    public var answer: Answer?
    public var application: Application?
    public var createdAt: Date
    public var createdBy: String
    public var updatedAt: Date
    public var updatedBy: String
    public var revision: Int

    public init(
        id: String,
        laneID: String,
        taskID: String,
        title: String,
        body: String,
        options: [String],
        reason: String,
        dueAt: Date?,
        status: DecisionStatus,
        answer: Answer?,
        application: Application?,
        createdAt: Date,
        createdBy: String,
        updatedAt: Date,
        updatedBy: String,
        revision: Int
    ) {
        self.id = id
        self.laneID = laneID
        self.taskID = taskID
        self.title = title
        self.body = body
        self.options = options
        self.reason = reason
        self.dueAt = dueAt
        self.status = status
        self.answer = answer
        self.application = application
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case laneID = "lane_id"
        case taskID = "task_id"
        case title
        case body
        case options
        case reason
        case dueAt = "due_at"
        case status
        case answer
        case application
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        laneID = try container.decode(String.self, forKey: .laneID)
        taskID = try container.decode(String.self, forKey: .taskID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        options = try container.decode([String].self, forKey: .options)
        reason = try container.decode(String.self, forKey: .reason)
        dueAt = try container.decodeNullableUTC(forKey: .dueAt)
        status = try container.decode(DecisionStatus.self, forKey: .status)
        answer = try container.decode(Answer?.self, forKey: .answer)
        application = try container.decode(Application?.self, forKey: .application)
        createdAt = try container.decodeUTC(forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        updatedAt = try container.decodeUTC(forKey: .updatedAt)
        updatedBy = try container.decode(String.self, forKey: .updatedBy)
        revision = try container.decode(Int.self, forKey: .revision)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(laneID, forKey: .laneID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(options, forKey: .options)
        try container.encode(reason, forKey: .reason)
        try container.encodeUTC(dueAt, forKey: .dueAt)
        try container.encode(status, forKey: .status)
        try container.encode(answer, forKey: .answer)
        try container.encode(application, forKey: .application)
        try container.encodeUTC(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encodeUTC(updatedAt, forKey: .updatedAt)
        try container.encode(updatedBy, forKey: .updatedBy)
        try container.encode(revision, forKey: .revision)
    }
}

public struct CommentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var targetType: CommentTargetType
    public var targetID: String
    public var body: String
    public var createdAt: Date
    public var createdBy: String
    public var eventSeq: Int

    public init(
        id: String,
        targetType: CommentTargetType,
        targetID: String,
        body: String,
        createdAt: Date,
        createdBy: String,
        eventSeq: Int
    ) {
        self.id = id
        self.targetType = targetType
        self.targetID = targetID
        self.body = body
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.eventSeq = eventSeq
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case targetType = "target_type"
        case targetID = "target_id"
        case body
        case createdAt = "created_at"
        case createdBy = "created_by"
        case eventSeq = "event_seq"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        targetType = try container.decode(CommentTargetType.self, forKey: .targetType)
        targetID = try container.decode(String.self, forKey: .targetID)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decodeUTC(forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        eventSeq = try container.decode(Int.self, forKey: .eventSeq)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(targetType, forKey: .targetType)
        try container.encode(targetID, forKey: .targetID)
        try container.encode(body, forKey: .body)
        try container.encodeUTC(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(eventSeq, forKey: .eventSeq)
    }
}

public struct AttachmentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var targetType: AttachmentTargetType
    public var targetID: String
    public var filename: String
    public var description: String
    public var mediaType: String
    public var sizeBytes: Int
    public var sha256: String
    public var blobPath: String
    public var createdAt: Date
    public var createdBy: String
    public var eventSeq: Int

    public init(
        id: String,
        targetType: AttachmentTargetType,
        targetID: String,
        filename: String,
        description: String,
        mediaType: String,
        sizeBytes: Int,
        sha256: String,
        blobPath: String,
        createdAt: Date,
        createdBy: String,
        eventSeq: Int
    ) {
        self.id = id
        self.targetType = targetType
        self.targetID = targetID
        self.filename = filename
        self.description = description
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.blobPath = blobPath
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.eventSeq = eventSeq
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case targetType = "target_type"
        case targetID = "target_id"
        case filename
        case description
        case mediaType = "media_type"
        case sizeBytes = "size_bytes"
        case sha256
        case blobPath = "blob_path"
        case createdAt = "created_at"
        case createdBy = "created_by"
        case eventSeq = "event_seq"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        targetType = try container.decode(AttachmentTargetType.self, forKey: .targetType)
        targetID = try container.decode(String.self, forKey: .targetID)
        filename = try container.decode(String.self, forKey: .filename)
        description = try container.decode(String.self, forKey: .description)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
        sha256 = try container.decode(String.self, forKey: .sha256)
        blobPath = try container.decode(String.self, forKey: .blobPath)
        createdAt = try container.decodeUTC(forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        eventSeq = try container.decode(Int.self, forKey: .eventSeq)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(targetType, forKey: .targetType)
        try container.encode(targetID, forKey: .targetID)
        try container.encode(filename, forKey: .filename)
        try container.encode(description, forKey: .description)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(blobPath, forKey: .blobPath)
        try container.encodeUTC(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(eventSeq, forKey: .eventSeq)
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var storeID: String
    public var lastEventSeq: Int
    public var lastEventHash: String?
    public var generatedAt: Date?
    public var lanes: [LaneRecord]
    public var tasks: [TaskRecord]
    public var decisions: [DecisionRecord]
    public var comments: [CommentRecord]
    public var attachments: [AttachmentRecord]

    public init(
        schemaVersion: Int,
        storeID: String,
        lastEventSeq: Int,
        lastEventHash: String?,
        generatedAt: Date?,
        lanes: [LaneRecord],
        tasks: [TaskRecord],
        decisions: [DecisionRecord],
        comments: [CommentRecord],
        attachments: [AttachmentRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.storeID = storeID
        self.lastEventSeq = lastEventSeq
        self.lastEventHash = lastEventHash
        self.generatedAt = generatedAt
        self.lanes = lanes
        self.tasks = tasks
        self.decisions = decisions
        self.comments = comments
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storeID = "store_id"
        case lastEventSeq = "last_event_seq"
        case lastEventHash = "last_event_hash"
        case generatedAt = "generated_at"
        case lanes
        case tasks
        case decisions
        case comments
        case attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        storeID = try container.decode(String.self, forKey: .storeID)
        lastEventSeq = try container.decode(Int.self, forKey: .lastEventSeq)
        lastEventHash = try container.decode(String?.self, forKey: .lastEventHash)
        generatedAt = try container.decodeNullableUTC(forKey: .generatedAt)
        lanes = try container.decode([LaneRecord].self, forKey: .lanes)
        tasks = try container.decode([TaskRecord].self, forKey: .tasks)
        decisions = try container.decode([DecisionRecord].self, forKey: .decisions)
        comments = try container.decode([CommentRecord].self, forKey: .comments)
        attachments = try container.decode([AttachmentRecord].self, forKey: .attachments)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(storeID, forKey: .storeID)
        try container.encode(lastEventSeq, forKey: .lastEventSeq)
        try container.encode(lastEventHash, forKey: .lastEventHash)
        try container.encodeUTC(generatedAt, forKey: .generatedAt)
        try container.encode(lanes, forKey: .lanes)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(comments, forKey: .comments)
        try container.encode(attachments, forKey: .attachments)
    }
}

public enum SnapshotValidationError: Error, LocalizedError, Equatable, Sendable {
    case tooLarge(limit: Int)
    case unsupportedSchemaVersion(Int)
    case malformedJSON
    case invalidField(String)
    case duplicateID(String)
    case missingReference(String)
    case inconsistentState(String)
    case parentCycle(String)
    case differentStore
    case rollback(previous: Int, received: Int)
    case sameSequenceHashMismatch

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            return "スナップショットが容量上限（\(limit)バイト）を超えている。"
        case .unsupportedSchemaVersion(let version):
            return "未対応のスキーマバージョン（\(version)）。現在の表示を保持する。"
        case .malformedJSON:
            return "スナップショットが正しいUTF-8 JSONではない。"
        case .invalidField(let field):
            return "スナップショットの項目が不正、または必須項目が不足：\(field)。"
        case .duplicateID(let id):
            return "スナップショットに重複IDがある：\(id)。"
        case .missingReference(let id):
            return "スナップショットの参照先が存在しない：\(id)。"
        case .inconsistentState(let field):
            return "スナップショットの状態に矛盾がある：\(field)。"
        case .parentCycle(let id):
            return "タスクの親子関係が循環している：\(id)。"
        case .differentStore:
            return "前回と異なるストアのデータ。現在の表示を保持する。"
        case .rollback(let previous, let received):
            return "イベント連番が巻き戻っている（\(previous) → \(received)）。現在の表示を保持する。"
        case .sameSequenceHashMismatch:
            return "同じイベント連番のハッシュが変更されている。現在の表示を保持する。"
        }
    }
}

extension Snapshot {
    public static let maximumByteCount = 32 * 1_024 * 1_024

    public static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= maximumByteCount else {
            throw SnapshotValidationError.tooLarge(limit: maximumByteCount)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SnapshotValidationError.malformedJSON
        }
        do {
            try SnapshotWireTypes.validate(data)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            try snapshot.validate()
            return snapshot
        } catch let error as SnapshotValidationError {
            throw error
        } catch DecodingError.keyNotFound(let key, let context) {
            throw SnapshotValidationError.invalidField(snapshotPath(context.codingPath + [key]))
        } catch DecodingError.typeMismatch(_, let context) {
            throw SnapshotValidationError.invalidField(snapshotPath(context.codingPath))
        } catch DecodingError.valueNotFound(_, let context) {
            throw SnapshotValidationError.invalidField(snapshotPath(context.codingPath))
        } catch DecodingError.dataCorrupted(let context) {
            if context.codingPath.isEmpty { throw SnapshotValidationError.malformedJSON }
            throw SnapshotValidationError.invalidField(snapshotPath(context.codingPath))
        } catch {
            throw SnapshotValidationError.malformedJSON
        }
    }

    public func validate(previous: Snapshot? = nil) throws {
        try SnapshotValidator(snapshot: self).validate()
        guard let previous else { return }
        guard storeID == previous.storeID else { throw SnapshotValidationError.differentStore }
        guard lastEventSeq >= previous.lastEventSeq else {
            throw SnapshotValidationError.rollback(previous: previous.lastEventSeq, received: lastEventSeq)
        }
        guard lastEventSeq != previous.lastEventSeq || lastEventHash == previous.lastEventHash else {
            throw SnapshotValidationError.sameSequenceHashMismatch
        }
    }
}

private enum SnapshotWireTypes {
    static func validate(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotValidationError.malformedJSON
        }
        let version = try integer(object["schema_version"], field: "schema_version")
        guard version == 1 else { throw SnapshotValidationError.unsupportedSchemaVersion(version) }
        _ = try integer(object["last_event_seq"], field: "last_event_seq")
        for (collection, fields) in [("lanes", ["revision"]), ("tasks", ["revision"]),
                                     ("decisions", ["revision"]), ("comments", ["event_seq"]),
                                     ("attachments", ["event_seq", "size_bytes"])] {
            guard let records = object[collection] as? [[String: Any]] else { continue }
            for (index, record) in records.enumerated() {
                for field in fields {
                    _ = try integer(record[field], field: "\(collection).\(index).\(field)")
                }
            }
        }
    }

    private static func integer(_ value: Any?, field: String) throws -> Int {
        // JSONDecoder accepts 1.0 and 1e0 as Int; the server requires integer tokens.
        guard let number = value as? NSNumber,
              ["q", "Q", "i", "I", "s", "S", "l", "L"].contains(String(cString: number.objCType)),
              let integer = Int(number.stringValue) else {
            throw SnapshotValidationError.invalidField(field)
        }
        return integer
    }
}

private func snapshotPath(_ path: [any CodingKey]) -> String {
    path.map(\.stringValue).joined(separator: ".")
}

private extension KeyedDecodingContainer {
    func decodeUTC(forKey key: Key) throws -> Date {
        let value = try decode(String.self, forKey: key)
        guard let date = SnapshotTimestamp.parse(value) else {
            throw SnapshotValidationError.invalidField(snapshotPath(codingPath + [key]))
        }
        return date
    }

    func decodeNullableUTC(forKey key: Key) throws -> Date? {
        guard let value = try decode(String?.self, forKey: key) else { return nil }
        guard let date = SnapshotTimestamp.parse(value) else {
            throw SnapshotValidationError.invalidField(snapshotPath(codingPath + [key]))
        }
        return date
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeUTC(_ value: Date?, forKey key: Key) throws {
        if let value {
            guard SnapshotTimestamp.isValid(value) else {
                throw SnapshotValidationError.invalidField(snapshotPath(codingPath + [key]))
            }
            try encode(SnapshotTimestamp.string(value), forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

enum SnapshotTimestamp {
    static func parse(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 20 else { return nil }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58, 19: 90]
        for (index, byte) in bytes.enumerated() {
            if let expected = separators[index] {
                guard byte == expected else { return nil }
            } else if !(48...57).contains(byte) { return nil }
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        let hour = number(11..<13), minute = number(14..<16), second = number(17..<19)
        guard year >= 1, (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { return nil }
        // Proleptic Gregorian arithmetic matches Python, without Foundation's 1582 cutover.
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let marchMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * marchMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    static func isValid(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds.rounded(.towardZero) == seconds &&
            seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }

    static func string(_ date: Date) -> String {
        let days = Int(floor(date.timeIntervalSince1970 / 86_400))
        let secondsOfDay = Int(date.timeIntervalSince1970 - Double(days * 86_400))
        let shiftedDays = days + 719_468
        let era = (shiftedDays >= 0 ? shiftedDays : shiftedDays - 146_096) / 146_097
        let dayOfEra = shiftedDays - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let marchMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * marchMonth + 2) / 5 + 1
        let month = marchMonth + (marchMonth < 10 ? 3 : -9)
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", locale: Locale(identifier: "en_US_POSIX"),
                      year, month, day, secondsOfDay / 3_600, secondsOfDay % 3_600 / 60, secondsOfDay % 60)
    }
}

func snapshotNormalized(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
        .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}

private struct SnapshotValidator {
    let snapshot: Snapshot

    func validate() throws {
        guard snapshot.schemaVersion == 1 else {
            throw SnapshotValidationError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        try require(UUID(uuidString: snapshot.storeID)?.uuidString.lowercased() == snapshot.storeID, "store_id")
        try require(snapshot.lastEventSeq >= 0, "last_event_seq")
        if snapshot.lastEventSeq == 0 {
            try require(snapshot.lastEventHash == nil && snapshot.generatedAt == nil, "空ストアの連番・ハッシュ・日時")
            try require(snapshot.lanes.isEmpty && snapshot.tasks.isEmpty && snapshot.decisions.isEmpty &&
                        snapshot.comments.isEmpty && snapshot.attachments.isEmpty, "空ストアのレコード")
            return
        }
        try require(snapshot.lastEventHash.map(validHash) == true, "last_event_hash")
        try require(snapshot.generatedAt.map(SnapshotTimestamp.isValid) == true, "generated_at")

        var allIDs = Set<String>()
        let groups: [(String, [String])] = [
            ("l", snapshot.lanes.map(\.id)), ("t", snapshot.tasks.map(\.id)),
            ("d", snapshot.decisions.map(\.id)), ("c", snapshot.comments.map(\.id)),
            ("a", snapshot.attachments.map(\.id))
        ]
        for (prefix, ids) in groups {
            for id in ids {
                try require(matches(id, "\(prefix)_[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}"), "id")
                guard allIDs.insert(id).inserted else { throw SnapshotValidationError.duplicateID(id) }
            }
        }
        let lanes = Dictionary(uniqueKeysWithValues: snapshot.lanes.map { ($0.id, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        let decisions = Dictionary(uniqueKeysWithValues: snapshot.decisions.map { ($0.id, $0) })
        let comments = Dictionary(uniqueKeysWithValues: snapshot.comments.map { ($0.id, $0) })
        var names = Set<String>()
        var maxRevision = 0
        var eventMetadata: [Int: (date: Date, actor: String)] = [:]
        func checkMetadata(_ sequence: Int, _ date: Date, _ actor: String) throws {
            if let known = eventMetadata[sequence] {
                try require(known.date == date && known.actor == actor, "同一イベントの日時・操作主体")
            }
            eventMetadata[sequence] = (date, actor)
            if sequence == snapshot.lastEventSeq {
                try require(date == snapshot.generatedAt, "最終イベントの日時")
            }
        }
        for lane in snapshot.lanes {
            try common(lane.createdAt, lane.createdBy, lane.updatedAt, lane.updatedBy, lane.revision)
            try text(lane.name, "name", required: true, limit: 512, singleLine: true)
            try text(lane.description, "description")
            try require(names.insert(snapshotNormalized(lane.name)).inserted, "同名レーン")
            maxRevision = max(maxRevision, lane.revision)
            try checkMetadata(lane.revision, lane.updatedAt, lane.updatedBy)
        }
        for task in snapshot.tasks {
            try common(task.createdAt, task.createdBy, task.updatedAt, task.updatedBy, task.revision)
            guard lanes[task.laneID] != nil else { throw SnapshotValidationError.missingReference(task.laneID) }
            if let parentID = task.parentID {
                guard let parent = tasks[parentID] else { throw SnapshotValidationError.missingReference(parentID) }
                try require(parent.laneID == task.laneID, "親タスクのレーン")
            }
            try text(task.title, "title", required: true, limit: 512, singleLine: true)
            try text(task.body, "body")
            try text(task.method, "method")
            try text(task.rationale, "rationale")
            if let assignee = task.assignee { try actor(assignee, "assignee") }
            if let dueAt = task.dueAt { try date(dueAt, "due_at") }
            if let amount = task.amount {
                try text(amount.value, "amount.value", required: true)
                try require(matches(amount.value, "(0|[1-9][0-9]*)(\\.[0-9]{1,6})?"), "amount.value")
                try require(matches(amount.currency, "[A-Z]{3}"), "amount.currency")
            }
            guard (task.status == .done) == (task.completion != nil) else {
                throw SnapshotValidationError.inconsistentState("task.completion")
            }
            if let completion = task.completion {
                try text(completion.evidence, "completion.evidence", required: true)
                try actor(completion.verifiedBy, "completion.verified_by")
                try date(completion.verifiedAt, "completion.verified_at")
            }
            maxRevision = max(maxRevision, task.revision)
            try checkMetadata(task.revision, task.updatedAt, task.updatedBy)
        }
        try parentCycles(tasks)
        for decision in snapshot.decisions {
            try common(decision.createdAt, decision.createdBy, decision.updatedAt, decision.updatedBy, decision.revision)
            guard let task = tasks[decision.taskID] else {
                throw SnapshotValidationError.missingReference(decision.taskID)
            }
            try require(task.laneID == decision.laneID, "裁定と元タスクのレーン")
            try text(decision.title, "title", required: true, limit: 512, singleLine: true)
            try text(decision.body, "body", required: true)
            try text(decision.reason, "reason", required: true)
            for option in decision.options { try text(option, "options", required: true) }
            if let dueAt = decision.dueAt { try date(dueAt, "due_at") }
            let validState: Bool
            switch decision.status {
            case .pending: validState = decision.answer == nil && decision.application == nil
            case .answered: validState = decision.answer != nil && decision.application == nil
            case .applied: validState = decision.answer != nil && decision.application != nil
            }
            guard validState else { throw SnapshotValidationError.inconsistentState("decision.answer/application") }
            if let answer = decision.answer {
                try text(answer.text, "answer.text", required: true)
                try actor(answer.respondent, "answer.respondent")
                try actor(answer.recordedBy, "answer.recorded_by")
                try date(answer.recordedAt, "answer.recorded_at")
            }
            if let application = decision.application {
                try text(application.evidence, "application.evidence", required: true)
                try actor(application.appliedBy, "application.applied_by")
                try date(application.appliedAt, "application.applied_at")
            }
            maxRevision = max(maxRevision, decision.revision)
            try checkMetadata(decision.revision, decision.updatedAt, decision.updatedBy)
        }
        try require(maxRevision == snapshot.lastEventSeq, "最終イベントとrevision")

        func ownerRevision(_ kind: String, _ id: String) throws -> Int {
            if kind == "task", let task = tasks[id] { return task.revision }
            if kind == "decision", let decision = decisions[id] { return decision.revision }
            throw SnapshotValidationError.missingReference(id)
        }
        var immutableSequences = Set<Int>()
        for comment in snapshot.comments {
            try event(comment.eventSeq, comment.createdAt, comment.createdBy)
            try require(immutableSequences.insert(comment.eventSeq).inserted, "追記・添付のevent_seq重複")
            try text(comment.body, "comment.body", required: true)
            let revision = try ownerRevision(comment.targetType.rawValue, comment.targetID)
            try require(revision >= comment.eventSeq, "追記先のrevision")
            try checkMetadata(comment.eventSeq, comment.createdAt, comment.createdBy)
        }
        var blobSizes: [String: Int] = [:]
        for attachment in snapshot.attachments {
            try event(attachment.eventSeq, attachment.createdAt, attachment.createdBy)
            try require(immutableSequences.insert(attachment.eventSeq).inserted, "追記・添付のevent_seq重複")
            let revision: Int
            if attachment.targetType == .comment {
                guard let comment = comments[attachment.targetID] else {
                    throw SnapshotValidationError.missingReference(attachment.targetID)
                }
                try require(attachment.eventSeq > comment.eventSeq, "追記と添付のevent_seq")
                revision = try ownerRevision(comment.targetType.rawValue, comment.targetID)
            } else {
                revision = try ownerRevision(attachment.targetType.rawValue, attachment.targetID)
            }
            try require(revision >= attachment.eventSeq, "添付先のrevision")
            try text(attachment.filename, "filename", required: true, limit: 255, singleLine: true)
            try require(attachment.filename != "." && attachment.filename != ".." &&
                        !attachment.filename.contains("/") && !attachment.filename.contains("\\"), "filename")
            try text(attachment.description, "description")
            try text(attachment.mediaType, "media_type", required: true, limit: 255, singleLine: true)
            let token = "[A-Za-z0-9!#$%&'*+.^_`|~-]+"
            try require(matches(attachment.mediaType, token + "/" + token), "media_type")
            try require((0...Snapshot.maximumByteCount).contains(attachment.sizeBytes), "size_bytes")
            try require(validHash(attachment.sha256), "sha256")
            try require(attachment.blobPath == "blobs/sha256/\(attachment.sha256.prefix(2))/\(attachment.sha256)", "blob_path")
            if let size = blobSizes[attachment.sha256] {
                try require(size == attachment.sizeBytes, "同一blobのサイズ")
            }
            blobSizes[attachment.sha256] = attachment.sizeBytes
            try checkMetadata(attachment.eventSeq, attachment.createdAt, attachment.createdBy)
        }
    }

    private func parentCycles(_ tasks: [String: TaskRecord]) throws {
        var completed = Set<String>()
        for task in snapshot.tasks where !completed.contains(task.id) {
            var visiting = Set<String>()
            var current: String? = task.id
            while let id = current, !completed.contains(id) {
                guard visiting.insert(id).inserted else { throw SnapshotValidationError.parentCycle(id) }
                current = tasks[id]?.parentID
            }
            completed.formUnion(visiting)
        }
    }

    private func common(_ createdAt: Date, _ createdBy: String, _ updatedAt: Date,
                        _ updatedBy: String, _ revision: Int) throws {
        try date(createdAt, "created_at")
        try actor(createdBy, "created_by")
        try date(updatedAt, "updated_at")
        try actor(updatedBy, "updated_by")
        try require(revision >= 1 && revision <= snapshot.lastEventSeq, "revision")
    }

    private func event(_ sequence: Int, _ createdAt: Date, _ createdBy: String) throws {
        try require(sequence >= 1 && sequence <= snapshot.lastEventSeq, "event_seq")
        try date(createdAt, "created_at")
        try actor(createdBy, "created_by")
    }

    private func date(_ value: Date, _ field: String) throws {
        try require(SnapshotTimestamp.isValid(value), field)
    }

    private func actor(_ value: String, _ field: String) throws {
        try text(value, field, required: true, limit: 128, singleLine: true)
    }

    private func text(_ value: String, _ field: String, required: Bool = false,
                      limit: Int = 65_536, singleLine: Bool = false) throws {
        try require(!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, field)
        try require(value.utf8.count <= limit, field)
        for scalar in value.unicodeScalars where scalar.properties.generalCategory == .control ||
            scalar.properties.generalCategory == .surrogate {
            try require(!singleLine && [9, 10, 13].contains(scalar.value), field)
        }
    }

    private func validHash(_ value: String) -> Bool {
        matches(value, "[0-9a-f]{64}")
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    private func require(_ condition: Bool, _ field: String) throws {
        guard condition else { throw SnapshotValidationError.invalidField(field) }
    }
}

