//
//  HubTaskRow.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

/// タスクの読み取り専用行。選択と画面遷移は呼び出し側が管理する。
public struct HubTaskRow: View {
    public let task: HubTaskSummary
    /// 期限判定の基準時刻。自動更新は呼び出し側が行う。
    public let now: Date

    public init(task: HubTaskSummary, now: Date = Date()) {
        self.task = task
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HubSpacing.sm) {
            VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                Text(verbatim: task.title)
                    .font(HubTypography.headline)
                    .foregroundStyle(HubColor.text)

                if !task.title.contains(task.id) {
                    Text(verbatim: task.id)
                        .font(HubTypography.identifier)
                        .foregroundStyle(HubColor.secondaryText)
                        .accessibilityLabel(Text("タスクID \(task.id)"))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: HubSpacing.xs) {
                    statusBadge
                    priorityBadge
                }
                .fixedSize(horizontal: true, vertical: true)

                VStack(alignment: .leading, spacing: HubSpacing.xs) {
                    statusBadge
                    priorityBadge
                }
            }

            HubLaneLabel(lane: task.lane)

            VStack(alignment: .leading, spacing: HubSpacing.xs) {
                if let assignee = task.assignee {
                    HubMetadata(label: "担当", value: assignee, systemImage: "person")
                }

                if let updatedBy = task.updatedBy {
                    HubMetadata(label: "更新者", value: updatedBy, systemImage: "person.crop.circle")
                }

                if let updatedAt = task.updatedAt {
                    Text("更新日時 \(updatedAt, format: .dateTime.year().month().day().hour().minute())")
                        .font(HubTypography.caption)
                        .foregroundStyle(HubColor.secondaryText)
                }

                HubDueLabel(date: task.dueDate, now: now, isResolved: task.status == .completed)

                if task.subtaskCount > 0 {
                    HubMetadata(
                        label: "サブタスク",
                        value: "\(task.completedSubtaskCount) / \(task.subtaskCount) 完了",
                        systemImage: "checklist"
                    )
                }
            }

            if let evidence = task.evidence {
                VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                    Label("根拠", systemImage: "checkmark.seal")
                        .font(HubTypography.caption)
                        .foregroundStyle(HubColor.secondaryText)
                    Text(verbatim: evidence)
                        .font(HubTypography.callout)
                        .foregroundStyle(HubColor.text)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .padding(.vertical, HubSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var statusBadge: some View {
        HubBadge(title: task.status.title, systemImage: task.status.systemImage, tone: task.status.tone)
    }

    private var priorityBadge: some View {
        HubBadge(title: "優先度: \(task.priority.title)", systemImage: task.priority.systemImage, tone: task.priority.tone)
    }
}
