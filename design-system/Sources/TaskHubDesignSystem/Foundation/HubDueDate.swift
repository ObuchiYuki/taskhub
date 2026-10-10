//
//  HubDueDate.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public enum HubDueState: CaseIterable, Sendable {
    case unspecified, overdue, dueSoon, scheduled, resolved

    public var title: String {
        switch self {
        case .unspecified: "期限なし"
        case .overdue: "期限切れ"
        case .dueSoon: "期限間近"
        case .scheduled: "期限"
        case .resolved: "対応済みの期限"
        }
    }

    public var systemImage: String {
        switch self {
        case .unspecified: "calendar"
        case .overdue: "exclamationmark.circle"
        case .dueSoon: "clock"
        case .scheduled, .resolved: "calendar"
        }
    }

    /// Dates are instants; applications convert date-only deadlines before presentation.
    public static func classify(
        date: Date?,
        now: Date,
        isResolved: Bool = false,
        warningInterval: TimeInterval = 86_400
    ) -> HubDueState {
        guard let date else { return .unspecified }
        if isResolved { return .resolved }
        if date < now { return .overdue }
        return date.timeIntervalSince(now) <= max(0, warningInterval) ? .dueSoon : .scheduled
    }
}
