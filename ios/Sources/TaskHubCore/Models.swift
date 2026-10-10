//
//  Models.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public enum TaskStatus: String, CaseIterable, Codable, Sendable {
    case todo
    case inProgress = "in_progress"
    case awaitingUser = "awaiting_user"
    case blocked
    case done
    case onHold = "on_hold"
}

public enum DecisionStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case answered
    case applied
}

public enum Priority: String, CaseIterable, Codable, Sendable {
    case low
    case normal
    case high
    case urgent
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var storeID: String
    public var lastEventSeq: Int
    public var lastEventHash: String?
    public var generatedAt: Date?
    public var lanes: [LaneRecord]
    public var tasks: [HubTaskRecord]
    public var decisions: [HubDecisionRecord]
    public var comments: [CommentRecord]
    public var attachments: [AttachmentRecord]

    public init(
        schemaVersion: Int,
        storeID: String,
        lastEventSeq: Int,
        lastEventHash: String?,
        generatedAt: Date?,
        lanes: [LaneRecord],
        tasks: [HubTaskRecord],
        decisions: [HubDecisionRecord],
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

    enum CodingKeys: String, CodingKey {
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
        generatedAt = try container.decode(Date?.self, forKey: .generatedAt)
        lanes = try container.decode([LaneRecord].self, forKey: .lanes)
        tasks = try container.decode([HubTaskRecord].self, forKey: .tasks)
        decisions = try container.decode([HubDecisionRecord].self, forKey: .decisions)
        comments = try container.decode([CommentRecord].self, forKey: .comments)
        attachments = try container.decode([AttachmentRecord].self, forKey: .attachments)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(storeID, forKey: .storeID)
        try container.encode(lastEventSeq, forKey: .lastEventSeq)
        try container.encode(lastEventHash, forKey: .lastEventHash)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(lanes, forKey: .lanes)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(comments, forKey: .comments)
        try container.encode(attachments, forKey: .attachments)
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

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case updatedBy = "updated_by"
        case revision
    }
}

public struct HubTaskRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var laneID: String
    public var parentID: String?
    public var title: String
    public var body: String
    public var status: TaskStatus
    public var priority: Priority
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
        priority: Priority,
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

    enum CodingKeys: String, CodingKey {
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
        priority = try container.decode(Priority.self, forKey: .priority)
        dueAt = try container.decode(Date?.self, forKey: .dueAt)
        assignee = try container.decode(String?.self, forKey: .assignee)
        amount = try container.decode(Money?.self, forKey: .amount)
        method = try container.decode(String.self, forKey: .method)
        rationale = try container.decode(String.self, forKey: .rationale)
        completion = try container.decode(Completion?.self, forKey: .completion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
        try container.encode(dueAt, forKey: .dueAt)
        try container.encode(assignee, forKey: .assignee)
        try container.encode(amount, forKey: .amount)
        try container.encode(method, forKey: .method)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(completion, forKey: .completion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(updatedBy, forKey: .updatedBy)
        try container.encode(revision, forKey: .revision)
    }
}

public struct HubDecisionRecord: Codable, Equatable, Sendable, Identifiable {
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

    enum CodingKeys: String, CodingKey {
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
        dueAt = try container.decode(Date?.self, forKey: .dueAt)
        status = try container.decode(DecisionStatus.self, forKey: .status)
        answer = try container.decode(Answer?.self, forKey: .answer)
        application = try container.decode(Application?.self, forKey: .application)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdBy = try container.decode(String.self, forKey: .createdBy)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
        try container.encode(dueAt, forKey: .dueAt)
        try container.encode(status, forKey: .status)
        try container.encode(answer, forKey: .answer)
        try container.encode(application, forKey: .application)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(createdBy, forKey: .createdBy)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(updatedBy, forKey: .updatedBy)
        try container.encode(revision, forKey: .revision)
    }
}

public struct CommentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var targetType: String
    public var targetID: String
    public var body: String
    public var createdAt: Date
    public var createdBy: String
    public var eventSeq: Int

    public init(
        id: String,
        targetType: String,
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

    enum CodingKeys: String, CodingKey {
        case id
        case targetType = "target_type"
        case targetID = "target_id"
        case body
        case createdAt = "created_at"
        case createdBy = "created_by"
        case eventSeq = "event_seq"
    }
}

public struct AttachmentRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var targetType: String
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
        targetType: String,
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

    enum CodingKeys: String, CodingKey {
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

    enum CodingKeys: String, CodingKey {
        case value
        case currency
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

    enum CodingKeys: String, CodingKey {
        case evidence
        case verifiedBy = "verified_by"
        case verifiedAt = "verified_at"
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

    enum CodingKeys: String, CodingKey {
        case text
        case respondent
        case recordedBy = "recorded_by"
        case recordedAt = "recorded_at"
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

    enum CodingKeys: String, CodingKey {
        case evidence
        case appliedBy = "applied_by"
        case appliedAt = "applied_at"
        case resumedTask = "resumed_task"
    }
}
