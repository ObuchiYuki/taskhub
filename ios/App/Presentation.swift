//
//  Presentation.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import UIKit
import TaskHubCore
import TaskHubDesignSystem

extension TaskStatus {
    var display: HubTaskStatus {
        switch self {
        case .todo: .notStarted
        case .inProgress: .inProgress
        case .awaitingUser: .needsReview
        case .blocked: .blocked
        case .done: .completed
        case .onHold: .onHold
        }
    }
}

extension DecisionStatus {
    var display: HubDecisionStatus {
        switch self {
        case .pending: .pending
        case .answered: .answered
        case .applied: .applied
        }
    }
}

extension Priority {
    var display: HubPriority {
        switch self {
        case .low: .low
        case .normal: .normal
        case .high: .high
        case .urgent: .urgent
        }
    }
}

extension Snapshot {
    func displayLane(_ id: String) -> HubLane {
        HubLane(id: id, name: lane(id: id)?.name ?? id)
    }

    func displayTask(_ task: HubTaskRecord) -> HubTaskSummary {
        let children = tasks.filter { $0.parentID == task.id }
        return HubTaskSummary(
            id: task.id, title: task.title, status: task.status.display, lane: displayLane(task.laneID),
            priority: task.priority.display, assignee: task.assignee, dueDate: task.dueAt,
            updatedBy: task.updatedBy, updatedAt: task.updatedAt, subtaskCount: children.count,
            completedSubtaskCount: children.filter { $0.status == .done }.count, evidence: task.completion?.evidence
        )
    }

    func displayDecision(_ decision: HubDecisionRecord) -> HubDecisionSummary {
        HubDecisionSummary(
            id: decision.id, title: decision.title, taskID: decision.taskID, lane: displayLane(decision.laneID),
            status: decision.status.display, options: decision.options, reason: decision.reason,
            dueDate: decision.dueAt, registeredBy: decision.createdBy, registeredAt: decision.createdAt,
            reply: decision.answer?.text
        )
    }
}

extension AttachmentRecord {
    var display: HubAttachment {
        HubAttachment(id: id, fileName: filename, description: description, registeredBy: createdBy,
                      registeredAt: createdAt, systemImage: mediaType.hasPrefix("image/") ? "photo" : "doc")
    }
}

@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

func formattedDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute())
}
