//
//  SyncTests.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import XCTest
@testable import TaskHubCore

@MainActor
final class SyncTests: XCTestCase {
    private let configuration = RepositoryConfiguration(owner: "Example", repository: "task-hub", branch: "feature/read-only")
    private let token = "test-only-not-a-real-token"
    private let oldSHA = String(repeating: "1", count: 40)
    private let newSHA = String(repeating: "2", count: 40)

    func testConfigurationRejectsURLsHostInjectionAndInvalidRefs() throws {
        try configuration.validated()
        XCTAssertEqual(configuration.identity, "github.com/example/task-hub@feature/read-only")
        for owner in ["", "https://evil.example", "a/b", "a@evil.example", "-owner", "owner\n"] {
            XCTAssertThrowsError(try RepositoryConfiguration(owner: owner, repository: "data", branch: "main").validated())
        }
        for repository in ["", "..", ".", "-repo", "owner/repo", "data?ref=other", "data%2Fother"] {
            XCTAssertThrowsError(try RepositoryConfiguration(owner: "owner", repository: repository, branch: "main").validated())
        }
        for branch in ["", "-main", "/main", "main/", "a//b", "a/../b", ".hidden", "a/.hidden", "main.lock", "a.lock/b", "main.", "main@{1}", "a b", "a\nb", "a\\b", "main?x", "main*", "main:other", "@"] {
            XCTAssertThrowsError(try RepositoryConfiguration(owner: "owner", repository: "data", branch: branch).validated(), branch)
        }
        try RepositoryConfiguration(owner: "owner", repository: "data", branch: "機能/読み取り").validated()
    }

    func testInitialSyncUsesPrivateMetadataAndSHAForRawSnapshot() async throws {
        let transport = MockHTTPTransport([.response(metadata()), .response(commit(oldSHA)), .response(try snapshotResponse())])
        let result = try await GitHubClient(transport: transport).synchronize(configuration: configuration, token: token, previous: nil)
        XCTAssertEqual(result.repositoryID, 7)
        XCTAssertEqual(result.commitSHA, oldSHA)
        XCTAssertEqual(result.etag, "\"old-etag\"")
        XCTAssertEqual(result.snapshot, try snapshot())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        }
        XCTAssertEqual(requests[0].url?.path, "/repos/Example/task-hub")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/repos/Example/task-hub/commits/heads%2Ffeature%2Fread-only")
        XCTAssertEqual(requests[2].url?.path, "/repos/Example/task-hub/contents/snapshot.json")
        XCTAssertEqual(query(requests[2], "ref"), oldSHA)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        let limits = await transport.limits
        XCTAssertEqual(limits, Array(repeating: 33_554_432, count: 3))
    }

    func test304RechecksPrivateMetadataAndRetainsOnlyPreviouslyVerifiedSHAAndETag() async throws {
        let previous = try cached()
        let transport = MockHTTPTransport([
            .response(metadata()), .response(HTTPResponse(statusCode: 304, headers: ["ETag": "\"unverified-new-etag\""]))
        ])
        let result = try await GitHubClient(transport: transport).synchronize(configuration: configuration, token: token, previous: previous)
        XCTAssertEqual(result.commitSHA, previous.commitSHA)
        XCTAssertEqual(result.etag, previous.etag)
        XCTAssertEqual(result.snapshot, previous.snapshot)
        XCTAssertGreaterThan(result.checkedAt, previous.checkedAt)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), previous.etag)
    }

    func test304WithoutSafeConditionalCacheIsRejected() async throws {
        var withoutETag = try cached()
        withoutETag.etag = nil
        for previous in [nil, CachedSnapshot(snapshot: try snapshot()), withoutETag] {
            let transport = MockHTTPTransport([.response(metadata()), .response(HTTPResponse(statusCode: 304))])
            await assertSyncError(.invalidResponse) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: previous)
            }
            let requests = await transport.requests
            XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-None-Match"))
        }
    }

    func testImportedSnapshotDoesNotSupplyETagAndCanBecomePinned() async throws {
        let previous = CachedSnapshot(checkedAt: Date(timeIntervalSince1970: 123), snapshot: try snapshot())
        let transport = MockHTTPTransport([.response(metadata()), .response(commit(newSHA)), .response(try snapshotResponse())])
        let result = try await GitHubClient(transport: transport).synchronize(configuration: configuration, token: token, previous: previous)
        XCTAssertEqual(result.configuration, configuration)
        XCTAssertEqual(result.repositoryID, 7)
        XCTAssertEqual(result.commitSHA, newSHA)
        let requests = await transport.requests
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testRepositoryIDChangeAndPublicRepositoryStopBeforeContents() async throws {
        let previous = try cached()
        for (response, expected) in [(metadata(id: 8), GitHubSyncError.repositoryChanged),
                                     (metadata(isPrivate: false), .publicRepository)] {
            let transport = MockHTTPTransport([.response(response)])
            await assertSyncError(expected) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: previous)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
        }
    }

    func testRepositoryOrBranchChangeIsRejectedBeforeSendingToken() async throws {
        let previous = try cached()
        for next in [RepositoryConfiguration(owner: "other", repository: "task-hub", branch: configuration.branch),
                     RepositoryConfiguration(owner: configuration.owner, repository: "other", branch: configuration.branch),
                     RepositoryConfiguration(owner: configuration.owner, repository: configuration.repository, branch: "other")] {
            let transport = MockHTTPTransport([])
            await assertSyncError(.configurationChanged) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: next, token: self.token, previous: previous)
            }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testAuthRateLimitNotFoundAndRedirectErrorsDoNotExposeResponseSecrets() async {
        let cases: [(Int, [String: String], GitHubSyncError)] = [
            (401, [:], .unauthorized), (403, [:], .forbidden),
            (403, ["x-ratelimit-remaining": "0"], .rateLimited),
            (403, ["retry-after": "60"], .rateLimited), (429, [:], .rateLimited),
            (404, [:], .notFound), (302, ["Location": "https://evil.example/secret"], .redirectRejected),
            (307, ["Location": "https://api.github.com/other"], .redirectRejected)
        ]
        for (status, headers, expected) in cases {
            let transport = MockHTTPTransport([.response(HTTPResponse(statusCode: status, headers: headers, body: Data("response-secret".utf8)))])
            await assertSyncError(expected) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: nil)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(expected.localizedDescription.contains("response-secret"))
            XCTAssertFalse(expected.localizedDescription.contains(token))
            XCTAssertFalse(expected.localizedDescription.contains("evil.example"))
        }
    }

    func testRawSnapshotRedirectIsRejectedWithoutFollowingLocation() async {
        let transport = MockHTTPTransport([
            .response(metadata()), .response(commit(oldSHA)),
            .response(HTTPResponse(statusCode: 302, headers: ["Location": "https://raw.githubusercontent.com/private/snapshot.json"]))
        ])
        await assertSyncError(.redirectRejected) {
            _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: nil)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.github.com" })
    }

    func testNetworkErrorsAreSanitizedAndCancellationIsPreserved() async {
        let transport = MockHTTPTransport([.secretFailure])
        await assertSyncError(.network) {
            _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: nil)
        }
        let cancelled = MockHTTPTransport([.cancelled])
        do {
            _ = try await GitHubClient(transport: cancelled).synchronize(configuration: configuration, token: token, previous: nil)
            XCTFail("Cancellation must stop synchronization")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testInvalidTokenAndCacheETagNeverReachTransport() async throws {
        for badToken in ["", "token\r\nAuthorization: leaked", "token with spaces"] {
            let transport = MockHTTPTransport([])
            await assertSyncError(.invalidToken) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: badToken, previous: nil)
            }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
        var previous = try cached()
        previous.etag = "\"tag\"\r\nX-Leak: secret"
        let transport = MockHTTPTransport([])
        await assertSyncError(.invalidResponse) {
            _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: previous)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testNewCommitAndETagPublishOnlyAfterSnapshotAndAncestrySucceed() async throws {
        let previous = try cached()
        var newer = previous.snapshot
        newer.lastEventSeq += 1
        newer.lastEventHash = String(repeating: "b", count: 64)
        newer.generatedAt = newer.generatedAt?.addingTimeInterval(1)
        let transport = MockHTTPTransport([
            .response(metadata()), .response(commit(newSHA, etag: "\"new-etag\"")),
            .response(HTTPResponse(statusCode: 200, body: try Snapshot.makeEncoder().encode(newer))),
            .response(comparison(status: "ahead"))
        ])
        let result = try await GitHubClient(transport: transport).synchronize(configuration: configuration, token: token, previous: previous)
        XCTAssertEqual(result.snapshot, newer)
        XCTAssertEqual(result.commitSHA, newSHA)
        XCTAssertEqual(result.etag, "\"new-etag\"")
        let requests = await transport.requests
        XCTAssertEqual(query(requests[2], "ref"), newSHA)
        XCTAssertEqual(requests[3].url?.path, "/repos/Example/task-hub/compare/\(oldSHA)...\(newSHA)")
        XCTAssertNil(requests[3].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testSameSequenceCommitRewriteIsDetectedByAncestry() async throws {
        let previous = try cached()
        for status in ["behind", "diverged", "identical"] {
            let transport = MockHTTPTransport([
                .response(metadata()), .response(commit(newSHA)), .response(try snapshotResponse()),
                .response(comparison(status: status))
            ])
            await assertSyncError(.historyRewritten) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: previous)
            }
        }
        let transport = MockHTTPTransport([
            .response(metadata()), .response(commit(newSHA)), .response(try snapshotResponse()),
            .response(comparison(status: "ahead", mergeBase: newSHA))
        ])
        await assertSyncError(.historyRewritten) {
            _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: previous)
        }
    }

    func testSnapshotFailureLeavesPersistedSHAETagAndDataUnchanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let previous = try cached()
        try await cache.save(previous)
        let file = directory.appendingPathComponent("snapshot-cache.json")
        let originalBytes = try Data(contentsOf: file)
        let transport = MockHTTPTransport([
            .response(metadata()), .response(commit(newSHA, etag: "\"new-etag\"")),
            .response(HTTPResponse(statusCode: 503, body: Data("private-server-message".utf8)))
        ])
        do {
            let result = try await GitHubClient(transport: transport).synchronize(configuration: configuration, token: token, previous: previous)
            try await cache.save(result)
            XCTFail("Failed snapshot must not be saved")
        } catch { XCTAssertEqual(error as? GitHubSyncError, .invalidResponse) }
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        let loaded = try await cache.load()
        XCTAssertEqual(loaded?.commitSHA, previous.commitSHA)
        XCTAssertEqual(loaded?.etag, previous.etag)
        XCTAssertEqual(loaded?.checkedAt, previous.checkedAt)
        XCTAssertEqual(loaded?.snapshot, previous.snapshot)
    }

    func testInvalidSnapshotRollbackHashChangeStoreMismatchAndUnknownSchemaAreRejected() async throws {
        let previous = try cached()
        var wrongHash = previous.snapshot
        wrongHash.lastEventHash = String(repeating: "b", count: 64)
        var wrongStore = previous.snapshot
        wrongStore.storeID = UUID().uuidString.lowercased()
        var wrongSchema = previous.snapshot
        wrongSchema.schemaVersion = 2
        let emptyURL = try XCTUnwrap(Bundle.module.url(forResource: "empty-snapshot", withExtension: "json", subdirectory: "Fixtures"))
        var rolledBack = try Snapshot.decode(Data(contentsOf: emptyURL))
        rolledBack.storeID = previous.snapshot.storeID
        let encoder = Snapshot.makeEncoder()
        for data in [try encoder.encode(wrongHash), try encoder.encode(wrongStore), try encoder.encode(wrongSchema),
                     try encoder.encode(rolledBack), Data("{invalid".utf8)] {
            let transport = MockHTTPTransport([
                .response(metadata()), .response(commit(newSHA)), .response(HTTPResponse(statusCode: 200, body: data))
            ])
            await assertSyncError(.invalidSnapshot) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: previous)
            }
            XCTAssertEqual(previous.commitSHA, oldSHA)
            XCTAssertEqual(previous.etag, "\"old-etag\"")
        }
    }

    func testUnchangedSHA200StillValidatesSnapshotAndDoesNotReuseMissingETag() async throws {
        let previous = try cached()
        let transport = MockHTTPTransport([
            .response(metadata()), .response(commit(oldSHA, etag: nil)), .response(try snapshotResponse())
        ])
        let result = try await GitHubClient(transport: transport).synchronize(configuration: configuration, token: token, previous: previous)
        XCTAssertEqual(result.commitSHA, oldSHA)
        XCTAssertNil(result.etag)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testMalformedMetadataAndCommitSHAAreRejected() async {
        for body in ["{\"id\":7}", "{\"id\":0,\"private\":true}", "{\"id\":\"7\",\"private\":true}"] {
            let transport = MockHTTPTransport([.response(HTTPResponse(statusCode: 200, body: Data(body.utf8)))])
            await assertSyncError(.invalidResponse) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: nil)
            }
        }
        for sha in ["main", "../../other", String(repeating: "A", count: 40), "https://evil.example"] {
            let transport = MockHTTPTransport([.response(metadata()), .response(commit(sha))])
            await assertSyncError(.invalidResponse) {
                _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: nil)
            }
        }
    }

    func testDownloadLimitIsEnforcedEvenWhenInjectedTransportIgnoresIt() async {
        let transport = MockHTTPTransport([.response(HTTPResponse(statusCode: 200, body: Data(repeating: 0, count: 33_554_433)))])
        await assertSyncError(.responseTooLarge) {
            _ = try await GitHubClient(transport: transport).synchronize(configuration: self.configuration, token: self.token, previous: nil)
        }
    }

    func testAttachmentUsesExactHashPathAndSamePinnedCommitAndRechecksPrivateEveryTime() async throws {
        let previous = try cached()
        let attachment = try XCTUnwrap(previous.snapshot.attachments.first)
        let transport = MockHTTPTransport([
            .response(metadata()), .response(HTTPResponse(statusCode: 200)),
            .response(metadata()), .response(HTTPResponse(statusCode: 200))
        ])
        let client = GitHubClient(transport: transport)
        for _ in 0..<2 {
            let data = try await client.attachment(attachment, from: previous, token: token)
            XCTAssertTrue(data.isEmpty)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        for index in [0, 2] { XCTAssertEqual(requests[index].url?.path, "/repos/Example/task-hub") }
        for index in [1, 3] {
            XCTAssertEqual(requests[index].url?.path, "/repos/Example/task-hub/contents/\(attachment.blobPath)")
            XCTAssertEqual(query(requests[index], "ref"), oldSHA)
            XCTAssertEqual(requests[index].value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
            XCTAssertNil(requests[index].value(forHTTPHeaderField: "If-None-Match"))
        }
    }

    func testAttachmentSizeAndSHA256AreVerified() async throws {
        var previous = try cached()
        let hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        previous.snapshot.attachments[0].sha256 = hash
        previous.snapshot.attachments[0].blobPath = "blobs/sha256/2c/\(hash)"
        previous.snapshot.attachments[0].sizeBytes = 5
        let attachment = previous.snapshot.attachments[0]
        for body in ["jello", "hell", "hello!"] {
            let transport = MockHTTPTransport([.response(metadata()), .response(HTTPResponse(statusCode: 200, body: Data(body.utf8)))])
            await assertSyncError(.invalidAttachment) {
                _ = try await GitHubClient(transport: transport).attachment(attachment, from: previous, token: self.token)
            }
        }
        let transport = MockHTTPTransport([.response(metadata()), .response(HTTPResponse(statusCode: 200, body: Data("hello".utf8)))])
        let data = try await GitHubClient(transport: transport).attachment(attachment, from: previous, token: token)
        XCTAssertEqual(data, Data("hello".utf8))
    }

    func testInvalidBlobPathsAndUnlistedAttachmentsAreRejectedBeforeDownload() async throws {
        let previous = try cached()
        let original = try XCTUnwrap(previous.snapshot.attachments.first)
        var candidates: [AttachmentRecord] = []
        for path in ["../../secret", "https://evil.example/blob", "blobs/sha256/ee/\(original.sha256)", "blobs/sha256/e3/%2e%2e"] {
            var invalid = original
            invalid.blobPath = path
            candidates.append(invalid)
        }
        var unlisted = original
        unlisted.id = "a_11111111111141118111111111111111"
        candidates.append(unlisted)
        var oversized = original
        oversized.sizeBytes = 33_554_433
        candidates.append(oversized)
        for attachment in candidates {
            let transport = MockHTTPTransport([])
            await assertSyncError(.invalidAttachment) {
                _ = try await GitHubClient(transport: transport).attachment(attachment, from: previous, token: self.token)
            }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testAttachmentRejectsPublicRepositoryChangedIDAndUnpinnedImports() async throws {
        let previous = try cached()
        let attachment = try XCTUnwrap(previous.snapshot.attachments.first)
        for (response, expected) in [(metadata(isPrivate: false), GitHubSyncError.publicRepository),
                                     (metadata(id: 8), .repositoryChanged),
                                     (HTTPResponse(statusCode: 302, headers: ["Location": "https://evil.example"]), .redirectRejected)] {
            let transport = MockHTTPTransport([.response(response)])
            await assertSyncError(expected) {
                _ = try await GitHubClient(transport: transport).attachment(attachment, from: previous, token: self.token)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
        let transport = MockHTTPTransport([])
        await assertSyncError(.attachmentUnavailable) {
            _ = try await GitHubClient(transport: transport).attachment(attachment, from: CachedSnapshot(snapshot: previous.snapshot), token: self.token)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCacheRoundTripPrivatePermissionsBackupExclusionAndFailedSaveRetention() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let missing = try await cache.load()
        XCTAssertNil(missing)
        let previous = try cached()
        try await cache.save(previous)
        let loaded = try await cache.load()
        XCTAssertEqual(loaded?.configuration, previous.configuration)
        XCTAssertEqual(loaded?.repositoryID, previous.repositoryID)
        XCTAssertEqual(loaded?.commitSHA, previous.commitSHA)
        XCTAssertEqual(loaded?.etag, previous.etag)
        XCTAssertEqual(loaded?.checkedAt, previous.checkedAt)
        XCTAssertEqual(loaded?.snapshot, previous.snapshot)
        let file = directory.appendingPathComponent("snapshot-cache.json")
        let originalBytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: originalBytes, as: UTF8.self).contains(token))
        let manager = FileManager.default
        XCTAssertEqual((try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #if os(iOS)
        XCTAssertEqual(try manager.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        var invalid = previous
        invalid.snapshot.schemaVersion = 999
        do {
            try await cache.save(invalid)
            XCTFail("Invalid snapshot must not replace the cache")
        } catch { XCTAssertEqual(error as? SnapshotCacheError, .writeFailed) }
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.path), ["snapshot-cache.json"])
    }

    func testCacheImportDefaultsRoundTripAndMalformedCacheFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory)
        let imported = CachedSnapshot(checkedAt: Date(timeIntervalSince1970: 123.125), snapshot: try snapshot())
        try await cache.save(imported)
        let loaded = try await cache.load()
        XCTAssertNil(loaded?.configuration)
        XCTAssertNil(loaded?.repositoryID)
        XCTAssertNil(loaded?.commitSHA)
        XCTAssertNil(loaded?.etag)
        XCTAssertEqual(loaded?.checkedAt, imported.checkedAt)
        let file = directory.appendingPathComponent("snapshot-cache.json")
        try Data("{corrupt".utf8).write(to: file)
        do {
            _ = try await cache.load()
            XCTFail("Corrupt cache must not appear empty")
        } catch { XCTAssertEqual(error as? SnapshotCacheError, .readFailed) }
    }

    func testCacheRejectsSymlinkAndOversizedFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("snapshot-cache.json")
        let target = directory.appendingPathComponent("target.json")
        try Data("private-target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let cache = SnapshotCache(directory: directory)
        do { _ = try await cache.load(); XCTFail("Symlink must not be read") }
        catch { XCTAssertEqual(error as? SnapshotCacheError, .readFailed) }
        do { try await cache.save(cached()); XCTFail("Symlink must not be replaced") }
        catch { XCTAssertEqual(error as? SnapshotCacheError, .writeFailed) }
        XCTAssertEqual(try Data(contentsOf: target), Data("private-target".utf8))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(33_554_432 + 64 * 1024 + 1))
        try handle.close()
        do { _ = try await cache.load(); XCTFail("Oversized cache must not be read") }
        catch { XCTAssertEqual(error as? SnapshotCacheError, .readFailed) }
    }

    func testCredentialValidationDoesNotAccessExistingCredentials() {
        XCTAssertThrowsError(try CredentialStore.read(for: "")) { error in
            XCTAssertEqual(error as? CredentialStoreError, .invalidInput)
        }
        XCTAssertThrowsError(try CredentialStore.save("token\n", for: configuration.identity)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .invalidInput)
        }
    }

    private func snapshot() throws -> Snapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "server-snapshot", withExtension: "json", subdirectory: "Fixtures"))
        return try Snapshot.decode(Data(contentsOf: url))
    }

    private func snapshotResponse() throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: try Snapshot.makeEncoder().encode(snapshot()))
    }

    private func cached() throws -> CachedSnapshot {
        CachedSnapshot(configuration: configuration, repositoryID: 7, commitSHA: oldSHA, etag: "\"old-etag\"",
                       checkedAt: Date(timeIntervalSince1970: 1_700_000_000.125), snapshot: try snapshot())
    }

    private func metadata(id: Int = 7, isPrivate: Bool = true) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data("{\"id\":\(id),\"private\":\(isPrivate)}".utf8))
    }

    private func commit(_ sha: String, etag: String? = "\"old-etag\"") -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: etag.map { ["ETag": $0] } ?? [:], body: Data("{\"sha\":\"\(sha)\"}".utf8))
    }

    private func comparison(status: String, mergeBase: String? = nil) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data("{\"status\":\"\(status)\",\"merge_base_commit\":{\"sha\":\"\(mergeBase ?? oldSHA)\"}}".utf8))
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TaskHubSyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func assertSyncError(_ expected: GitHubSyncError, file: StaticString = #filePath, line: UInt = #line,
                                 operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected synchronization failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? GitHubSyncError, expected, file: file, line: line) }
    }
}

private actor MockHTTPTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(HTTPResponse)
        case secretFailure
        case cancelled
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var limits: [Int] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> HTTPResponse {
        requests.append(request)
        limits.append(maximumBytes)
        guard !replies.isEmpty else { throw GitHubSyncError.invalidResponse }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .secretFailure: throw NSError(domain: "secret-domain", code: 1, userInfo: [NSLocalizedDescriptionKey: "response-secret"])
        case .cancelled: throw CancellationError()
        }
    }
}
