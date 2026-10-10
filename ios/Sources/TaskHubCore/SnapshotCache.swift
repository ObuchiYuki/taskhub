//
//  SnapshotCache.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Darwin
import Foundation

public struct CachedSnapshot: Codable, Sendable {
    public var configuration: RepositoryConfiguration?
    public var repositoryID: Int?
    public var commitSHA: String?
    public var etag: String?
    public var checkedAt: Date
    public var snapshot: Snapshot

    public init(
        configuration: RepositoryConfiguration? = nil,
        repositoryID: Int? = nil,
        commitSHA: String? = nil,
        etag: String? = nil,
        checkedAt: Date = Date(),
        snapshot: Snapshot
    ) {
        self.configuration = configuration
        self.repositoryID = repositoryID
        self.commitSHA = commitSHA
        self.etag = etag
        self.checkedAt = checkedAt
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case configuration, repositoryID, commitSHA, etag, checkedAt, snapshot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decodeIfPresent(RepositoryConfiguration.self, forKey: .configuration)
        repositoryID = try container.decodeIfPresent(Int.self, forKey: .repositoryID)
        commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        checkedAt = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .checkedAt))
        snapshot = try container.decode(Snapshot.self, forKey: .snapshot)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(repositoryID, forKey: .repositoryID)
        try container.encodeIfPresent(commitSHA, forKey: .commitSHA)
        try container.encodeIfPresent(etag, forKey: .etag)
        // Cache check times retain subseconds; snapshot event dates use the domain's UTC format.
        try container.encode(checkedAt.timeIntervalSince1970, forKey: .checkedAt)
        try container.encode(snapshot, forKey: .snapshot)
    }

    func validateEnvelope() throws {
        try configuration?.validated()
        guard checkedAt.timeIntervalSince1970.isFinite,
              repositoryID.map({ $0 > 0 && configuration != nil }) ?? true,
              commitSHA.map({ GitHubClient.isCommitSHA($0) && repositoryID != nil }) ?? true,
              etag.map({ GitHubClient.isETag($0) && commitSHA != nil }) ?? true else {
            throw GitHubSyncError.invalidResponse
        }
        do { try snapshot.validated() }
        catch { throw GitHubSyncError.invalidSnapshot }
    }
}

public enum SnapshotCacheError: Error, LocalizedError, Equatable, Sendable {
    case readFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .readFailed: "保存済みデータを安全に読み込めません。キャッシュの破損または端末のロック状態を確認してください。"
        case .writeFailed: "データを安全に保存できません。空き容量と端末のロック状態を確認してください。"
        }
    }
}

public actor SnapshotCache {
    private static let maximumCacheBytes = GitHubClient.maximumResponseBytes + 64 * 1024
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("snapshot-cache.json", isDirectory: false) }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() throws -> CachedSnapshot? {
        do {
            guard directory.isFileURL else { throw SnapshotCacheError.readFailed }
            let manager = FileManager.default
            guard let directoryAttributes = try attributesIfPresent(at: directory) else { return nil }
            guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SnapshotCacheError.readFailed
            }
            guard let attributes = try attributesIfPresent(at: file) else { return nil }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value <= Int64(Self.maximumCacheBytes) else { throw SnapshotCacheError.readFailed }
            try protect(directory, isDirectory: true, manager: manager)
            try protect(file, isDirectory: false, manager: manager)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var data = Data()
            while let chunk = try handle.read(upToCount: min(64 * 1024, Self.maximumCacheBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= Self.maximumCacheBytes else { throw SnapshotCacheError.readFailed }
            }
            let value = try Snapshot.makeDecoder().decode(CachedSnapshot.self, from: data)
            try value.validateEnvelope()
            guard try Snapshot.makeEncoder().encode(value.snapshot).count <= GitHubClient.maximumResponseBytes else {
                throw SnapshotCacheError.readFailed
            }
            return value
        } catch { throw SnapshotCacheError.readFailed }
    }

    public func save(_ value: CachedSnapshot) throws {
        do {
            guard directory.isFileURL else { throw SnapshotCacheError.writeFailed }
            try value.validateEnvelope()
            let encoder = Snapshot.makeEncoder()
            guard try encoder.encode(value.snapshot).count <= GitHubClient.maximumResponseBytes else {
                throw SnapshotCacheError.writeFailed
            }
            let data = try encoder.encode(value)
            guard data.count <= Self.maximumCacheBytes else { throw SnapshotCacheError.writeFailed }
            let manager = FileManager.default
            if let attributes = try attributesIfPresent(at: directory) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SnapshotCacheError.writeFailed }
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try protect(directory, isDirectory: true, manager: manager)
            if let attributes = try attributesIfPresent(at: file), attributes[.type] as? FileAttributeType != .typeRegular {
                throw SnapshotCacheError.writeFailed
            }
            let temporary = directory.appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: temporary) }
            #if os(iOS)
            try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: temporary, options: .withoutOverwriting)
            #endif
            try protect(temporary, isDirectory: false, manager: manager)
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, file.path) == 0 else { throw SnapshotCacheError.writeFailed }
        } catch { throw SnapshotCacheError.writeFailed }
    }

    private func attributesIfPresent(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func protect(_ url: URL, isDirectory: Bool, manager: FileManager) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: isDirectory ? 0o700 : 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try manager.setAttributes(attributes, ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }
}
