//
//  Details.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import AppKit
import SwiftUI
import TaskHubDesignSystem
import TaskHubMacCore

struct TaskDetail: View {
    let task: TaskRecord
    let snapshot: Snapshot
    let store: HubStore
    let now: Date
    let navigate: (String) -> Void

    var body: some View {
        Page {
            Text(verbatim: task.title).font(HubTypography.largeTitle)
                .accessibilityIdentifier("task.detail.title")
            HubCard { HubTaskRow(task: snapshot.summary(task), now: now) }
            HubMetadata(label: "登録", value: "\(task.createdBy) · \(dateText(task.createdAt))")
            HubMetadata(label: "更新", value: "\(task.updatedBy) · \(dateText(task.updatedAt)) · revision \(task.revision)")
            Heading(title: "依頼内容")
            Text(verbatim: task.body.isEmpty ? "本文なし" : task.body)
            HubMetadata(label: "金額", value: task.amount.map { "\($0.value) \($0.currency)" } ?? "未設定", systemImage: "yensign.circle")
            HubMetadata(label: "やり方", value: task.method.isEmpty ? "未設定" : task.method)
            HubMetadata(label: "根拠", value: task.rationale.isEmpty ? "未設定" : task.rationale)
            if let completion = task.completion {
                Heading(title: "完了の証拠")
                HubMetadata(label: "証拠", value: completion.evidence, systemImage: "checkmark.seal")
                HubMetadata(label: "確認", value: "\(completion.verifiedBy) · \(dateText(completion.verifiedAt))")
            }
            if let parent = task.parentID, let parentTask = snapshot.tasks.first(where: { $0.id == parent }) {
                HubButton(title: "親タスク: \(parentTask.title)", systemImage: "arrow.up", role: .secondary) { navigate(parent) }
                    .accessibilityIdentifier("task.parent")
            }
            let children = snapshot.tasks.filter { $0.parentID == task.id }
            if !children.isEmpty {
                Heading(title: "サブタスク")
                ForEach(children) { child in
                    Button { navigate(child.id) } label: { HubTaskRow(task: snapshot.summary(child), now: now) }
                        .buttonStyle(.plain).accessibilityHint("サブタスクの詳細を開く")
                }
            }
            let related = snapshot.decisions.filter { $0.taskID == task.id }
            if !related.isEmpty {
                Heading(title: "関連するユーザー裁定")
                ForEach(related) { decision in
                    Button { navigate(decision.id) } label: { HubDecisionCard(decision: snapshot.summary(decision), now: now) }
                        .buttonStyle(.plain).accessibilityHint("裁定の詳細を開く")
                        .accessibilityIdentifier("task.decision.\(decision.id)")
                }
            }
            RecordsView(targetID: task.id, snapshot: snapshot, store: store)
        }
    }
}

struct DecisionDetail: View {
    let decision: DecisionRecord
    let snapshot: Snapshot
    let store: HubStore
    let now: Date
    let navigate: (String) -> Void

    var body: some View {
        Page {
            Text(verbatim: decision.title).font(HubTypography.largeTitle)
                .accessibilityIdentifier("decision.detail.title")
            HubCard { HubDecisionCard(decision: snapshot.summary(decision), now: now) }
            HubMetadata(label: "登録", value: "\(decision.createdBy) · \(dateText(decision.createdAt))")
            HubMetadata(label: "更新", value: "\(decision.updatedBy) · \(dateText(decision.updatedAt)) · revision \(decision.revision)")
            Heading(title: "依頼内容")
            Text(verbatim: decision.body)
            HubButton(title: "元タスクを開く", systemImage: "arrow.turn.up.right", role: .secondary) { navigate(decision.taskID) }
                .accessibilityIdentifier("decision.task")
            Heading(title: "回答と反映")
            if let answer = decision.answer {
                HubMetadata(label: "回答", value: answer.text)
                    .accessibilityIdentifier("decision.answer")
                HubMetadata(label: "回答者", value: answer.respondent)
                HubMetadata(label: "記録", value: "\(answer.recordedBy) · \(dateText(answer.recordedAt))")
            } else {
                Text("回答はサーバーの decision answer コマンドで記録する。同期するとここに表示される。")
                    .foregroundStyle(HubColor.secondaryText)
            }
            if let application = decision.application {
                HubMetadata(label: "反映の証拠", value: application.evidence)
                HubMetadata(label: "反映", value: "\(application.appliedBy) · \(dateText(application.appliedAt))")
                HubMetadata(label: "元タスク再開", value: application.resumedTask ? "再開済み" : "状態を維持")
            }
            RecordsView(targetID: decision.id, snapshot: snapshot, store: store)
        }
    }
}

private struct RecordsView: View {
    let targetID: String
    let snapshot: Snapshot
    let store: HubStore
    @State private var savingID: String?
    @State private var message: String?

    var body: some View {
        let comments = snapshot.comments.filter { $0.targetID == targetID }.sorted { $0.eventSeq < $1.eventSeq }
        let direct = snapshot.attachments.filter { $0.targetID == targetID }
        Heading(title: "添付")
        Text("保存操作時に取得し、サイズとSHA-256を検証する。保存したファイルの取り扱いは内容を確認して判断する。")
            .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
        if direct.isEmpty { Text("直接の添付なし").foregroundStyle(HubColor.secondaryText) }
        attachmentRows(direct)
        Heading(title: "追記・作業ログ")
        if comments.isEmpty { Text("追記なし").foregroundStyle(HubColor.secondaryText) }
        ForEach(comments) { comment in
            HubHistoryRow(entry: HubHistoryEntry(id: comment.id, actor: comment.createdBy,
                timestamp: comment.createdAt, message: comment.body))
                .accessibilityIdentifier("comment.\(comment.id)")
            attachmentRows(snapshot.attachments.filter { $0.targetID == comment.id })
        }
        Text("全変更はサイドバーの「変更履歴」で確認できる。")
            .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
        if let message { Text(verbatim: message).foregroundStyle(HubColor.info).accessibilityIdentifier("attachment.result") }
    }

    @ViewBuilder private func attachmentRows(_ attachments: [AttachmentRecord]) -> some View {
        ForEach(attachments) { attachment in
            VStack(alignment: .leading, spacing: HubSpacing.xs) {
                HubAttachmentRow(attachment: attachment.presentation)
                HubButton(title: "検証して保存…", systemImage: "arrow.down.doc", role: .secondary,
                          isLoading: savingID == attachment.id) {
                    Task { await save(attachment) }
                }
                .disabled(savingID != nil)
                .accessibilityIdentifier("attachment.save.\(attachment.id)")
            }
        }
    }

    @MainActor private func save(_ attachment: AttachmentRecord) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return }
        savingID = attachment.id
        message = nil
        defer { savingID = nil }
        do {
            let data = try await store.attachmentData(attachment)
            try data.write(to: url, options: .atomic)
            message = "\(attachment.filename) を検証して保存した。"
        } catch {
            message = "保存失敗: \(error.localizedDescription)"
        }
    }
}
