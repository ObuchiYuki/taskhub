//
//  ConnectionView.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import UniformTypeIdentifiers
import TaskHubCore
import TaskHubDesignSystem

struct ConnectionView: View {
    @EnvironmentObject private var store: AppStore
    @State private var owner = ""
    @State private var repository = ""
    @State private var branch = "main"
    @State private var token = ""
    @State private var showImporter = false
    @State private var confirmImport = false
    @State private var confirmConnection = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: HubSpacing.sm) {
                    Label("TaskHub", systemImage: "checklist").font(HubTypography.largeTitle)
                    Text("エージェントの進捗と、今あなたが決めること。")
                        .font(HubTypography.headline)
                    Text("private GitHubリポジトリのタスクと裁定を読み取り専用で確認します。")
                        .foregroundStyle(HubColor.secondaryText)
                }
                .padding(.vertical, HubSpacing.xs)
                if store.snapshot != nil {
                    HubMetadata(label: "表示中", value: store.sourceTitle)
                    if let commit = store.cached?.commitSHA {
                        HubMetadata(label: "commit", value: commit)
                    }
                    if let snapshot = store.snapshot {
                        HubMetadata(label: "イベント連番", value: String(snapshot.lastEventSeq))
                    }
                }
            }
            if let error = store.errorMessage {
                Section { HubErrorState(message: error) }
            }
            if let notice = store.backgroundNotice {
                Section { Text(verbatim: notice).font(HubTypography.caption) }
            }
            Section {
                TextField("所有者（OWNER）", text: $owner).accessibilityIdentifier("owner")
                TextField("リポジトリ名", text: $repository).accessibilityIdentifier("repository")
                TextField("ブランチ", text: $branch).accessibilityIdentifier("branch")
                SecureField("読み取り用トークン", text: $token)
                    // APIトークンへのパスワード保存提案を抑止する。
                    .textContentType(.oneTimeCode)
                    .keyboardType(.asciiCapable)
                    .privacySensitive()
                    .accessibilityIdentifier("token")
                HubButton(title: "接続して同期", systemImage: "lock.icloud", isLoading: store.isBusy) {
                    if store.snapshot != nil && !store.isDemo && connectionChanges {
                        confirmConnection = true
                    } else { connect() }
                }
                .disabled(owner.isEmpty || repository.isEmpty || branch.isEmpty)
            } header: {
                Text("GitHub接続")
            } footer: {
                Text("GitHub.comの専用privateリポジトリを指定。Fine-grained PATの対象をこのリポジトリに限定し、Contents: Read-onlyを許可してください。トークンはこの端末のKeychainに保存します。保存済みトークンを使う場合は空欄にできます。")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            Section {
                HubButton(title: "snapshot.jsonを読み込む", systemImage: "doc.badge.plus", role: .secondary) {
                    if store.snapshot != nil && !store.isDemo { confirmImport = true }
                    else { showImporter = true }
                }
                .disabled(store.isBusy)
                HubButton(title: "サンプルを見る", systemImage: "eye", role: .secondary) { store.showDemo() }
                    .disabled(store.isBusy)
                if store.isDemo {
                    HubButton(title: "保存済みデータに戻る", role: .secondary) { Task { await store.returnToSaved() } }
                }
            } header: { Text("端末内で確認") } footer: {
                Text("JSON読込は端末内で保存。サンプルは一時表示です。添付本体の取得にはGitHub接続が必要です。")
            }
            Section("同期の動作") {
                Text("画面表示中は60秒ごとにcommitを確認し、アプリ復帰時と手動更新でも同期します。")
                Text("バックグラウンド更新は15分以降をiOSへ要求します。実行時刻はOSが判断します。アプリの強制終了・省電力・設定によって更新が遅れます。")
                Text("更新に失敗した場合は、最後に検証・保存できたデータを表示します。未知の形式、履歴の巻戻り、公開リポジトリを検出した場合は更新を保留します。")
                if store.cached?.configuration != nil {
                    HubButton(title: "今すぐ同期", systemImage: "arrow.clockwise", isLoading: store.isBusy) {
                        Task { await store.synchronize() }
                    }
                }
            }
        }
        .navigationTitle(store.snapshot == nil ? "はじめる" : "接続設定")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("キーボードを閉じる") { dismissKeyboard() }
            }
        }
        .onAppear {
            if let configuration = store.cached?.configuration {
                owner = configuration.owner
                repository = configuration.repository
                branch = configuration.branch
            }
        }
        .confirmationDialog("表示と自動同期先を切り替えますか？", isPresented: $confirmConnection, titleVisibility: .visible) {
            Button("接続先を切り替える") { connect() }
        } message: {
            Text("新しいデータの検証に成功した後、この端末のキャッシュを置き換えます。")
        }
        .confirmationDialog("JSONの手動更新に切り替えますか？", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("ファイルを選ぶ") { showImporter = true }
        } message: {
            Text("読込成功後、この端末の表示データを置き換え、GitHubの自動同期を停止します。")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { _ = await store.importSnapshot(from: url) } }
            case .failure:
                store.errorMessage = "ファイルを開けませんでした。アクセス権を確認して再度選択してください。"
            }
        }
    }

    private var connectionChanges: Bool {
        guard let config = store.cached?.configuration else { return true }
        return config.owner != owner || config.repository != repository || config.branch != branch
    }

    private func connect() {
        dismissKeyboard()
        Task {
            if await store.connect(owner: owner, repository: repository, branch: branch, token: token) { token = "" }
        }
    }
}
