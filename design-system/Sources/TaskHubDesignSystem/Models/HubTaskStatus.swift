//
//  HubTaskStatus.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

/// タスクの表示状態。通信形式とは独立した値。
public enum HubTaskStatus: String, CaseIterable, Identifiable, Sendable {
    case notStarted
    case inProgress
    case needsReview
    case blocked
    case completed
    case onHold

    public var id: String { rawValue }

    /// 日本語の状態名。
    public var title: String {
        switch self {
        case .notStarted: "未着手"
        case .inProgress: "進行中"
        case .needsReview: "ユーザー確認待ち"
        case .blocked: "ブロック"
        case .completed: "完了"
        case .onHold: "保留"
        }
    }

    /// 状態名と併記するSF Symbol。
    public var systemImage: String {
        switch self {
        case .notStarted: "circle"
        case .inProgress: "play.circle"
        case .needsReview: "questionmark.bubble"
        case .blocked: "hand.raised"
        case .completed: "checkmark.circle"
        case .onHold: "pause.circle"
        }
    }

    /// 色だけに依存しない状態表示の補助色。
    public var tone: HubTone {
        switch self {
        case .notStarted, .onHold: .neutral
        case .inProgress: .info
        case .needsReview: .warning
        case .blocked: .danger
        case .completed: .success
        }
    }
}
