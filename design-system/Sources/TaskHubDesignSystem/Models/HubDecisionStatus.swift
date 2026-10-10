//
//  HubDecisionStatus.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

/// ユーザー裁定の表示状態。通信形式とは独立した値。
public enum HubDecisionStatus: String, CaseIterable, Identifiable, Sendable {
    case pending
    case answered
    case applied

    public var id: String { rawValue }

    /// 日本語の状態名。
    public var title: String {
        switch self {
        case .pending: "未対応"
        case .answered: "回答済み"
        case .applied: "反映済み"
        }
    }

    /// 状態名と併記するSF Symbol。
    public var systemImage: String {
        switch self {
        case .pending: "questionmark.circle"
        case .answered: "text.bubble"
        case .applied: "checkmark.circle"
        }
    }

    /// 色だけに依存しない状態表示の補助色。
    public var tone: HubTone {
        switch self {
        case .pending: .warning
        case .answered: .info
        case .applied: .success
        }
    }
}
