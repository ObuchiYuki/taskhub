//
//  ConnectionView.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import AppKit
import SwiftUI
import TaskHubDesignSystem
import TaskHubMacCore

struct ConnectionView: View {
    let store: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "github"
    @State private var repository = ""
    @State private var branch = "main"
    @State private var directory = ""
    @State private var attempted = false

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpacing.lg) {
            Heading(title: "同期元を設定")
            Picker("同期方法", selection: $mode) {
                Text("GitHub private").tag("github")
                Text("ローカルフォルダ").tag("local")
            }
            .pickerStyle(.segmented).frame(minHeight: HubMetrics.minimumTarget)
            .accessibilityIdentifier("connection.mode")
            if mode == "github" {
                TextField("OWNER/REPOSITORY", text: $repository).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connection.repository")
                TextField("ブランチ", text: $branch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connection.branch")
                Text("既存の GitHub CLI（gh）認証を使用する。対象privateリポジトリのContents読み取り権限が必要。接続後はアプリ起動中に60秒周期で変更を確認する。")
                    .font(HubTypography.callout).foregroundStyle(HubColor.secondaryText)
            } else {
                TextField("snapshot.json があるフォルダ", text: $directory).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connection.directory")
                HubButton(title: "フォルダを選択…", systemImage: "folder", role: .secondary) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.begin { result in
                        if result == .OK { directory = panel.url?.path ?? directory }
                    }
                }
                Text("サーバーのデータフォルダ、またはそのコピーを読み取る。snapshot.json・blobs・eventsを同じフォルダに置く。")
                    .font(HubTypography.callout).foregroundStyle(HubColor.secondaryText)
            }
            if attempted, let message = store.errorMessage {
                Text(verbatim: message).foregroundStyle(HubColor.danger)
                    .accessibilityIdentifier("connection.error")
            }
            HStack {
                HubButton(title: "キャンセル", role: .secondary) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(store.isSyncing)
                Spacer()
                HubButton(title: "接続して読み込む", systemImage: "arrow.triangle.2.circlepath", isLoading: store.isSyncing) {
                    Task {
                        attempted = true
                        let source: SourceConfiguration = mode == "github"
                            ? .github(repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                                      branch: branch.trimmingCharacters(in: .whitespacesAndNewlines))
                            : .local(directory: directory.trimmingCharacters(in: .whitespacesAndNewlines))
                        if await store.synchronize(using: source) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mode == "github" ? repository.isEmpty || branch.isEmpty : directory.isEmpty)
                .accessibilityIdentifier("connection.connect")
            }
        }
        .padding(HubSpacing.lg).frame(width: 520)
        .hubTheme()
        .interactiveDismissDisabled(store.isSyncing)
        .onAppear {
            switch store.configuration {
            case .github(let repo, let ref): repository = repo; branch = ref; mode = "github"
            case .local(let path): directory = path; mode = "local"
            case nil: break
            }
        }
    }
}

struct HistoryView: View {
    @State private var history: AuditHistory

    init(context: AuditContext) { _history = State(initialValue: AuditHistory(context: context)) }

    var body: some View {
        Page {
            Heading(title: "全変更履歴")
            Text("同じ同期時点のイベントを新しい順に25件ずつ取得する。スナップショットの末尾からSHA-256の連鎖を検証し、元の変更内容を表示する。")
                .foregroundStyle(HubColor.secondaryText)
            if history.entries.isEmpty && history.nextSequence == 0 {
                HubEmptyState(title: "変更履歴なし", message: "まだ操作が記録されていない。", systemImage: "clock")
            }
            ForEach(history.entries) { entry in
                HubCard {
                    VStack(alignment: .leading, spacing: HubSpacing.sm) {
                        HubHistoryRow(entry: HubHistoryEntry(id: String(entry.id), actor: entry.actor,
                            timestamp: entry.timestamp, message: "#\(entry.id) \(entry.title)"))
                        Text(verbatim: entry.entityID).font(HubTypography.identifier)
                        DisclosureGroup("変更内容を表示") {
                            Text(verbatim: entry.payload).font(HubTypography.identifier)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: HubMetrics.minimumTarget)
                    }
                }
            }
            if let message = history.errorMessage { HubErrorState(message: message) }
            if history.nextSequence > 0 {
                HubButton(title: "続きを読み込む（残り \(history.nextSequence) 件）", systemImage: "clock.arrow.circlepath",
                          role: .secondary, isLoading: history.isLoading) {
                    Task { await history.loadMore() }
                }
                .accessibilityIdentifier("history.load")
            } else if !history.entries.isEmpty {
                Text("全履歴の検証が完了した。").foregroundStyle(HubColor.success)
            }
        }
    }
}
