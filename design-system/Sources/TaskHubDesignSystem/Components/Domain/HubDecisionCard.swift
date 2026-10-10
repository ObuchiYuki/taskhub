//
//  HubDecisionCard.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

/// 裁定内容の読み取り専用カード。回答や画面遷移の操作を内包しない。
public struct HubDecisionCard: View {
    public let decision: HubDecisionSummary
    /// 期限判定の基準時刻。自動更新は呼び出し側が行う。
    public let now: Date

    public init(decision: HubDecisionSummary, now: Date = Date()) {
        self.decision = decision
        self.now = now
    }

    public var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: HubSpacing.md) {
                VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                    Text(verbatim: decision.title)
                        .font(HubTypography.headline)
                        .foregroundStyle(HubColor.text)

                    if !decision.title.contains(decision.id) {
                        Text(verbatim: decision.id)
                            .font(HubTypography.identifier)
                            .foregroundStyle(HubColor.secondaryText)
                            .accessibilityLabel(Text("裁定ID \(decision.id)"))
                    }
                }

                HubBadge(
                    title: decision.status.title,
                    systemImage: decision.status.systemImage,
                    tone: decision.status.tone
                )

                VStack(alignment: .leading, spacing: HubSpacing.xs) {
                    HubLaneLabel(lane: decision.lane)
                    HubMetadata(label: "元タスク", value: decision.taskID, systemImage: "number")

                    if let registeredBy = decision.registeredBy {
                        HubMetadata(label: "登録者", value: registeredBy, systemImage: "person.crop.circle")
                    }

                    if let registeredAt = decision.registeredAt {
                        Text("登録日時 \(registeredAt, format: .dateTime.year().month().day().hour().minute())")
                            .font(HubTypography.caption)
                            .foregroundStyle(HubColor.secondaryText)
                    }

                    HubDueLabel(date: decision.dueDate, now: now, isResolved: decision.status != .pending)
                }

                VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                    Text("理由")
                        .font(HubTypography.caption)
                        .foregroundStyle(HubColor.secondaryText)
                    Text(verbatim: decision.reason)
                        .font(HubTypography.body)
                        .foregroundStyle(HubColor.text)
                }

                if !decision.options.isEmpty {
                    VStack(alignment: .leading, spacing: HubSpacing.xs) {
                        Text("選択肢")
                            .font(HubTypography.caption)
                            .foregroundStyle(HubColor.secondaryText)

                        ForEach(Array(decision.options.enumerated()), id: \.offset) { index, option in
                            HStack(alignment: .top, spacing: HubSpacing.xs) {
                                Text(verbatim: "\(index + 1).")
                                    .foregroundStyle(HubColor.secondaryText)
                                Text(verbatim: option)
                                    .foregroundStyle(HubColor.text)
                            }
                            .font(HubTypography.body)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if let reply = decision.reply {
                    VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                        Label("ユーザーの回答", systemImage: "text.bubble")
                            .font(HubTypography.caption)
                            .foregroundStyle(HubColor.secondaryText)
                        Text(verbatim: reply)
                            .font(HubTypography.body)
                            .foregroundStyle(HubColor.text)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}
