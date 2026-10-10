//
//  AppStore.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import BackgroundTasks
import Foundation
import SwiftUI
import TaskHubCore
import TaskHubDesignSystem

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var cached: CachedSnapshot?
    @Published private(set) var isDemo = false
    @Published private(set) var isBusy = false
    @Published private(set) var restored = false
    @Published var syncState: HubSyncState = .synced(lastUpdated: nil)
    @Published var errorMessage: String?
    @Published private(set) var backgroundNotice: String?

    static let refreshIdentifier = "dev.taskhub.ios.refresh"
    private let client: GitHubClient
    private let cache: SnapshotCache
    private let testing: Bool
    private var restoring = false
    var automaticSyncEnabled: Bool { !testing }
    var snapshot: Snapshot? { cached?.snapshot }
    var sourceKey: String { isDemo ? "demo" : (snapshot?.storeID ?? "welcome") }
    var sourceTitle: String {
        if isDemo { return "サンプル・端末内のみ" }
        if let configuration = cached?.configuration { return "\(configuration.owner)/\(configuration.repository)" }
        return "読み込んだスナップショット"
    }

    init() {
        #if DEBUG
        testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        client = ProcessInfo.processInfo.arguments.contains("--ui-sync-fixture") ? GitHubClient(transport: UITestTransport()) : GitHubClient()
        #else
        testing = false
        client = GitHubClient()
        #endif
        let directory = URL.applicationSupportDirectory.appending(path: testing ? "TaskHubUITests" : "TaskHub")
        cache = SnapshotCache(directory: directory)
    }

    func restore() async {
        guard !restored, !restoring else { return }
        restoring = true
        isBusy = true
        defer {
            restoring = false
            isBusy = false
            restored = true
        }
        do {
            #if DEBUG
            let shouldLoad = !testing || ProcessInfo.processInfo.arguments.contains("--ui-restore")
            #else
            let shouldLoad = true
            #endif
            if shouldLoad { cached = try await cache.load() }
            if let cached { syncState = .offline(lastUpdated: cached.checkedAt) }
        } catch { report(error) }
    }

    func showDemo() {
        guard !isBusy else { return }
        do {
            guard let url = Bundle.main.url(forResource: "demo-snapshot", withExtension: "json") else {
                throw AppError.message("サンプルデータが見つかりません。")
            }
            let snapshot = try Snapshot.decode(Data(contentsOf: url))
            cached = CachedSnapshot(checkedAt: .now, snapshot: snapshot)
            isDemo = true
            errorMessage = nil
            syncState = .synced(lastUpdated: nil)
        } catch { report(error) }
    }

    func returnToSaved() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            cached = testing ? nil : try await cache.load()
            isDemo = false
            errorMessage = nil
            syncState = .offline(lastUpdated: cached?.checkedAt)
        } catch { report(error) }
    }

    func connect(owner: String, repository: String, branch: String, token: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        syncState = .syncing
        defer { isBusy = false }
        do {
            let config = RepositoryConfiguration(
                owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
                repository: repository.trimmingCharacters(in: .whitespacesAndNewlines),
                branch: branch.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try config.validated()
            let input = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = input.isEmpty ? try CredentialStore.read(for: config.identity) ?? "" : input
            guard !credential.isEmpty else { throw AppError.message("読み取り用トークンを入力してください。") }
            let retained = isDemo ? try await cache.load() : cached
            let previous = retained?.configuration?.identity == config.identity ? retained : nil
            let result = try await client.synchronize(configuration: config, token: credential, previous: previous)
            if let retained, retained.snapshot.storeID == result.snapshot.storeID {
                try result.snapshot.validated(previous: retained.snapshot)
            }
            try CredentialStore.save(credential, for: config.identity)
            try await cache.save(result)
            cached = result
            isDemo = false
            errorMessage = nil
            syncState = .synced(lastUpdated: result.checkedAt)
            scheduleRefresh()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func synchronize() async {
        guard !isBusy, !isDemo, let previous = cached, let config = previous.configuration else { return }
        isBusy = true
        syncState = .syncing
        defer { isBusy = false }
        do {
            guard let token = try CredentialStore.read(for: config.identity) else {
                throw AppError.message("認証情報を読み込めません。接続設定でトークンを確認してください。")
            }
            let result = try await client.synchronize(configuration: config, token: token, previous: previous)
            try Task.checkCancellation()
            try await cache.save(result)
            cached = result
            errorMessage = nil
            syncState = .synced(lastUpdated: result.checkedAt)
        } catch is CancellationError {
            syncState = .offline(lastUpdated: cached?.checkedAt)
        } catch { report(error) }
    }

    func importSnapshot(from url: URL) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1_024 * 1_024 else { throw AppError.message("snapshot.jsonの上限は32MiBです。") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 32 * 1_024 * 1_024 + 1) ?? Data()
            let retained = isDemo ? try await cache.load() : cached
            let snapshot = try Snapshot.decode(data)
            if let previous = retained?.snapshot, previous.storeID == snapshot.storeID {
                try snapshot.validated(previous: previous)
            }
            let result = CachedSnapshot(checkedAt: .now, snapshot: snapshot)
            try await cache.save(result)
            cached = result
            isDemo = false
            syncState = .synced(lastUpdated: result.checkedAt)
            errorMessage = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    func attachmentData(_ attachment: AttachmentRecord) async throws -> Data {
        if isDemo, attachment.sizeBytes == 0 { return Data() }
        guard let cached, let configuration = cached.configuration else {
            throw AppError.message("添付本体の取得にはGitHub接続が必要です。読み込み済みJSONには添付情報だけが含まれます。")
        }
        guard let token = try CredentialStore.read(for: configuration.identity) else {
            throw AppError.message("接続設定で読み取り用トークンを確認してください。")
        }
        return try await client.attachment(attachment, from: cached, token: token)
    }

    func scheduleRefresh() {
        guard !testing, !isDemo, cached?.configuration != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundNotice = nil
        } catch {
            backgroundNotice = "バックグラウンド更新を予約できません。iOSのAppのバックグラウンド更新設定を確認してください。画面表示中の自動同期は継続します。"
        }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        if cached != nil && ((error as? GitHubSyncError) == .network || (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains($0.code) } == true) {
            syncState = .offline(lastUpdated: cached?.checkedAt)
        } else {
            syncState = .failed(message: error.localizedDescription)
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}
