//
//  Queries.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public struct BrowseFilter: Equatable, Sendable {
    public var query: String = ""
    public var laneID: String? = nil
    public var taskStatus: TaskStatus? = nil
    public var decisionStatus: DecisionStatus? = nil
    public var assignee: String? = nil
    public var since: Date? = nil
    public var until: Date? = nil

    public init() {}
}

public struct DigestSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let taskIDs: [String]
    public let decisionIDs: [String]

    public init(id: String, title: String, summary: String, taskIDs: [String], decisionIDs: [String]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.taskIDs = taskIDs
        self.decisionIDs = decisionIDs
    }
}

extension Snapshot {
    public func task(id: String) -> HubTaskRecord? { tasks.first { $0.id == id } }
    public func lane(id: String) -> LaneRecord? { lanes.first { $0.id == id } }
    public func decision(id: String) -> HubDecisionRecord? { decisions.first { $0.id == id } }

    public func comments(targetType: String, targetID: String) -> [CommentRecord] {
        comments.filter { $0.targetType == targetType && $0.targetID == targetID }
            .sorted { ($0.eventSeq, $0.id) < ($1.eventSeq, $1.id) }
    }

    public func attachments(targetType: String, targetID: String) -> [AttachmentRecord] {
        attachments.filter { $0.targetType == targetType && $0.targetID == targetID }
            .sorted { ($0.eventSeq, $0.id) < ($1.eventSeq, $1.id) }
    }

    public func filteredTasks(_ filter: BrowseFilter) -> [HubTaskRecord] {
        let needle = searchNeedle(filter.query)
        let related = relatedMatches(needle: needle, targetType: "task")
        return tasks.filter { task in
            (filter.laneID == nil || task.laneID == filter.laneID) &&
            (filter.taskStatus == nil || task.status == filter.taskStatus) &&
            (filter.assignee == nil || task.assignee == filter.assignee) &&
            withinPeriod(task.updatedAt, filter) &&
            (needle.isEmpty || related.contains(task.id) ||
             [task.title, task.body, task.method, task.rationale, task.completion?.evidence ?? ""]
                .contains { normalizedForSearch($0).contains(needle) })
        }.sorted { dueOrder($0.dueAt, $0.id, $1.dueAt, $1.id) }
    }

    public func filteredDecisions(_ filter: BrowseFilter) -> [HubDecisionRecord] {
        let needle = searchNeedle(filter.query)
        let related = relatedMatches(needle: needle, targetType: "decision")
        let assignees = Dictionary(tasks.map { ($0.id, $0.assignee) }, uniquingKeysWith: { first, _ in first })
        return decisions.filter { decision in
            (filter.laneID == nil || decision.laneID == filter.laneID) &&
            (filter.decisionStatus == nil || decision.status == filter.decisionStatus) &&
            (filter.assignee == nil || assignees[decision.taskID] == filter.assignee) &&
            withinPeriod(decision.updatedAt, filter) &&
            (needle.isEmpty || related.contains(decision.id) ||
             ([decision.title, decision.body, decision.reason, decision.answer?.text ?? "",
               decision.application?.evidence ?? ""] + decision.options)
                .contains { normalizedForSearch($0).contains(needle) })
        }.sorted { dueOrder($0.dueAt, $0.id, $1.dueAt, $1.id) }
    }

    public func digest(now: Date) -> [DigestSection] {
        let activeTasks = tasks.filter { $0.status != .done }
            .sorted { dueOrder($0.dueAt, $0.id, $1.dueAt, $1.id) }
        let openDecisions = decisions.filter { $0.status != .applied }
            .sorted { dueOrder($0.dueAt, $0.id, $1.dueAt, $1.id) }
        let upcoming = now.addingTimeInterval(72 * 3_600)
        let stale = now.addingTimeInterval(-7 * 86_400)

        func section(_ id: String, _ title: String, tasks: [HubTaskRecord], decisions: [HubDecisionRecord],
                     summary: String? = nil) -> DigestSection {
            DigestSection(id: id, title: title,
                          summary: summary ?? "\(title)：\(tasks.count + decisions.count)件（タスク\(tasks.count)件・裁定\(decisions.count)件）。",
                          taskIDs: tasks.map(\.id), decisionIDs: decisions.map(\.id))
        }

        struct DuplicateKey: Hashable {
            let laneID: String
            let title: String
        }
        let groups = Dictionary(grouping: activeTasks) {
            DuplicateKey(laneID: $0.laneID, title: normalizedForSearch($0.title).split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }.values.filter { $0.count > 1 }
        let duplicates = groups.flatMap { $0 }.sorted { dueOrder($0.dueAt, $0.id, $1.dueAt, $1.id) }
        let pendingCount = openDecisions.filter { $0.status == .pending }.count
        let answeredCount = openDecisions.count - pendingCount
        return [
            section("overdue", "期限切れ", tasks: activeTasks.filter { $0.dueAt.map { $0 < now } ?? false },
                    decisions: openDecisions.filter { $0.dueAt.map { $0 < now } ?? false }),
            section("upcoming", "期限間近", tasks: activeTasks.filter { $0.dueAt.map { $0 >= now && $0 <= upcoming } ?? false },
                    decisions: openDecisions.filter { $0.dueAt.map { $0 >= now && $0 <= upcoming } ?? false }),
            section("stale", "停滞", tasks: activeTasks.filter { $0.updatedAt <= stale },
                    decisions: openDecisions.filter { $0.updatedAt <= stale }),
            section("duplicates", "重複候補", tasks: duplicates, decisions: [],
                    summary: "重複候補：\(groups.count)組・\(duplicates.count)件。同一レーンの未完了タスクで正規化したタイトルが一致。"),
            section("decisions", "ユーザー裁定", tasks: [], decisions: openDecisions,
                    summary: "未反映の裁定：\(openDecisions.count)件（未対応\(pendingCount)件・回答済み\(answeredCount)件）。")
        ]
    }

    private func relatedMatches(needle: String, targetType: String) -> Set<String> {
        guard !needle.isEmpty else { return [] }
        let relatedComments = comments.filter { $0.targetType == targetType }
        let commentOwners = Dictionary(relatedComments.map { ($0.id, $0.targetID) }, uniquingKeysWith: { first, _ in first })
        var result = Set(relatedComments.filter { normalizedForSearch($0.body).contains(needle) }.map(\.targetID))
        for attachment in attachments where
            normalizedForSearch(attachment.filename).contains(needle) || normalizedForSearch(attachment.description).contains(needle) {
            if attachment.targetType == targetType {
                result.insert(attachment.targetID)
            } else if attachment.targetType == "comment", let owner = commentOwners[attachment.targetID] {
                result.insert(owner)
            }
        }
        return result
    }
}

func normalizedForSearch(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}

private func searchNeedle(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : normalizedForSearch(value)
}

private func withinPeriod(_ date: Date, _ filter: BrowseFilter) -> Bool {
    (filter.since == nil || date >= filter.since!) && (filter.until == nil || date < filter.until!)
}

private func dueOrder(_ lhsDate: Date?, _ lhsID: String, _ rhsDate: Date?, _ rhsID: String) -> Bool {
    switch (lhsDate, rhsDate) {
    case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
    case (_?, nil): return true
    case (nil, _?): return false
    default: return lhsID < rhsID
    }
}
