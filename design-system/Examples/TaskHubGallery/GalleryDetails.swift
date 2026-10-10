//
//  GalleryDetails.swift
//  TaskHubGallery
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubDesignSystem

struct GalleryTaskDetail: View {
    let task: GalleryTask
    let decisions: [GalleryDecision]

    var body: some View {
        GalleryPage {
            Text(task.summary.title)
                .font(HubTypography.largeTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("task.detail.title")
            HubCard {
                VStack(alignment: .leading, spacing: HubSpacing.sm) {
                    Text(task.id).font(HubTypography.identifier)
                    HubLaneLabel(lane: task.summary.lane)
                    HubBadge(title: task.summary.status.title, systemImage: task.summary.status.systemImage, tone: task.summary.status.tone)
                    HubBadge(title: task.summary.priority.title, systemImage: task.summary.priority.systemImage, tone: task.summary.priority.tone)
                    HubDueLabel(date: task.summary.dueDate, now: GalleryData.now, isResolved: task.summary.status == .completed)
                    HubMetadata(label: "担当", value: task.summary.assignee ?? "未割当", systemImage: "person")
                    HubMetadata(label: "最終操作", value: task.summary.updatedBy ?? "未記録", systemImage: "person.crop.circle.badge.clock")
                    HubMetadata(label: "金額", value: "未設定（サンプル）", systemImage: "yensign.circle")
                }
            }
            GalleryHeading(title: "依頼内容")
            Text(task.body).font(HubTypography.body)
                .fixedSize(horizontal: false, vertical: true)
            HubMetadata(label: "やり方", value: task.approach, systemImage: "list.number")
            if let evidence = task.summary.evidence {
                HubMetadata(label: "完了の根拠", value: evidence, systemImage: "checkmark.seal")
                    .accessibilityIdentifier("task.evidence")
            }
            if !decisions.isEmpty {
                GalleryHeading(title: "関連するユーザー裁定")
                ForEach(decisions) { decision in
                    NavigationLink(value: GalleryRoute.decision(decision.id)) {
                        HubDecisionCard(decision: decision.summary, now: GalleryData.now)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task.decision.\(decision.id)")
                }
            }
            GalleryRecords(attachments: task.attachments, history: task.history)
        }
        .foregroundStyle(HubColor.text)
        .navigationTitle(task.id)
    }
}

struct GalleryDecisionDetail: View {
    let decision: GalleryDecision
    let recordReply: (String) -> Void
    @State private var reply = GalleryData.sampleReply

    var body: some View {
        GalleryPage {
            Text(decision.summary.title)
                .font(HubTypography.largeTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("decision.detail.title")
            HubCard {
                VStack(alignment: .leading, spacing: HubSpacing.sm) {
                    Text(decision.id).font(HubTypography.identifier)
                    HubLaneLabel(lane: decision.summary.lane)
                    HubBadge(title: decision.summary.status.title, systemImage: decision.summary.status.systemImage, tone: decision.summary.status.tone)
                        .accessibilityIdentifier("decision.status")
                    HubDueLabel(date: decision.summary.dueDate, now: GalleryData.now, isResolved: decision.summary.status != .pending)
                    HubMetadata(label: "登録者", value: decision.summary.registeredBy ?? "未記録", systemImage: "person")
                    NavigationLink(value: GalleryRoute.task(decision.summary.taskID)) {
                        Label("元タスク \(decision.summary.taskID) を開く", systemImage: "arrow.turn.up.right")
                    }
                    .accessibilityIdentifier("decision.task")
                }
            }
            GalleryHeading(title: "判断が必要な理由")
            Text(decision.summary.reason).font(HubTypography.body)
                .fixedSize(horizontal: false, vertical: true)
            GalleryHeading(title: "選択肢")
            if decision.summary.options.isEmpty {
                Text("指定された選択肢はありません。自由記述の回答例です。")
                    .font(HubTypography.callout)
            } else {
                ForEach(Array(decision.summary.options.enumerated()), id: \.offset) { index, option in
                    HubMetadata(label: "選択肢 \(index + 1)", value: option, systemImage: "circle")
                }
            }
            GalleryHeading(title: "回答")
            if let savedReply = decision.summary.reply {
                HubCard {
                    Text(savedReply)
                        .font(HubTypography.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("decision.reply.recorded")
                }
            } else {
                TextField("回答内容", text: $reply, axis: .vertical)
                    .font(HubTypography.body)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("decision.reply.input")
            }
            Text("回答はこのウインドウのメモリ内だけに記録します。外部送信・永続保存・元タスクの自動更新は行いません。再起動すると初期状態に戻ります。")
                .font(HubTypography.caption)
                .foregroundStyle(HubColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HubButton(title: "回答を記録（サンプル）", systemImage: "text.badge.checkmark") {
                recordReply(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .disabled(decision.summary.status != .pending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("decision.reply.save")
            GalleryRecords(attachments: decision.attachments, history: decision.history)
        }
        .foregroundStyle(HubColor.text)
        .navigationTitle(decision.id)
    }
}

private struct GalleryRecords: View {
    let attachments: [HubAttachment]
    let history: [HubHistoryEntry]

    var body: some View {
        GalleryHeading(title: "添付")
        Text("添付は表示用メタデータです。画像・ファイルの取得やオープンは行いません。")
            .font(HubTypography.caption)
            .foregroundStyle(HubColor.secondaryText)
        if attachments.isEmpty {
            HubEmptyState(title: "添付なし", message: "この項目には添付がありません。", systemImage: "paperclip")
        } else {
            ForEach(attachments) { attachment in
                HubAttachmentRow(attachment: attachment)
                    .accessibilityIdentifier("attachment.\(attachment.id)")
            }
        }
        GalleryHeading(title: "追記・変更履歴")
        if history.isEmpty {
            HubEmptyState(title: "履歴なし", message: "追記や変更はまだありません。", systemImage: "clock")
        } else {
            ForEach(history) { entry in
                HubHistoryRow(entry: entry)
                    .accessibilityIdentifier("history.\(entry.id)")
            }
        }
    }
}
