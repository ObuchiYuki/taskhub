//
//  TransportTests.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TaskHubMacCore

@Suite("Read-only source transport", .serialized)
struct TransportTests {
    private let configuration = SourceConfiguration.github(repository: "owner/private-data", branch: "main")
    private let revision = String(repeating: "a", count: 40)
    private let localRevision = String(repeating: "b", count: 64)

    @Test func configurationValidationAndCodable() throws {
        let sources: [SourceConfiguration] = [.local(directory: "/tmp/taskhub"), configuration,
                                              .github(repository: "Owner/Data.repo", branch: "feature/read-only")]
        for source in sources {
            #expect(try source.validated() == source)
            #expect(!source.displayName.isEmpty)
            #expect(try JSONDecoder().decode(SourceConfiguration.self, from: JSONEncoder().encode(source)) == source)
        }
        for directory in ["relative", "~/data", "/tmp/../data", "/tmp/./data", "/tmp/data\u{0}"] {
            #expect(throws: SourceTransportError.self) { try SourceConfiguration.local(directory: directory).validated() }
        }
        for repository in ["https://github.com/a/b", "a/b/c", "a", "-a/b", "a/..", "a/-repo", "a/b?token=x", "a/b\n"] {
            #expect(throws: SourceTransportError.self) {
                try SourceConfiguration.github(repository: repository, branch: "main").validated()
            }
        }
        for branch in ["", "-main", "../main", "a..b", "a//b", "a.lock", ".hidden", "main.", "a@{b", "main?", "a%2Fb", "main\n"] {
            #expect(throws: SourceTransportError.self) {
                try SourceConfiguration.github(repository: "owner/repo", branch: branch).validated()
            }
        }
    }

    @Test func githubSnapshotIsPrivateAndCommitPinned() async throws {
        let bytes = Data("{\"snapshot\":true}\n".utf8)
        let http = MockSourceHTTPClient([
            .json(#"{"id":42,"private":true}"#), .sha(revision, etag: "\"branch-v1\""), .init(data: bytes)
        ])
        let result = try await transport(http).fetchSnapshot(configuration: configuration)
        #expect(result == SourceFetch(data: bytes, revision: revision, etag: "\"branch-v1\"", repositoryID: 42))
        let requests = await http.requests
        #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/repos/owner/private-data")
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].url?.path == "/repos/owner/private-data/commits/main")
        #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/vnd.github.sha")
        #expect(requests[2].url?.path == "/repos/owner/private-data/contents/snapshot.json")
        #expect(requests[2].url?.query == "ref=\(revision)")
        #expect(requests[2].value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "api.github.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mock-token")
            #expect(request.httpBody == nil)
            #expect(request.timeoutInterval == 30)
        }
        #expect(await http.limits == [1024 * 1024, 1024 * 1024, 32 * 1024 * 1024])
    }

    @Test func branchWithSlashIsOneEncodedRef() async throws {
        let http = MockSourceHTTPClient([.privateRepository, .sha(revision), .init(data: Data())])
        _ = try await transport(http).fetchSnapshot(configuration: .github(repository: "owner/repo", branch: "topic/safe"))
        let requests = await http.requests
        #expect(requests[1].url?.absoluteString == "https://api.github.com/repos/owner/repo/commits/topic%2Fsafe")
    }

    @Test func publicMissingAndMalformedPrivateFailClosed() async throws {
        for metadata in [#"{"id":42,"private":false}"#, #"{"id":42}"#, #"{"id":42,"private":null}"#,
                         #"{"id":42,"private":"true"}"#, #"{"id":42,"private":1}"#, "not json"] {
            let http = MockSourceHTTPClient([.json(metadata)])
            await #expect(throws: SourceTransportError.privateRepositoryRequired) {
                try await transport(http).fetchSnapshot(configuration: configuration, previousRevision: revision,
                                                         etag: "\"cached\"", repositoryID: 42)
            }
            #expect(await http.requests.count == 1)
        }
    }

    @Test func repositoryIDIsRequiredAndPinned() async throws {
        for metadata in [#"{"private":true}"#, #"{"id":0,"private":true}"#] {
            let http = MockSourceHTTPClient([.json(metadata)])
            await #expect(throws: SourceTransportError.invalidResponse) {
                try await transport(http).fetchSnapshot(configuration: configuration)
            }
        }
        let http = MockSourceHTTPClient([.json(#"{"id":43,"private":true}"#)])
        await #expect(throws: SourceTransportError.repositoryChanged) {
            try await transport(http).fetchSnapshot(configuration: configuration, repositoryID: 42)
        }
        #expect(await http.requests.count == 1)
    }

    @Test func etag304StillChecksPrivacyAndRequiresPreviousRevision() async throws {
        let http = MockSourceHTTPClient([.privateRepository, .init(status: 304, headers: ["ETag": "\"same\""])])
        let result = try await transport(http).fetchSnapshot(configuration: configuration, previousRevision: revision,
                                                            etag: "\"same\"", repositoryID: 42)
        #expect(result.data == nil)
        #expect(result.revision == revision)
        #expect(result.repositoryID == 42)
        #expect(result.etag == "\"same\"")
        let requests = await http.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"same\"")

        let withoutRevision = MockSourceHTTPClient([.privateRepository, .init(status: 304)])
        await #expect(throws: SourceTransportError.invalidResponse) {
            try await transport(withoutRevision).fetchSnapshot(configuration: configuration, etag: "\"same\"")
        }
        let unconditioned = await withoutRevision.requests
        #expect(unconditioned[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        let withoutETag = MockSourceHTTPClient([.privateRepository, .init(status: 304)])
        await #expect(throws: SourceTransportError.invalidResponse) {
            try await transport(withoutETag).fetchSnapshot(configuration: configuration, previousRevision: revision)
        }
    }

    @Test func unchanged200SkipsSnapshot() async throws {
        let http = MockSourceHTTPClient([.privateRepository, .sha(revision, etag: "\"new-tag\"")])
        let result = try await transport(http).fetchSnapshot(configuration: configuration, previousRevision: revision)
        #expect(result.data == nil)
        #expect(result.etag == "\"new-tag\"")
        #expect(await http.requests.count == 2)
    }

    @Test func malformedSHAAndETagAreRejected() async throws {
        for invalid in ["main", "../snapshot.json", String(repeating: "A", count: 40), String(repeating: "a", count: 39),
                        String(repeating: "g", count: 40), #"{"sha":"main"}"#] {
            let http = MockSourceHTTPClient([.privateRepository, .sha(invalid)])
            await #expect(throws: SourceTransportError.invalidRevision) {
                try await transport(http).fetchSnapshot(configuration: configuration)
            }
            #expect(await http.requests.count == 2)
        }
        let http = MockSourceHTTPClient([])
        await #expect(throws: SourceTransportError.invalidResponse) {
            try await transport(http).fetchSnapshot(configuration: configuration, previousRevision: revision, etag: "safe\r\nInjected: x")
        }
        #expect(await http.requests.isEmpty)
        let badResponse = MockSourceHTTPClient([.privateRepository, .sha(revision, etag: "bad\nvalue")])
        await #expect(throws: SourceTransportError.invalidResponse) {
            try await transport(badResponse).fetchSnapshot(configuration: configuration)
        }
    }

    @Test func redirectsAndUnexpectedOriginsFailClosed() async throws {
        for destination in ["https://evil.example/snapshot.json", "http://api.github.com/repos/owner/private-data",
                            "https://api.github.com.evil.example/", "https://api.github.com/elsewhere"] {
            let http = MockSourceHTTPClient([.init(data: Data(), url: URL(string: destination)!)])
            await #expect(throws: SourceTransportError.redirectRejected) {
                try await transport(http).fetchSnapshot(configuration: configuration)
            }
            #expect(await http.requests.count == 1)
        }
        let redirect = MockSourceHTTPClient([.init(status: 302, headers: ["Location": "https://evil.example/"])])
        await #expect(throws: SourceTransportError.redirectRejected) {
            try await transport(redirect).fetchSnapshot(configuration: configuration)
        }
    }

    @Test func statusAndTimeoutErrorsAreLocalizedWithoutSecrets() async throws {
        for status in [401, 403, 404, 429, 500] {
            let http = MockSourceHTTPClient([.init(status: status, headers: ["Retry-After": "12"], data: Data("mock-token".utf8))])
            let expected = SourceTransportError.httpStatus(status, retryAfter: 12)
            await #expect(throws: expected) { try await transport(http).fetchSnapshot(configuration: configuration) }
            #expect(expected.localizedDescription.contains("HTTP \(status)"))
            #expect(!expected.localizedDescription.contains("mock-token"))
        }
        let timeout = MockSourceHTTPClient([.init(error: URLError(.timedOut))])
        await #expect(throws: SourceTransportError.timedOut) {
            try await transport(timeout).fetchSnapshot(configuration: configuration)
        }
        let invalidToken = SourceTransport(httpClient: MockSourceHTTPClient([]), tokenProvider: MockToken(value: "secret\r\nHeader: x"))
        await #expect(throws: SourceTransportError.authenticationUnavailable) {
            try await invalidToken.fetchSnapshot(configuration: configuration)
        }
    }

    @Test func snapshotAbsoluteSizeLimit() async throws {
        let limit = SourceTransport.maximumFileBytes
        let exact = Data(repeating: 65, count: limit)
        let http = MockSourceHTTPClient([.privateRepository, .sha(revision), .init(data: exact)])
        let accepted = try await transport(http).fetchSnapshot(configuration: configuration)
        #expect(accepted.data?.count == limit)
        let oversized = MockSourceHTTPClient([.privateRepository, .sha(revision), .init(data: Data(repeating: 65, count: limit + 1))])
        await #expect(throws: SourceTransportError.tooLarge(limit: limit)) {
            try await transport(oversized).fetchSnapshot(configuration: configuration)
        }
    }

    @Test func githubBlobUsesPinnedCommitAndVerifiesHashAndSize() async throws {
        let data = Data("immutable attachment".utf8)
        let hash = digest(data)
        let path = blobPath(hash)
        let http = MockSourceHTTPClient([.privateRepository, .init(data: data)])
        #expect(try await transport(http).fetchBlob(path: path, sha256: hash, size: data.count, configuration: configuration,
                                                  revision: revision, repositoryID: 42) == data)
        let requests = await http.requests
        #expect(requests.count == 2)
        #expect(requests[1].url?.path == "/repos/owner/private-data/contents/\(path)")
        #expect(requests[1].url?.query == "ref=\(revision)")
        #expect(await http.limits.last == data.count)
        let changed = MockSourceHTTPClient([.privateRepository, .init(data: Data(repeating: 0, count: data.count))])
        await #expect(throws: SourceTransportError.blobIntegrityMismatch) {
            try await transport(changed).fetchBlob(path: path, sha256: hash, size: data.count,
                                                    configuration: configuration, revision: revision, repositoryID: 42)
        }
        let truncated = MockSourceHTTPClient([.privateRepository, .init(data: Data())])
        await #expect(throws: SourceTransportError.blobIntegrityMismatch) {
            try await transport(truncated).fetchBlob(path: path, sha256: hash, size: data.count,
                                                     configuration: configuration, revision: revision)
        }
    }

    @Test func blobValidationPrecedesNetworkingAndEmptyBlobWorks() async throws {
        let hash = digest(Data())
        let http = MockSourceHTTPClient([])
        for path in ["../snapshot.json", "https://example.com/file", "blobs/sha256/ff/\(hash)", blobPath(hash) + "/../x"] {
            await #expect(throws: SourceTransportError.unsafePath) {
                try await transport(http).fetchBlob(path: path, sha256: hash, size: 0, configuration: configuration, revision: revision)
            }
        }
        await #expect(throws: SourceTransportError.tooLarge(limit: SourceTransport.maximumFileBytes)) {
            try await transport(http).fetchBlob(path: blobPath(hash), sha256: hash, size: SourceTransport.maximumFileBytes + 1,
                                                configuration: configuration, revision: revision)
        }
        #expect(await http.requests.isEmpty)
        let empty = MockSourceHTTPClient([.privateRepository, .init(data: Data())])
        #expect(try await transport(empty).fetchBlob(path: blobPath(hash), sha256: hash, size: 0,
                                                   configuration: configuration, revision: revision).isEmpty)
    }

    @Test func blobsAndEventsRecheckPrivateAndRepositoryPin() async throws {
        let hash = digest(Data())
        let publicBlob = MockSourceHTTPClient([.json(#"{"id":42,"private":false}"#)])
        await #expect(throws: SourceTransportError.privateRepositoryRequired) {
            try await transport(publicBlob).fetchBlob(path: blobPath(hash), sha256: hash, size: 0,
                                                      configuration: configuration, revision: revision, repositoryID: 42)
        }
        let replacedBlob = MockSourceHTTPClient([.json(#"{"id":43,"private":true}"#)])
        await #expect(throws: SourceTransportError.repositoryChanged) {
            try await transport(replacedBlob).fetchBlob(path: blobPath(hash), sha256: hash, size: 0,
                                                        configuration: configuration, revision: revision, repositoryID: 42)
        }
        let missingPrivate = MockSourceHTTPClient([.json(#"{"id":42}"#)])
        await #expect(throws: SourceTransportError.privateRepositoryRequired) {
            try await transport(missingPrivate).fetchEvent(seq: 1, configuration: configuration, revision: revision, repositoryID: 42)
        }
    }

    @Test func eventPathAndOneMiBLimit() async throws {
        let data = Data("{\"seq\":7}\n".utf8)
        let http = MockSourceHTTPClient([.privateRepository, .init(data: data)])
        #expect(try await transport(http).fetchEvent(seq: 7, configuration: configuration, revision: revision, repositoryID: 42) == data)
        let requests = await http.requests
        #expect(requests[1].url?.path == "/repos/owner/private-data/contents/events/00000000000000000007.json")
        #expect(requests[1].url?.query == "ref=\(revision)")
        #expect(await http.limits.last == SourceTransport.maximumEventBytes)
        let large = MockSourceHTTPClient([.privateRepository, .init(data: Data(repeating: 65, count: 1024 * 1024 + 1))])
        await #expect(throws: SourceTransportError.tooLarge(limit: 1024 * 1024)) {
            try await transport(large).fetchEvent(seq: 1, configuration: configuration, revision: revision)
        }
        await #expect(throws: SourceTransportError.unsafePath) {
            try await transport(MockSourceHTTPClient([])).fetchEvent(seq: 0, configuration: configuration, revision: revision)
        }
    }

    @Test func localSnapshotHashesBytesAndDetectsUnchangedWithoutCredentials() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local snapshot\n".utf8)
        try bytes.write(to: root.appendingPathComponent("snapshot.json"))
        let source = SourceConfiguration.local(directory: root.path)
        let client = localTransport()
        let first = try await client.fetchSnapshot(configuration: source)
        #expect(first.data == bytes)
        #expect(first.revision == digest(bytes))
        #expect(first.etag == nil)
        #expect(first.repositoryID == nil)
        let second = try await client.fetchSnapshot(configuration: source, previousRevision: first.revision)
        #expect(second.data == nil)
        #expect(second.revision == first.revision)
        try Data("replacement\n".utf8).write(to: root.appendingPathComponent("snapshot.json"), options: .atomic)
        let third = try await client.fetchSnapshot(configuration: source, previousRevision: first.revision)
        #expect(third.data != nil)
        #expect(third.revision != first.revision)
    }

    @Test func localBlobAndEventAreReadWithoutGitOrCredentials() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("local blob".utf8)
        let hash = digest(data)
        let path = blobPath(hash)
        try write(data, to: root.appendingPathComponent(path))
        let event = Data("{\"seq\":1}\n".utf8)
        try write(event, to: root.appendingPathComponent("events/00000000000000000001.json"))
        let source = SourceConfiguration.local(directory: root.path)
        #expect(try await localTransport().fetchBlob(path: path, sha256: hash, size: data.count,
                                                    configuration: source, revision: localRevision) == data)
        #expect(try await localTransport().fetchEvent(seq: 1, configuration: source, revision: localRevision) == event)
        try Data(repeating: 0, count: data.count).write(to: root.appendingPathComponent(path))
        await #expect(throws: SourceTransportError.blobIntegrityMismatch) {
            try await localTransport().fetchBlob(path: path, sha256: hash, size: data.count,
                                                 configuration: source, revision: localRevision)
        }
    }

    @Test func localRejectsSymlinkRootIntermediateAndLeaf() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for directory in [link.path, link.path + "/"] {
            await #expect(throws: SourceTransportError.unsafePath) {
                try await localTransport().fetchSnapshot(configuration: .local(directory: directory))
            }
        }
        let data = Data("file".utf8)
        try data.write(to: real.appendingPathComponent("actual"))
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("snapshot.json"),
                                                   withDestinationURL: real.appendingPathComponent("actual"))
        await #expect(throws: SourceTransportError.unsafePath) {
            try await localTransport().fetchSnapshot(configuration: .local(directory: real.path))
        }
        let hash = digest(data)
        let destination = real.appendingPathComponent("actual-blobs")
        try write(data, to: destination.appendingPathComponent("sha256/\(hash.prefix(2))/\(hash)"))
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("blobs"), withDestinationURL: destination)
        await #expect(throws: SourceTransportError.unsafePath) {
            try await localTransport().fetchBlob(path: blobPath(hash), sha256: hash, size: data.count,
                                                 configuration: .local(directory: real.path), revision: localRevision)
        }
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("events"), withDestinationURL: destination)
        await #expect(throws: SourceTransportError.unsafePath) {
            try await localTransport().fetchEvent(seq: 1, configuration: .local(directory: real.path), revision: localRevision)
        }
    }

    @Test func localRejectsDirectoryFIFOAndOversize() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snapshot.json")
        let source = SourceConfiguration.local(directory: root.path)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: SourceTransportError.unsafePath) { try await localTransport().fetchSnapshot(configuration: source) }
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        await #expect(throws: SourceTransportError.unsafePath) { try await localTransport().fetchSnapshot(configuration: source) }
        try FileManager.default.removeItem(at: file)
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SourceTransport.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: SourceTransportError.tooLarge(limit: SourceTransport.maximumFileBytes)) {
            try await localTransport().fetchSnapshot(configuration: source)
        }
    }

    @Test func URLSessionStreamsWithCapEvenWithoutContentLength() async throws {
        let client = URLSessionSourceHTTPClient(protocolClasses: [TransportURLProtocol.self])
        let request = URLRequest(url: URL(string: "https://api.github.com/test")!)
        TransportURLProtocol.state.set(.response(status: 200, headers: [:], chunks: [Data(repeating: 1, count: 5), Data(repeating: 2, count: 3)]))
        let response = try await client.get(request, maximumBytes: 8)
        #expect(response.data.count == 8)
        TransportURLProtocol.state.set(.response(status: 200, headers: [:], chunks: [Data(repeating: 1, count: 5), Data(repeating: 2, count: 4)]))
        await #expect(throws: SourceTransportError.tooLarge(limit: 8)) { try await client.get(request, maximumBytes: 8) }
        TransportURLProtocol.state.set(.response(status: 200, headers: ["Content-Length": "9"], chunks: []))
        await #expect(throws: SourceTransportError.tooLarge(limit: 8)) { try await client.get(request, maximumBytes: 8) }
    }

    @Test func URLSessionRejectsRedirectBeforeSendingAuthorizationElsewhere() async throws {
        let client = URLSessionSourceHTTPClient(protocolClasses: [TransportURLProtocol.self])
        var request = URLRequest(url: URL(string: "https://api.github.com/test")!)
        request.setValue("Bearer mock-token", forHTTPHeaderField: "Authorization")
        TransportURLProtocol.state.set(.redirect(URL(string: "https://evil.example/stolen")!))
        await #expect(throws: SourceTransportError.redirectRejected) { try await client.get(request, maximumBytes: 8) }
        let requests = TransportURLProtocol.state.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "api.github.com")
    }

    @Test func URLSessionRejectsUnsafeRequestsWithoutStartingThem() async throws {
        let client = URLSessionSourceHTTPClient(protocolClasses: [TransportURLProtocol.self])
        for url in ["http://api.github.com/a", "https://evil.example/a", "https://user@api.github.com/a", "https://api.github.com:444/a"] {
            await #expect(throws: SourceTransportError.unsafePath) {
                try await client.get(URLRequest(url: URL(string: url)!), maximumBytes: 8)
            }
        }
        var write = URLRequest(url: URL(string: "https://api.github.com/test")!)
        write.httpMethod = "POST"
        await #expect(throws: SourceTransportError.unsafePath) { try await client.get(write, maximumBytes: 8) }
    }

    @Test func URLSessionPreservesErrorStatusWithoutBufferingErrorBody() async throws {
        let client = URLSessionSourceHTTPClient(protocolClasses: [TransportURLProtocol.self])
        TransportURLProtocol.state.set(.response(status: 404, headers: ["Content-Length": "1000"], chunks: [Data(repeating: 0, count: 1000)]))
        let response = try await client.get(URLRequest(url: URL(string: "https://api.github.com/test")!), maximumBytes: 0)
        #expect(response.statusCode == 404)
        #expect(response.data.isEmpty)
    }

    @Test func URLSessionCancellationCompletes() async throws {
        let client = URLSessionSourceHTTPClient(protocolClasses: [TransportURLProtocol.self])
        TransportURLProtocol.state.set(.pending)
        let task = Task { try await client.get(URLRequest(url: URL(string: "https://api.github.com/test")!), maximumBytes: 8) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func transport(_ http: MockSourceHTTPClient) -> SourceTransport {
        SourceTransport(httpClient: http, tokenProvider: MockToken(value: "mock-token"))
    }

    private func localTransport() -> SourceTransport {
        SourceTransport(httpClient: MockSourceHTTPClient([]), tokenProvider: NoToken())
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func blobPath(_ hash: String) -> String { "blobs/sha256/\(hash.prefix(2))/\(hash)" }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TaskHubTransportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

private struct MockToken: SourceTokenProvider {
    let value: String
    func token() async throws -> String { value }
}

private struct NoToken: SourceTokenProvider {
    func token() async throws -> String { throw SourceTransportError.authenticationUnavailable }
}

private struct MockHTTPReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var data = Data()
    var url: URL?
    var error: URLError?

    static let privateRepository = json(#"{"id":42,"private":true}"#)
    static func json(_ value: String) -> Self { Self(data: Data(value.utf8)) }
    static func sha(_ value: String, etag: String? = nil) -> Self {
        Self(headers: etag.map { ["ETag": $0] } ?? [:], data: Data(value.utf8))
    }
}

private actor MockSourceHTTPClient: SourceHTTPClient {
    private var replies: [MockHTTPReply]
    private(set) var requests: [URLRequest] = []
    private(set) var limits: [Int] = []

    init(_ replies: [MockHTTPReply]) { self.replies = replies }

    func get(_ request: URLRequest, maximumBytes: Int) async throws -> SourceHTTPResponse {
        requests.append(request)
        limits.append(maximumBytes)
        guard !replies.isEmpty else { throw SourceTransportError.invalidResponse }
        let reply = replies.removeFirst()
        if let error = reply.error { throw error }
        return SourceHTTPResponse(url: reply.url ?? request.url!, statusCode: reply.status, headers: reply.headers, data: reply.data)
    }
}

private final class TransportURLProtocol: URLProtocol, @unchecked Sendable {
    enum Scenario: Sendable {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(URL)
        case pending
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var scenario = Scenario.pending
        private var recordedRequests: [URLRequest] = []

        var requests: [URLRequest] { lock.withLock { recordedRequests } }
        func set(_ scenario: Scenario) { lock.withLock { self.scenario = scenario; recordedRequests = [] } }
        func record(_ request: URLRequest) -> Scenario {
            lock.withLock { recordedRequests.append(request); return scenario }
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.state.record(request) {
        case .response(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let url):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        case .pending:
            break
        }
    }

    override func stopLoading() {}
}
