//
//  DetailViews.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubCore
import TaskHubDesignSystem

struct TaskDetailView: View {
    let id: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        DetailContainer(title: "タスク詳細") {
            if let snapshot = store.snapshot, let task = snapshot.task(id: id) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HubCard { HubTaskRow(task: snapshot.displayTask(task), now: context.date) }
                }
                TextBlock(title: "依頼内容", text: task.body)
                HubCard {
                    VStack(alignment: .leading, spacing: HubSpacing.sm) {
                        HubMetadata(label: "登録者", value: task.createdBy, systemImage: "person")
                        HubMetadata(label: "登録日時", value: formattedDate(task.createdAt))
                        HubMetadata(label: "更新者", value: task.updatedBy, systemImage: "person.crop.circle")
                        HubMetadata(label: "更新日時", value: formattedDate(task.updatedAt))
                        HubMetadata(label: "リビジョン", value: String(task.revision))
                        if let amount = task.amount { HubMetadata(label: "金額", value: "\(amount.value) \(amount.currency)") }
                    }
                }
                if !task.method.isEmpty { TextBlock(title: "やり方", text: task.method) }
                if !task.rationale.isEmpty { TextBlock(title: "根拠", text: task.rationale) }
                if let completion = task.completion {
                    TextBlock(title: "完了証拠", text: completion.evidence)
                    HubMetadata(label: "確認者・日時", value: "\(completion.verifiedBy)・\(formattedDate(completion.verifiedAt))")
                }
                if let parentID = task.parentID, let parent = snapshot.task(id: parentID) {
                    Text("親タスク").font(HubTypography.headline)
                    TaskLink(task: parent)
                }
                let children = snapshot.tasks.filter { $0.parentID == id }
                if !children.isEmpty {
                    Text("サブタスク").font(HubTypography.headline)
                    ForEach(children) { TaskLink(task: $0) }
                }
                let decisions = snapshot.decisions.filter { $0.taskID == id }
                if !decisions.isEmpty {
                    Text("関連する裁定").font(HubTypography.headline)
                    ForEach(decisions) { decision in
                        NavigationLink(value: DetailRoute.decision(decision.id)) {
                            Label {
                                Text(verbatim: "\(decision.title)・\(decision.status.display.title)")
                            } icon: { Image(systemName: decision.status.display.systemImage) }
                        }
                        .buttonStyle(HubButtonStyle(role: .secondary))
                    }
                }
                RecordHistory(targetType: "task", targetID: id)
            }
        }
    }
}

struct DecisionDetailView: View {
    let id: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        DetailContainer(title: "裁定詳細") {
            if let snapshot = store.snapshot, let decision = snapshot.decision(id: id) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HubDecisionCard(decision: snapshot.displayDecision(decision), now: context.date)
                }
                TextBlock(title: "依頼内容", text: decision.body)
                HubMetadata(label: "更新者・日時", value: "\(decision.updatedBy)・\(formattedDate(decision.updatedAt))")
                if let answer = decision.answer {
                    HubCard {
                        VStack(alignment: .leading, spacing: HubSpacing.sm) {
                            Text("回答の記録").font(HubTypography.headline)
                            Text(verbatim: answer.text)
                            HubMetadata(label: "回答者", value: answer.respondent)
                            HubMetadata(label: "記録者", value: answer.recordedBy)
                            HubMetadata(label: "回答日時", value: formattedDate(answer.recordedAt))
                        }
                    }
                }
                if let application = decision.application {
                    TextBlock(title: "反映証拠", text: application.evidence)
                    HubMetadata(label: "反映者・日時", value: "\(application.appliedBy)・\(formattedDate(application.appliedAt))")
                    HubMetadata(label: "元タスク再開", value: application.resumedTask ? "再開済み" : "再開指定なし")
                }
                if decision.status == .pending {
                    TextBlock(title: "回答の記録方法", text: "回答はサーバー側でエージェントに記録を依頼してください。次回同期で回答者・回答日時・反映結果を確認できます。")
                    Text(verbatim: "taskhub --actor RECORDER decision answer \(decision.id) --answer-file ANSWER.txt --respondent RESPONDENT")
                        .font(HubTypography.identifier).textSelection(.enabled)
                }
                if let task = snapshot.task(id: decision.taskID) {
                    Text("元タスク").font(HubTypography.headline)
                    TaskLink(task: task)
                }
                RecordHistory(targetType: "decision", targetID: id)
            }
        }
    }
}

struct TaskLink: View {
    let task: HubTaskRecord
    var body: some View {
        NavigationLink(value: DetailRoute.task(task.id)) {
            Label { Text(verbatim: task.title) } icon: { Image(systemName: "arrow.right.doc") }
        }
        .buttonStyle(HubButtonStyle(role: .secondary))
        .accessibilityIdentifier("related-\(task.id)")
    }
}

struct RecordHistory: View {
    let targetType: String
    let targetID: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let snapshot = store.snapshot {
            let attachments = snapshot.attachments(targetType: targetType, targetID: targetID)
            if !attachments.isEmpty {
                Text("添付").font(HubTypography.headline)
                ForEach(attachments) { AttachmentLink(attachment: $0) }
            }
            Text("追記・作業ログ").font(HubTypography.headline)
            let comments = snapshot.comments(targetType: targetType, targetID: targetID)
            if comments.isEmpty {
                Text("追記はまだありません。").foregroundStyle(HubColor.secondaryText)
            }
            ForEach(comments) { comment in
                HubCard {
                    VStack(alignment: .leading, spacing: HubSpacing.sm) {
                        HubHistoryRow(entry: HubHistoryEntry(
                            id: comment.id, actor: comment.createdBy, timestamp: comment.createdAt, message: comment.body
                        ))
                        ForEach(snapshot.attachments(targetType: "comment", targetID: comment.id)) {
                            AttachmentLink(attachment: $0)
                        }
                    }
                }
            }
            Text("全変更の監査履歴はサーバーのhistoryコマンドで確認できます。ここにはsnapshotに含まれる追記を時系列表示します。")
                .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
        }
    }
}

struct AttachmentLink: View {
    let attachment: AttachmentRecord
    var body: some View {
        NavigationLink(value: DetailRoute.attachment(attachment.id)) {
            HubAttachmentRow(attachment: attachment.display)
        }
        .buttonStyle(.plain)
        .accessibilityHint("添付の情報とプレビューを開く")
        .accessibilityIdentifier("attachment-\(attachment.id)")
    }
}

struct TextBlock: View {
    let title: String
    let text: String
    var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: HubSpacing.xs) {
                Text(verbatim: title).font(HubTypography.headline)
                Text(verbatim: text.isEmpty ? "未記入" : text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DetailContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpacing.lg) {
                SyncHeader()
                content()
            }
            .frame(maxWidth: HubMetrics.readingWidth, alignment: .leading)
            .padding(HubSpacing.md)
            .frame(maxWidth: .infinity)
        }
        .background(HubColor.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.synchronize() }
    }
}
