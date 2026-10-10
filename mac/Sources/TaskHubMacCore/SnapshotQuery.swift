//
//  SnapshotQuery.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public struct TaskFilter: Codable, Equatable, Sendable {
    public var text: String
    public var laneID: String?
    public var statuses: Set<TaskStatus>
    public var assignee: String?
    public var updatedSince: Date?
    public var updatedUntil: Date?

    public init(text: String = "", laneID: String? = nil, statuses: Set<TaskStatus> = [],
                assignee: String? = nil, updatedSince: Date? = nil, updatedUntil: Date? = nil) {
        self.text = text
        self.laneID = laneID
        self.statuses = statuses
        self.assignee = assignee
        self.updatedSince = updatedSince
        self.updatedUntil = updatedUntil
    }
}

public struct DecisionFilter: Codable, Equatable, Sendable {
    public var text: String
    public var laneID: String?
    public var statuses: Set<DecisionStatus>
    public var assignee: String?
    public var updatedSince: Date?
    public var updatedUntil: Date?

    public init(text: String = "", laneID: String? = nil, statuses: Set<DecisionStatus> = [],
                assignee: String? = nil, updatedSince: Date? = nil, updatedUntil: Date? = nil) {
        self.text = text
        self.laneID = laneID
        self.statuses = statuses
        self.assignee = assignee
        self.updatedSince = updatedSince
        self.updatedUntil = updatedUntil
    }
}

public struct SearchMatch: Codable, Equatable, Hashable, Sendable {
    public var field: String
    public var commentID: String?
    public var attachmentID: String?

    public init(field: String, commentID: String? = nil, attachmentID: String? = nil) {
        self.field = field
        self.commentID = commentID
        self.attachmentID = attachmentID
    }
}

public struct TaskSearchResult: Equatable, Sendable, Identifiable {
    public var id: String { task.id }
    public let task: TaskRecord
    public let matches: [SearchMatch]
}

public struct DecisionSearchResult: Equatable, Sendable, Identifiable {
    public var id: String { decision.id }
    public let decision: DecisionRecord
    public let matches: [SearchMatch]
}

public enum DigestItemKind: String, Codable, Equatable, Sendable {
    case task, decision
}

public struct DigestItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: DigestItemKind
    public let laneID: String
    public let taskID: String?
    public let title: String
    public let dueAt: Date?
}

public struct DuplicateTitleGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String { laneID + ":" + normalizedTitle }
    public let laneID: String
    public let normalizedTitle: String
    public let tasks: [DigestItem]
}

public struct SnapshotDigest: Equatable, Sendable {
    public let asOf: Date
    public let overdue: [DigestItem]
    public let upcoming: [DigestItem]
    public let stale: [DigestItem]
    public let duplicateTitles: [DuplicateTitleGroup]
    public let openDecisions: [DigestItem]

    public var japaneseSummary: String {
        var lines: [String] = []
        for (label, items) in [("期限切れ", overdue), ("期限間近", upcoming), ("停滞", stale)] {
            lines.append("\(label): \(items.count)件")
            lines.append(contentsOf: items.map(digestLine))
        }
        lines.append("重複候補: \(duplicateTitles.count)件")
        for group in duplicateTitles {
            lines.append("- \(group.laneID) / \(group.normalizedTitle)（\(group.tasks.count)件）")
            lines.append(contentsOf: group.tasks.map { "  " + digestLine($0) })
        }
        lines.append("ユーザー裁定: \(openDecisions.count)件")
        lines.append(contentsOf: openDecisions.map(digestLine))
        return lines.joined(separator: "\n")
    }
}

public struct SnapshotQuery: Sendable {
    public let snapshot: Snapshot
    private let tasksByID: [String: TaskRecord]
    private let commentsByOwner: [String: [CommentRecord]]
    private let attachmentsByOwner: [String: [AttachmentRecord]]
    private let commentsByID: [String: CommentRecord]

    public init(snapshot: Snapshot) {
        self.snapshot = snapshot
        tasksByID = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commentsByID = Dictionary(snapshot.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        commentsByOwner = Dictionary(grouping: snapshot.comments, by: \.targetID)
        var attachments: [String: [AttachmentRecord]] = [:]
        for attachment in snapshot.attachments {
            let ownerID: String?
            if attachment.targetType == .comment {
                ownerID = commentsByID[attachment.targetID]?.targetID
            } else {
                ownerID = attachment.targetID
            }
            if let ownerID { attachments[ownerID, default: []].append(attachment) }
        }
        attachmentsByOwner = attachments
    }

    public func tasks(matching filter: TaskFilter = .init()) -> [TaskSearchResult] {
        let needle = searchNeedle(filter.text)
        return snapshot.tasks.sorted { $0.id < $1.id }.compactMap { task in
            guard filter.laneID == nil || task.laneID == filter.laneID,
                  filter.statuses.isEmpty || filter.statuses.contains(task.status),
                  filter.assignee == nil || task.assignee == filter.assignee,
                  includesDate(task.updatedAt, since: filter.updatedSince, until: filter.updatedUntil) else { return nil }
            guard let needle else { return TaskSearchResult(task: task, matches: []) }
            var fields = [("title", task.title), ("body", task.body), ("method", task.method), ("rationale", task.rationale)]
            if let completion = task.completion { fields.append(("completion.evidence", completion.evidence)) }
            let matches = matches(ownerID: task.id, fields: fields, needle: needle)
            return matches.isEmpty ? nil : TaskSearchResult(task: task, matches: matches)
        }
    }

    public func decisions(matching filter: DecisionFilter = .init()) -> [DecisionSearchResult] {
        let needle = searchNeedle(filter.text)
        return snapshot.decisions.sorted { $0.id < $1.id }.compactMap { decision in
            guard filter.laneID == nil || decision.laneID == filter.laneID,
                  filter.statuses.isEmpty || filter.statuses.contains(decision.status),
                  filter.assignee == nil || tasksByID[decision.taskID]?.assignee == filter.assignee,
                  includesDate(decision.updatedAt, since: filter.updatedSince, until: filter.updatedUntil) else { return nil }
            guard let needle else { return DecisionSearchResult(decision: decision, matches: []) }
            var fields = [("title", decision.title), ("body", decision.body), ("reason", decision.reason)]
            fields.append(contentsOf: decision.options.map { ("options", $0) })
            if let answer = decision.answer { fields.append(("answer.text", answer.text)) }
            if let application = decision.application { fields.append(("application.evidence", application.evidence)) }
            let matches = matches(ownerID: decision.id, fields: fields, needle: needle)
            return matches.isEmpty ? nil : DecisionSearchResult(decision: decision, matches: matches)
        }
    }

    public func digest(now: Date) -> SnapshotDigest {
        var active: [(item: DigestItem, updatedAt: Date)] = snapshot.tasks.filter { $0.status != .done }.map {
            (DigestItem(id: $0.id, kind: .task, laneID: $0.laneID, taskID: nil, title: $0.title, dueAt: $0.dueAt), $0.updatedAt)
        }
        active.append(contentsOf: snapshot.decisions.filter { $0.status != .applied }.map {
            (DigestItem(id: $0.id, kind: .decision, laneID: $0.laneID, taskID: $0.taskID, title: $0.title, dueAt: $0.dueAt), $0.updatedAt)
        })
        let upcomingLimit = now.addingTimeInterval(72 * 3_600)
        let staleLimit = now.addingTimeInterval(-7 * 86_400)
        let overdue = active.compactMap { entry in entry.item.dueAt.map { $0 < now } == true ? entry.item : nil }
        let upcoming = active.compactMap { entry in
            entry.item.dueAt.map { $0 >= now && $0 <= upcomingLimit } == true ? entry.item : nil
        }
        let stale = active.filter { $0.updatedAt <= staleLimit }.map(\.item)
        let openDecisions = active.map(\.item).filter { $0.kind == .decision }
        var groups: [DuplicateKey: [DigestItem]] = [:]
        for entry in active where entry.item.kind == .task {
            let title = snapshotNormalized(entry.item.title).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = DuplicateKey(laneID: entry.item.laneID, title: title)
            groups[key, default: []].append(entry.item)
        }
        let duplicateTitles = groups.compactMap { key, items -> DuplicateTitleGroup? in
            guard items.count > 1 else { return nil }
            return DuplicateTitleGroup(laneID: key.laneID, normalizedTitle: key.title, tasks: items.sorted(by: digestOrder))
        }.sorted { digestOrder($0.tasks[0], $1.tasks[0]) }
        return SnapshotDigest(asOf: now, overdue: overdue.sorted(by: digestOrder), upcoming: upcoming.sorted(by: digestOrder),
                              stale: stale.sorted(by: digestOrder), duplicateTitles: duplicateTitles,
                              openDecisions: openDecisions.sorted(by: digestOrder))
    }

    private func matches(ownerID: String, fields: [(String, String)], needle: String) -> [SearchMatch] {
        var result = Set<SearchMatch>()
        for (field, value) in fields where snapshotNormalized(value).contains(needle) {
            result.insert(SearchMatch(field: field))
        }
        for comment in commentsByOwner[ownerID] ?? [] where snapshotNormalized(comment.body).contains(needle) {
            result.insert(SearchMatch(field: "body", commentID: comment.id))
        }
        for attachment in attachmentsByOwner[ownerID] ?? [] {
            for (field, value) in [("filename", attachment.filename), ("description", attachment.description)]
                where snapshotNormalized(value).contains(needle) {
                result.insert(SearchMatch(field: field,
                                          commentID: attachment.targetType == .comment ? attachment.targetID : nil,
                                          attachmentID: attachment.id))
            }
        }
        return result.sorted {
            ($0.commentID ?? "", $0.attachmentID ?? "", $0.field) < ($1.commentID ?? "", $1.attachmentID ?? "", $1.field)
        }
    }
}

private struct DuplicateKey: Hashable {
    let laneID: String
    let title: String
}

private func searchNeedle(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : snapshotNormalized(text)
}

private func includesDate(_ date: Date, since: Date?, until: Date?) -> Bool {
    (since == nil || date >= since!) && (until == nil || date < until!)
}

private func digestOrder(_ lhs: DigestItem, _ rhs: DigestItem) -> Bool {
    if lhs.dueAt != rhs.dueAt {
        if let leftDate = lhs.dueAt, let rightDate = rhs.dueAt { return leftDate < rightDate }
        return lhs.dueAt != nil
    }
    return lhs.id < rhs.id
}

private func digestLine(_ item: DigestItem) -> String {
    let kind = item.kind == .task ? "タスク" : "裁定"
    let due = item.dueAt.map(SnapshotTimestamp.string) ?? "期限なし"
    return "- \(kind) \(item.id) \(item.title)（\(due)）"
}
