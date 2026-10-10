//
//  Presentation.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import SwiftUI
import TaskHubDesignSystem
import TaskHubMacCore

extension TaskStatus {
    var presentation: HubTaskStatus {
        switch rawValue {
        case "in_progress": .inProgress
        case "awaiting_user": .needsReview
        case "blocked": .blocked
        case "done": .completed
        case "on_hold": .onHold
        default: .notStarted
        }
    }
}

extension DecisionStatus {
    var presentation: HubDecisionStatus {
        switch rawValue {
        case "answered": .answered
        case "applied": .applied
        default: .pending
        }
    }
}

extension Snapshot {
    func lane(_ id: String) -> HubLane {
        HubLane(id: id, name: lanes.first { $0.id == id }?.name ?? id)
    }

    func summary(_ task: TaskRecord) -> HubTaskSummary {
        let children = tasks.filter { $0.parentID == task.id }
        return HubTaskSummary(id: task.id, title: task.title, status: task.status.presentation,
            lane: lane(task.laneID), priority: HubPriority(rawValue: task.priority.rawValue) ?? .normal,
            assignee: task.assignee, dueDate: task.dueAt, updatedBy: task.updatedBy, updatedAt: task.updatedAt,
            subtaskCount: children.count, completedSubtaskCount: children.filter { $0.status.rawValue == "done" }.count,
            evidence: task.completion?.evidence)
    }

    func summary(_ decision: DecisionRecord) -> HubDecisionSummary {
        HubDecisionSummary(id: decision.id, title: decision.title, taskID: decision.taskID,
            lane: lane(decision.laneID), status: decision.status.presentation, options: decision.options,
            reason: decision.reason, dueDate: decision.dueAt, registeredBy: decision.createdBy,
            registeredAt: decision.createdAt, reply: decision.answer?.text)
    }
}

extension AttachmentRecord {
    var presentation: HubAttachment {
        HubAttachment(id: id, fileName: filename, description: description, registeredBy: createdBy,
            registeredAt: createdAt, systemImage: mediaType.hasPrefix("image/") ? "photo" : "doc")
    }
}

func dateText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpacing.lg) { content }
                .frame(maxWidth: HubMetrics.readingWidth, alignment: .leading)
                .padding(HubSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(HubColor.canvas)
        .textSelection(.enabled)
    }
}

struct Heading: View {
    let title: String
    var body: some View {
        Text(verbatim: title).font(HubTypography.title).accessibilityAddTraits(.isHeader)
    }
}
