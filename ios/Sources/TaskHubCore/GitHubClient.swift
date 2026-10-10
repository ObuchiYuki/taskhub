//
//  GitHubClient.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import CryptoKit
import Foundation

public struct RepositoryConfiguration: Codable, Equatable, Sendable {
    public var owner: String
    public var repository: String
    public var branch: String

    public init(owner: String, repository: String, branch: String) {
        self.owner = owner
        self.repository = repository
        self.branch = branch
    }

    public var identity: String {
        "github.com/\(owner.lowercased())/\(repository.lowercased())@\(branch)"
    }

    public func validated() throws {
        let ownerCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let repositoryCharacters = ownerCharacters.union(CharacterSet(charactersIn: "_."))
        guard (1...39).contains(owner.utf8.count),
              owner.unicodeScalars.allSatisfy(ownerCharacters.contains),
              !owner.hasPrefix("-"), !owner.hasSuffix("-"),
              (1...100).contains(repository.utf8.count),
              repository.unicodeScalars.allSatisfy(repositoryCharacters.contains),
              !repository.hasPrefix("-"), repository != ".", repository != "..",
              (1...255).contains(branch.utf8.count),
              !branch.hasPrefix("-"), !branch.hasPrefix("/"), !branch.hasSuffix("/"),
              !branch.hasSuffix("."), branch != "@",
              !branch.contains(".."), !branch.contains("//"), !branch.contains("@{"),
              !branch.unicodeScalars.contains(where: {
                  $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0)
              }),
              branch.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") && !$0.hasSuffix(".lock") })
        else { throw GitHubSyncError.invalidConfiguration }
    }
}

public enum GitHubSyncError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidToken
    case unauthorized
    case forbidden
    case rateLimited
    case notFound
    case publicRepository
    case repositoryChanged
    case configurationChanged
    case redirectRejected
    case invalidResponse
    case responseTooLarge
    case invalidSnapshot
    case historyRewritten
    case attachmentUnavailable
    case invalidAttachment
    case network

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "GitHubの所有者・リポジトリ名・ブランチ名を確認してください。URLは指定できません。"
        case .invalidToken: "GitHubの読み取り用トークンを設定してください。"
        case .unauthorized: "GitHub認証に失敗しました。トークンの有効期限を確認してください。"
        case .forbidden: "GitHubへのアクセスが拒否されました。対象リポジトリの読み取り権限を確認してください。"
        case .rateLimited: "GitHubのアクセス制限に達しました。時間を置いて再試行してください。"
        case .notFound: "リポジトリ・ブランチ・ファイルが見つかりません。設定とトークンの読み取り権限を確認してください。"
        case .publicRepository: "公開リポジトリは同期できません。専用のprivateリポジトリを指定してください。"
        case .repositoryChanged: "リポジトリIDが変わったため取得を中止しました。保存済みデータは維持されます。"
        case .configurationChanged: "保存済みデータとリポジトリまたはブランチが異なります。取得を中止しました。"
        case .redirectRejected: "認証情報の転送を防ぐため、GitHubのリダイレクトを拒否しました。"
        case .invalidResponse: "GitHubから不正な応答を受信しました。保存済みデータは維持されます。"
        case .responseTooLarge: "取得データが許容サイズを超えたため中止しました。上限は32MiBです。"
        case .invalidSnapshot: "スナップショットの形式・ストアID・履歴の整合性を確認できません。保存済みデータは維持されます。"
        case .historyRewritten: "Git履歴の巻戻しまたは書換えを検出しました。保存済みデータは維持されます。"
        case .attachmentUnavailable: "添付の取得には同期済みのprivateリポジトリとコミット情報が必要です。"
        case .invalidAttachment: "添付のパス・サイズ・SHA256が一致しません。添付を開かずに取得を中止しました。"
        case .network: "GitHubに接続できません。通信状態を確認してください。"
        }
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    /// Implementations must reject redirects and stop receiving at the supplied byte limit.
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> HTTPResponse
}

public struct GitHubClient: Sendable {
    public static let maximumResponseBytes = 32 * 1024 * 1024
    private let transport: any HTTPTransport

    public init() {
        transport = GitHubHTTPTransport()
    }

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func synchronize(
        configuration: RepositoryConfiguration,
        token: String,
        previous: CachedSnapshot?
    ) async throws -> CachedSnapshot {
        try configuration.validated()
        try Self.validateToken(token)
        if let previous {
            try previous.validateEnvelope()
            if let oldConfiguration = previous.configuration,
               oldConfiguration.identity != configuration.identity {
                throw GitHubSyncError.configurationChanged
            }
        }

        let repositoryID = try await privateRepositoryID(configuration: configuration, token: token)
        if let pinnedID = previous?.repositoryID, pinnedID != repositoryID {
            throw GitHubSyncError.repositoryChanged
        }
        let pinnedPrevious = previous.flatMap { cached -> CachedSnapshot? in
            guard cached.configuration?.identity == configuration.identity,
                  cached.repositoryID == repositoryID, cached.commitSHA != nil else { return nil }
            return cached
        }
        let conditionalETag = pinnedPrevious?.etag
        // The heads/ prefix prevents a same-named tag or hexadecimal branch from resolving as a commit.
        let commitResponse = try await get(
            configuration: configuration, path: ["commits", "heads/\(configuration.branch)"],
            token: token, etag: conditionalETag
        )
        if commitResponse.statusCode == 304 {
            guard conditionalETag != nil, let cached = pinnedPrevious else {
                throw GitHubSyncError.invalidResponse
            }
            return CachedSnapshot(
                configuration: configuration, repositoryID: repositoryID,
                commitSHA: cached.commitSHA, etag: cached.etag, checkedAt: Date(), snapshot: cached.snapshot
            )
        }
        try Self.requireSuccess(commitResponse)
        let commit: Commit = try Self.decodeResponse(commitResponse)
        guard Self.isCommitSHA(commit.sha) else { throw GitHubSyncError.invalidResponse }

        let snapshotResponse = try await get(
            configuration: configuration, path: ["contents", "snapshot.json"],
            token: token, query: [URLQueryItem(name: "ref", value: commit.sha)], raw: true
        )
        try Self.requireSuccess(snapshotResponse)
        let snapshot: Snapshot
        do {
            snapshot = try Snapshot.decode(snapshotResponse.body, previous: previous?.snapshot)
        } catch {
            throw GitHubSyncError.invalidSnapshot
        }

        if let oldSHA = pinnedPrevious?.commitSHA, oldSHA != commit.sha {
            let comparisonResponse = try await get(
                configuration: configuration, path: ["compare", "\(oldSHA)...\(commit.sha)"],
                token: token, query: [URLQueryItem(name: "per_page", value: "1")]
            )
            try Self.requireSuccess(comparisonResponse)
            let comparison: Comparison = try Self.decodeResponse(comparisonResponse)
            guard comparison.status == "ahead", comparison.mergeBaseCommit.sha == oldSHA else {
                throw GitHubSyncError.historyRewritten
            }
        }

        let newETag = commitResponse.header("ETag").flatMap { Self.isETag($0) ? $0 : nil }
        return CachedSnapshot(
            configuration: configuration, repositoryID: repositoryID,
            commitSHA: commit.sha, etag: newETag, checkedAt: Date(), snapshot: snapshot
        )
    }

    public func attachment(_ attachment: AttachmentRecord, from cached: CachedSnapshot, token: String) async throws -> Data {
        try cached.validateEnvelope()
        try Self.validateToken(token)
        guard let configuration = cached.configuration,
              let repositoryID = cached.repositoryID, let commitSHA = cached.commitSHA else {
            throw GitHubSyncError.attachmentUnavailable
        }
        let hash = attachment.sha256
        let path = "blobs/sha256/\(hash.prefix(2))/\(hash)"
        guard Self.isHash(hash, length: 64), attachment.blobPath == path,
              (0...Self.maximumResponseBytes).contains(attachment.sizeBytes),
              cached.snapshot.attachments.contains(attachment) else {
            throw GitHubSyncError.invalidAttachment
        }
        let currentID = try await privateRepositoryID(configuration: configuration, token: token)
        guard currentID == repositoryID else { throw GitHubSyncError.repositoryChanged }
        let response = try await get(
            configuration: configuration, path: ["contents", "blobs", "sha256", String(hash.prefix(2)), hash],
            token: token, query: [URLQueryItem(name: "ref", value: commitSHA)], raw: true
        )
        try Self.requireSuccess(response)
        guard response.body.count == attachment.sizeBytes,
              SHA256.hash(data: response.body).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw GitHubSyncError.invalidAttachment
        }
        return response.body
    }

    private func privateRepositoryID(configuration: RepositoryConfiguration, token: String) async throws -> Int {
        let response = try await get(configuration: configuration, path: [], token: token)
        try Self.requireSuccess(response)
        let repository: Repository = try Self.decodeResponse(response)
        guard repository.isPrivate else { throw GitHubSyncError.publicRepository }
        guard repository.id > 0 else { throw GitHubSyncError.invalidResponse }
        return repository.id
    }

    private func get(
        configuration: RepositoryConfiguration,
        path: [String],
        token: String,
        query: [URLQueryItem] = [],
        raw: Bool = false,
        etag: String? = nil
    ) async throws -> HTTPResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let segments = ["repos", configuration.owner, configuration.repository] + path
        components.percentEncodedPath = "/" + segments.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitHubSyncError.invalidConfiguration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TaskHub-iOS", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request, maximumBytes: Self.maximumResponseBytes)
            try Task.checkCancellation()
            guard response.body.count <= Self.maximumResponseBytes else { throw GitHubSyncError.responseTooLarge }
            if (300...399).contains(response.statusCode), response.statusCode != 304 {
                throw GitHubSyncError.redirectRejected
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitHubSyncError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GitHubSyncError.network
        }
    }

    private static func requireSuccess(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw GitHubSyncError.unauthorized
        case 403:
            if response.header("X-RateLimit-Remaining") == "0" || response.header("Retry-After") != nil {
                throw GitHubSyncError.rateLimited
            }
            throw GitHubSyncError.forbidden
        case 404: throw GitHubSyncError.notFound
        case 429: throw GitHubSyncError.rateLimited
        case 300...399 where response.statusCode != 304: throw GitHubSyncError.redirectRejected
        default: throw GitHubSyncError.invalidResponse
        }
    }

    private static func decodeResponse<Value: Decodable>(_ response: HTTPResponse) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: response.body) }
        catch { throw GitHubSyncError.invalidResponse }
    }

    static func validateToken(_ token: String) throws {
        guard (1...4096).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw GitHubSyncError.invalidToken
        }
    }

    static func isCommitSHA(_ value: String) -> Bool { isHash(value, length: 40) }

    private static func isHash(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isETag(_ value: String) -> Bool {
        let tag = value.hasPrefix("W/") ? String(value.dropFirst(2)) : value
        return value.utf8.count <= 1024 && tag.count >= 2 && tag.hasPrefix("\"") && tag.hasSuffix("\"")
            && tag.dropFirst().dropLast().utf8.allSatisfy { $0 == 33 || (35...126).contains($0) }
    }

    private struct Repository: Decodable {
        let id: Int
        let isPrivate: Bool
        enum CodingKeys: String, CodingKey { case id; case isPrivate = "private" }
    }

    private struct Commit: Decodable { let sha: String }

    private struct Comparison: Decodable {
        let status: String
        let mergeBaseCommit: Commit
        enum CodingKeys: String, CodingKey { case status; case mergeBaseCommit = "merge_base_commit" }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct GitHubHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> HTTPResponse {
        guard request.httpMethod == "GET", let url = request.url,
              url.scheme == "https", url.host == "api.github.com", url.port == nil,
              url.user == nil, url.password == nil else { throw GitHubSyncError.invalidConfiguration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw GitHubSyncError.invalidResponse
        }
        if (300...399).contains(http.statusCode), http.statusCode != 304 {
            throw GitHubSyncError.redirectRejected
        }
        guard maximumBytes >= 0, response.expectedContentLength <= Int64(maximumBytes) else {
            throw GitHubSyncError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw GitHubSyncError.responseTooLarge }
            data.append(byte)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String { headers[name] = String(describing: value) }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
