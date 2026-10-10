//
//  HubStore.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Darwin
import Foundation
import Observation

public struct CachedSnapshot: Codable, Sendable {
    public let configuration: SourceConfiguration
    public let revision: String
    public let etag: String?
    public let repositoryID: Int?
    public let checkedAt: Date
    public let data: Data
}

public struct SnapshotIdentity: Hashable, Sendable {
    public let configuration: SourceConfiguration
    public let revision: String
    public let repositoryID: Int?
}

public enum CacheSaveOutcome: Equatable, Sendable {
    case durable, publishedDurabilityUncertain
}

public struct SnapshotCache: Sendable {
    public let directory: URL
    private let directorySync: @Sendable (Int32) -> Int32

    public init(directory: URL) {
        self.directory = directory
        directorySync = { fsync($0) }
    }

    init(directory: URL, directorySync: @escaping @Sendable (Int32) -> Int32) {
        self.directory = directory
        self.directorySync = directorySync
    }

    public static var applicationDefault: SnapshotCache {
        SnapshotCache(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskHubMac", isDirectory: true))
    }

    public func load() throws -> CachedSnapshot? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let parent = try openDirectory()
        defer { close(parent) }
        let file = openat(parent, "snapshot-cache.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw StoreError.invalidCache }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= 46 * 1_024 * 1_024 else { throw StoreError.invalidCache }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + max(count, 0) <= 46 * 1_024 * 1_024 else { throw StoreError.invalidCache }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let cached = try JSONDecoder().decode(CachedSnapshot.self, from: data)
        _ = try cached.configuration.validated()
        _ = try Snapshot.decode(cached.data)
        return cached
    }

    @discardableResult
    public func save(_ value: CachedSnapshot) throws -> CacheSaveOutcome {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let parent = try openDirectory()
        defer { close(parent) }
        var existing = stat()
        let result = fstatat(parent, "snapshot-cache.json", &existing, AT_SYMLINK_NOFOLLOW)
        guard (result == -1 && errno == ENOENT) ||
              (result == 0 && existing.st_mode & S_IFMT == S_IFREG && existing.st_uid == geteuid()) else {
            throw StoreError.invalidCache
        }
        let temporary = ".snapshot-\(UUID().uuidString).tmp"
        let file = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StoreError.cacheWriteFailed }
        defer { close(file); unlinkat(parent, temporary, 0) }
        let bytes = try JSONEncoder().encode(value)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.cacheWriteFailed }
                offset += count
            }
        }
        guard fsync(file) == 0,
              renameat(parent, temporary, parent, "snapshot-cache.json") == 0 else { throw StoreError.cacheWriteFailed }
        return directorySync(parent) == 0 ? .durable : .publishedDurabilityUncertain
    }

    private func openDirectory() throws -> Int32 {
        let file = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw StoreError.invalidCache }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(file)
            throw StoreError.invalidCache
        }
        return file
    }
}

public enum StoreError: LocalizedError {
    case invalidCache, cacheWriteFailed, missingSnapshot, changedSource, unchangedWithoutCache
    public var errorDescription: String? {
        switch self {
        case .invalidCache: "保存済みデータの形式または保存先が不正です。元のデータを保全して保存先を確認してください。"
        case .cacheWriteFailed: "データを安全に保存できません。空き容量と保存先のアクセス権を確認してください。"
        case .missingSnapshot: "同期済みのデータがありません。"
        case .changedSource: "同期元が切り替わりました。詳細を開き直してください。"
        case .unchangedWithoutCache: "初回取得でデータが返されませんでした。再同期してください。"
        }
    }
}

@MainActor @Observable
public final class HubStore {
    public private(set) var snapshot: Snapshot?
    public private(set) var configuration: SourceConfiguration?
    public private(set) var revision: String?
    public private(set) var lastUpdated: Date?
    public private(set) var errorMessage: String?
    public private(set) var isOffline = false
    public private(set) var isSyncing = false
    public private(set) var cacheWasLoaded = false
    @ObservationIgnored private let transport: any SnapshotTransport
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private var checkpoint: CachedSnapshot?

    public var sourceIdentity: SnapshotIdentity? {
        guard let configuration, let revision else { return nil }
        return SnapshotIdentity(configuration: configuration, revision: revision, repositoryID: checkpoint?.repositoryID)
    }

    public init(cache: SnapshotCache = .applicationDefault, transport: any SnapshotTransport = SourceTransport()) {
        self.cache = cache
        self.transport = transport
        do {
            if let saved = try cache.load() {
                snapshot = try Snapshot.decode(saved.data)
                checkpoint = saved
                configuration = saved.configuration
                revision = saved.revision
                lastUpdated = saved.checkedAt
                cacheWasLoaded = true
            }
        } catch {
            errorMessage = "保存済みデータを読み込めません。\(error.localizedDescription)"
        }
    }

    @discardableResult
    public func synchronize(using source: SourceConfiguration? = nil) async -> Bool {
        guard !isSyncing, let candidate = source ?? configuration else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try candidate.validated()
            let previous = checkpoint?.configuration == candidate ? checkpoint : nil
            let fetched = try await transport.fetchSnapshot(configuration: candidate,
                previousRevision: previous?.revision, etag: previous?.etag, repositoryID: previous?.repositoryID)
            try Task.checkCancellation()
            guard let bytes = fetched.data ?? previous?.data else { throw StoreError.unchangedWithoutCache }
            let decoded = try Snapshot.decode(bytes)
            let mustCompare = previous != nil || decoded.storeID == snapshot?.storeID
            try decoded.validate(previous: mustCompare ? snapshot : nil)
            let saved = CachedSnapshot(configuration: candidate, revision: fetched.revision,
                etag: fetched.etag, repositoryID: fetched.repositoryID, checkedAt: .now, data: bytes)
            let outcome = try cache.save(saved)
            checkpoint = saved
            snapshot = decoded
            configuration = candidate
            revision = fetched.revision
            lastUpdated = saved.checkedAt
            errorMessage = outcome == .durable ? nil : "最新データを保存・表示しましたが、ディスクへの永続化を確認できません。再同期して確認してください。"
            isOffline = false
            cacheWasLoaded = false
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            isOffline = (error as? SourceTransportError) == .networkUnavailable ||
                (error as? SourceTransportError) == .timedOut || ((error as? URLError).map {
                    [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains($0.code)
                } ?? false)
            return false
        }
    }

    public func attachmentData(_ attachment: AttachmentRecord) async throws -> Data {
        guard let checkpoint else { throw StoreError.missingSnapshot }
        let data = try await transport.fetchBlob(path: attachment.blobPath, sha256: attachment.sha256,
            size: attachment.sizeBytes, configuration: checkpoint.configuration,
            revision: checkpoint.revision, repositoryID: checkpoint.repositoryID)
        guard self.checkpoint?.configuration == checkpoint.configuration else { throw StoreError.changedSource }
        return data
    }

    public func auditContext() throws -> AuditContext {
        guard let checkpoint, let snapshot else { throw StoreError.missingSnapshot }
        return AuditContext(configuration: checkpoint.configuration, revision: checkpoint.revision,
            repositoryID: checkpoint.repositoryID, snapshot: snapshot, transport: transport)
    }
}
