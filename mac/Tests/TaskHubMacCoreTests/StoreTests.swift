//
//  StoreTests.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import CryptoKit
import Foundation
import XCTest
@testable import TaskHubMacCore

private actor TestTransport: SnapshotTransport {
    var response: SourceFetch
    var failure = false
    var events: [Int: Data] = [:]
    var calls = 0
    var delay = false

    init(data: Data) { response = SourceFetch(data: data, revision: String(repeating: "a", count: 40), etag: "v1", repositoryID: nil) }
    func set(data: Data?, revision: String = String(repeating: "b", count: 40)) {
        response = SourceFetch(data: data, revision: revision, etag: "v2", repositoryID: nil)
    }
    func fail() { failure = true }
    func slow() { delay = true }
    func set(events: [Int: Data]) { self.events = events }
    func count() -> Int { calls }
    func fetchSnapshot(configuration: SourceConfiguration, previousRevision: String?, etag: String?, repositoryID: Int?) async throws -> SourceFetch {
        calls += 1
        if delay { try await Task.sleep(for: .milliseconds(50)) }
        if failure { throw URLError(.notConnectedToInternet) }
        return response
    }
    func fetchBlob(path: String, sha256: String, size: Int, configuration: SourceConfiguration, revision: String, repositoryID: Int?) async throws -> Data { Data() }
    func fetchEvent(seq: Int, configuration: SourceConfiguration, revision: String, repositoryID: Int?) async throws -> Data {
        guard let bytes = events[seq] else { throw URLError(.fileDoesNotExist) }
        return bytes
    }
}

final class StoreTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "snapshot-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func temporaryCache() -> SnapshotCache {
        SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("taskhub-store-tests-\(UUID())"))
    }

    @MainActor func testSuccessfulSyncPersistsAndRelaunchLoadsSameSnapshot() async throws {
        let bytes = try fixture()
        let transport = TestTransport(data: bytes)
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: transport)
        let success = await store.synchronize(using: .local(directory: "/tmp/taskhub-fixture"))
        XCTAssertTrue(success)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot, try Snapshot.decode(bytes))
        let relaunched = HubStore(cache: cache, transport: transport)
        XCTAssertEqual(relaunched.snapshot, store.snapshot)
        XCTAssertTrue(relaunched.cacheWasLoaded)
        let attrs = try FileManager.default.attributesOfItem(atPath: cache.directory.appendingPathComponent("snapshot-cache.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    @MainActor func testFailureAndUnknownSchemaPreserveAcceptedSnapshotAndDisk() async throws {
        let bytes = try fixture()
        let transport = TestTransport(data: bytes)
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: transport)
        _ = await store.synchronize(using: .local(directory: "/tmp/taskhub-fixture"))
        let accepted = store.snapshot
        await transport.set(data: Data("{\"schema_version\":2}".utf8))
        let unknown = await store.synchronize()
        XCTAssertFalse(unknown)
        XCTAssertEqual(store.snapshot, accepted)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try cache.load()?.data, bytes)
        await transport.fail()
        let offline = await store.synchronize()
        XCTAssertFalse(offline)
        XCTAssertTrue(store.isOffline)
        XCTAssertEqual(store.snapshot, accepted)
        XCTAssertFalse(store.isSyncing)
    }

    @MainActor func testUnchangedResponseKeepsDataAndCanRefreshAfterRelaunch() async throws {
        let bytes = try fixture()
        let transport = TestTransport(data: bytes)
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: transport)
        _ = await store.synchronize(using: .local(directory: "/tmp/taskhub-fixture"))
        await transport.set(data: nil)
        let success = await store.synchronize()
        XCTAssertTrue(success)
        XCTAssertEqual(try cache.load()?.data, bytes)
        XCTAssertEqual(store.revision, String(repeating: "b", count: 40))
    }

    @MainActor func testSourceSwitchFailureKeepsPreviousSource() async throws {
        let transport = TestTransport(data: try fixture())
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: transport)
        let original = SourceConfiguration.local(directory: "/tmp/taskhub-first")
        _ = await store.synchronize(using: original)
        await transport.fail()
        let result = await store.synchronize(using: .local(directory: "/tmp/taskhub-second"))
        XCTAssertFalse(result)
        XCTAssertEqual(store.configuration, original)
        XCTAssertEqual(try cache.load()?.configuration, original)
    }

    @MainActor func testConcurrentRefreshIsCoalesced() async throws {
        let transport = TestTransport(data: try fixture())
        await transport.slow()
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: transport)
        let first = Task { await store.synchronize(using: .local(directory: "/tmp/taskhub-fixture")) }
        await Task.yield()
        while !store.isSyncing { await Task.yield() }
        let second = await store.synchronize(using: .local(directory: "/tmp/taskhub-fixture"))
        XCTAssertFalse(second)
        let result = await first.value
        XCTAssertTrue(result)
        let calls = await transport.count()
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testFullAuditChainAndTamperPreservesVerifiedEntries() async throws {
        let transport = TestTransport(data: try fixture())
        var snapshot = try Snapshot.decode(fixture())
        let first: [String: Any] = ["schema_version": 1, "seq": 1, "actor": "agent-test", "occurred_at": "2026-10-10T12:00:00Z",
                                    "type": "lane.created", "prev_hash": NSNull(), "payload": ["id": "lane-test", "name": "テスト"]]
        let firstBytes = try JSONSerialization.data(withJSONObject: first, options: .sortedKeys)
        let firstHash = SHA256.hash(data: firstBytes).map { String(format: "%02x", $0) }.joined()
        let second: [String: Any] = ["schema_version": 1, "seq": 2, "actor": "agent-test", "occurred_at": "2026-10-10T12:01:00Z",
                                     "type": "lane.updated", "prev_hash": firstHash, "payload": ["id": "lane-test", "changes": ["name": "更新"]]]
        let secondBytes = try JSONSerialization.data(withJSONObject: second, options: .sortedKeys)
        snapshot.lastEventSeq = 2
        snapshot.lastEventHash = SHA256.hash(data: secondBytes).map { String(format: "%02x", $0) }.joined()
        await transport.set(events: [1: firstBytes, 2: secondBytes])
        let context = AuditContext(configuration: .local(directory: "/tmp/taskhub-fixture"), revision: "local", repositoryID: nil,
                                   snapshot: snapshot, transport: transport)
        let history = AuditHistory(context: context)
        await history.loadMore(count: 1)
        XCTAssertEqual(history.entries.map(\.id), [2])
        XCTAssertEqual(history.nextSequence, 1)
        await transport.set(events: [1: Data("tampered".utf8)])
        await history.loadMore()
        XCTAssertNotNil(history.errorMessage)
        XCTAssertEqual(history.entries.map(\.id), [2])
        XCTAssertEqual(history.nextSequence, 1)
        await transport.set(events: [1: firstBytes])
        await history.loadMore()
        XCTAssertNil(history.errorMessage)
        XCTAssertEqual(history.entries.map(\.id), [2, 1])
        XCTAssertEqual(history.nextSequence, 0)
    }

    @MainActor func testSameStoreRollbackIsRejectedAcrossSourceChange() async throws {
        let older = try fixture()
        var newer = try Snapshot.decode(older)
        newer.lastEventSeq += 1
        newer.lastEventHash = String(repeating: "b", count: 64)
        newer.lanes[0].revision = newer.lastEventSeq
        newer.lanes[0].updatedAt = newer.generatedAt!
        let transport = TestTransport(data: try JSONEncoder().encode(newer))
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: transport)
        let success = await store.synchronize(using: .local(directory: "/tmp/taskhub-first"))
        XCTAssertTrue(success, store.errorMessage ?? "")
        await transport.set(data: older)
        let rolledBack = await store.synchronize(using: .local(directory: "/tmp/taskhub-second"))
        XCTAssertFalse(rolledBack)
        XCTAssertEqual(store.snapshot?.lastEventSeq, newer.lastEventSeq)
    }

    func testCacheRejectsSymlinkAndBroadDirectoryPermissions() throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let saved = CachedSnapshot(configuration: .local(directory: "/tmp/data"), revision: String(repeating: "a", count: 64),
            etag: nil, repositoryID: nil, checkedAt: .now, data: try fixture())
        try cache.save(saved)
        let original = cache.directory.appendingPathComponent("original.json")
        let file = cache.directory.appendingPathComponent("snapshot-cache.json")
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertThrowsError(try cache.load())
        XCTAssertThrowsError(try cache.save(saved))
        XCTAssertEqual(try JSONDecoder().decode(CachedSnapshot.self, from: Data(contentsOf: original)).data, saved.data)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cache.directory.path)
        XCTAssertThrowsError(try cache.save(saved))
        XCTAssertThrowsError(try cache.load())
    }

    @MainActor func testSourceIdentityChangesForSameRevisionAtDifferentLocation() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache, transport: TestTransport(data: try fixture()))
        _ = await store.synchronize(using: .local(directory: "/tmp/taskhub-first"))
        let first = store.sourceIdentity
        _ = await store.synchronize(using: .local(directory: "/tmp/taskhub-copy"))
        XCTAssertNotEqual(first, store.sourceIdentity)
        XCTAssertEqual(first?.revision, store.sourceIdentity?.revision)
        XCTAssertEqual(try store.auditContext().configuration, .local(directory: "/tmp/taskhub-copy"))
    }

    @MainActor func testDirectorySyncFailureAdoptsPublishedCacheWithWarning() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let transport = TestTransport(data: try fixture())
        let original = HubStore(cache: cache, transport: transport)
        _ = await original.synchronize(using: .local(directory: "/tmp/taskhub-first"))
        let failing = SnapshotCache(directory: cache.directory, directorySync: { _ in -1 })
        let store = HubStore(cache: failing, transport: transport)
        let adopted = await store.synchronize(using: .local(directory: "/tmp/taskhub-second"))
        XCTAssertTrue(adopted)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.configuration, .local(directory: "/tmp/taskhub-second"))
        XCTAssertEqual(try cache.load()?.configuration, store.configuration)
        let reloaded = HubStore(cache: cache, transport: transport)
        XCTAssertEqual(reloaded.configuration, store.configuration)
        XCTAssertEqual(reloaded.snapshot, store.snapshot)
    }

    @MainActor func testServerGeneratedContractWhenProvided() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TASKHUB_CONTRACT_FIXTURE"] else {
            throw XCTSkip("TASKHUB_CONTRACT_FIXTURE指定時にサーバー実データとの統合検証を実行")
        }
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let store = HubStore(cache: cache)
        let success = await store.synchronize(using: .local(directory: directory))
        XCTAssertTrue(success, store.errorMessage ?? "")
        let snapshot = try XCTUnwrap(store.snapshot)
        XCTAssertGreaterThan(snapshot.tasks.count, 2)
        XCTAssertEqual(Set(snapshot.decisions.map(\.status)), [.pending, .answered, .applied])
        for attachment in snapshot.attachments {
            let bytes = try await store.attachmentData(attachment)
            XCTAssertEqual(bytes.count, attachment.sizeBytes)
        }
        let history = AuditHistory(context: try store.auditContext())
        while history.nextSequence > 0 && history.errorMessage == nil { await history.loadMore() }
        XCTAssertNil(history.errorMessage)
        XCTAssertEqual(history.entries.count, snapshot.lastEventSeq)
    }
}
