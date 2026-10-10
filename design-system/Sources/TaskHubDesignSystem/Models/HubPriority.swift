//
//  HubPriority.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

/// タスクの表示用優先度。
public enum HubPriority: String, CaseIterable, Identifiable, Sendable {
    case low
    case normal
    case high
    case urgent

    public var id: String { rawValue }

    /// 日本語の優先度名。
    public var title: String {
        switch self {
        case .low: "低"
        case .normal: "通常"
        case .high: "高"
        case .urgent: "緊急"
        }
    }

    /// 優先度名と併記するSF Symbol。
    public var systemImage: String {
        switch self {
        case .low: "arrow.down.circle"
        case .normal: "minus.circle"
        case .high: "arrow.up.circle"
        case .urgent: "exclamationmark.triangle"
        }
    }

    /// 色だけに依存しない優先度表示の補助色。
    public var tone: HubTone {
        switch self {
        case .low, .normal: .neutral
        case .high: .warning
        case .urgent: .danger
        }
    }
}
