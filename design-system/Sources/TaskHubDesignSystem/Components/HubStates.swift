//
//  HubStates.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

public enum HubSyncState: Equatable, Sendable {
    case synced(lastUpdated: Date?)
    case syncing
    case offline(lastUpdated: Date?)
    case failed(message: String)

    public var title: String {
        switch self {
        case .synced: "同期済み"
        case .syncing: "同期中"
        case .offline: "オフライン・保存済みデータを表示"
        case .failed: "同期に失敗"
        }
    }

    public var systemImage: String {
        switch self {
        case .synced: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .failed: "exclamationmark.icloud"
        }
    }

    public var tone: HubTone {
        switch self {
        case .synced: .success
        case .syncing: .info
        case .offline: .warning
        case .failed: .danger
        }
    }

    public var canRetry: Bool {
        switch self {
        case .offline, .failed: true
        case .synced, .syncing: false
        }
    }
}

public struct HubSyncBanner: View {
    public let state: HubSyncState
    private let retry: (() -> Void)?

    public init(state: HubSyncState, retry: (() -> Void)? = nil) {
        self.state = state
        self.retry = retry
    }

    public var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: HubSpacing.xs) {
                Label { Text(verbatim: state.title) } icon: { Image(systemName: state.systemImage) }
                    .font(HubTypography.callout.weight(.semibold))
                    .foregroundStyle(state.tone.color)
                switch state {
                case .synced(let date), .offline(let date):
                    if let date {
                        (Text("最終同期：") + Text(date, format: .dateTime.year().month().day().hour().minute()))
                            .font(HubTypography.caption)
                            .foregroundStyle(HubColor.secondaryText)
                    } else {
                        Text("最終同期：未記録")
                            .font(HubTypography.caption)
                            .foregroundStyle(HubColor.secondaryText)
                    }
                case .syncing:
                    ProgressView("変更を確認中")
                        .font(HubTypography.caption)
                case .failed(let message):
                    Text(verbatim: message).font(HubTypography.callout)
                        .foregroundStyle(HubColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.canRetry, let retry {
                    HubButton(title: "再試行", systemImage: "arrow.clockwise", role: .secondary, action: retry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public struct HubEmptyState: View {
    public let title: String
    public let message: String
    public let systemImage: String
    public let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        message: String,
        systemImage: String = "tray",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: HubSpacing.sm) {
            Image(systemName: systemImage)
                .font(HubTypography.largeTitle)
                .foregroundStyle(HubColor.secondaryText)
                .accessibilityHidden(true)
            Text(verbatim: title).font(HubTypography.headline).foregroundStyle(HubColor.text)
            Text(verbatim: message).font(HubTypography.body).foregroundStyle(HubColor.secondaryText)
            if let actionTitle, let action {
                HubButton(title: actionTitle, role: .secondary, action: action)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(HubSpacing.lg)
    }
}

public struct HubErrorState: View {
    public let title: String
    public let message: String
    private let retry: (() -> Void)?

    public init(title: String = "読み込めませんでした", message: String, retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: HubSpacing.sm) {
                Label { Text(verbatim: title) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(HubTypography.headline)
                    .foregroundStyle(HubColor.danger)
                Text(verbatim: message)
                    .font(HubTypography.body)
                    .foregroundStyle(HubColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    HubButton(title: "再試行", systemImage: "arrow.clockwise", role: .secondary, action: retry)
                }
            }
        }
    }
}

public struct HubLoadingState: View {
    public let title: String

    public init(title: String = "読み込み中") {
        self.title = title
    }

    public var body: some View {
        ProgressView { Text(verbatim: title) }
            .font(HubTypography.callout)
            .tint(HubColor.accent)
            .frame(maxWidth: .infinity)
            .padding(HubSpacing.lg)
    }
}
