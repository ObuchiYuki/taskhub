//
//  SourceTransport.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import CryptoKit
import Darwin
import Foundation

public enum SourceConfiguration: Codable, Hashable, Sendable {
    case local(directory: String)
    case github(repository: String, branch: String)

    public var displayName: String {
        switch self {
        case .local(let directory): directory
        case .github(let repository, let branch): "\(repository) [\(branch)]"
        }
    }

    @discardableResult
    public func validated() throws -> SourceConfiguration {
        switch self {
        case .local(let directory):
            guard directory.hasPrefix("/"), directory.utf8.count <= 4096,
                  !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !directory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw SourceTransportError.invalidConfiguration("ローカル保存先は安全な絶対パスで指定してください。")
            }
        case .github(let repository, let branch):
            let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  Self.matches(String(parts[0]), "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"),
                  Self.matches(String(parts[1]), "^[A-Za-z0-9_.-]{1,100}$"),
                  parts[1] != ".", parts[1] != "..", !parts[1].hasPrefix("-") else {
                throw SourceTransportError.invalidConfiguration("GitHub.com の OWNER/NAME を指定してください。URL は指定できません。")
            }
            let components = branch.split(separator: "/", omittingEmptySubsequences: false)
            guard !branch.isEmpty, branch.utf8.count <= 255,
                  Self.matches(branch, "^[A-Za-z0-9_./-]+$"), !branch.contains(".."),
                  components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("-")
                      && !$0.hasSuffix(".") && !$0.hasSuffix(".lock") }) else {
                throw SourceTransportError.invalidConfiguration("安全な Git ブランチ名を指定してください。")
            }
        }
        return self
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
}

public struct SourceFetch: Equatable, Sendable {
    public let data: Data?
    public let revision: String
    public let etag: String?
    public let repositoryID: Int?

    public init(data: Data?, revision: String, etag: String?, repositoryID: Int?) {
        self.data = data
        self.revision = revision
        self.etag = etag
        self.repositoryID = repositoryID
    }
}

public protocol SnapshotTransport: Sendable {
    func fetchSnapshot(configuration: SourceConfiguration, previousRevision: String?, etag: String?,
                       repositoryID: Int?) async throws -> SourceFetch
    func fetchBlob(path: String, sha256: String, size: Int, configuration: SourceConfiguration,
                   revision: String, repositoryID: Int?) async throws -> Data
    func fetchEvent(seq: Int, configuration: SourceConfiguration, revision: String,
                    repositoryID: Int?) async throws -> Data
}

public extension SnapshotTransport {
    func fetchEvent(seq: Int, configuration: SourceConfiguration, revision: String,
                    repositoryID: Int?) async throws -> Data {
        throw SourceTransportError.unsupported
    }
}

public enum SourceTransportError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case authenticationUnavailable
    case privateRepositoryRequired
    case repositoryChanged
    case invalidRevision
    case invalidResponse
    case redirectRejected
    case httpStatus(Int, retryAfter: TimeInterval?)
    case timedOut
    case networkUnavailable
    case tooLarge(limit: Int)
    case unsafePath
    case localReadFailed
    case localFileChanged
    case blobIntegrityMismatch
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .authenticationUnavailable:
            "既存の GitHub CLI 認証を読み取れません。インストール済み gh と github.com の既存認証を確認してください。"
        case .privateRepositoryRequired:
            "private リポジトリであることを確認できないため、取得を停止しました。"
        case .repositoryChanged: "リポジトリ ID が保存済みの値と異なります。取得を停止しました。"
        case .invalidRevision: "取得元の commit SHA またはローカル内容ハッシュが不正です。"
        case .invalidResponse: "取得元の応答が不正です。"
        case .redirectRejected: "認証情報保護のため HTTP リダイレクトを拒否しました。"
        case .httpStatus(let status, _):
            switch status {
            case 401: "GitHub 認証が無効です (HTTP 401)。既存認証を確認してください。"
            case 403, 429: "GitHub のアクセス制限または取得回数制限です (HTTP \(status))。時間を置いて再取得してください。"
            case 404: "GitHub リポジトリ、ブランチ、またはファイルが見つかりません (HTTP 404)。読み取り権限も確認してください。"
            default: "GitHub から取得できませんでした (HTTP \(status))。"
            }
        case .timedOut: "取得処理がタイムアウトしました。"
        case .networkUnavailable: "GitHub に接続できません。ネットワークを確認してください。"
        case .tooLarge(let limit): "ファイルが取得上限 \(limit) バイトを超えています。"
        case .unsafePath: "安全でないパス、シンボリックリンク、または通常ファイル以外を拒否しました。"
        case .localReadFailed: "ローカルファイルを読み取れません。保存先とアクセス権を確認してください。"
        case .localFileChanged: "読み取り中にローカルファイルが変更されました。再取得してください。"
        case .blobIntegrityMismatch: "添付ファイルのサイズまたは SHA-256 が一致しません。"
        case .unsupported: "この取得元は監査イベントの読み取りに対応していません。"
        }
    }
}

public struct SourceHTTPResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(url: URL, statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }

    public func header(_ name: String) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
}

public protocol SourceHTTPClient: Sendable {
    /// Implementations must enforce the byte limit during receipt, not after buffering the response.
    func get(_ request: URLRequest, maximumBytes: Int) async throws -> SourceHTTPResponse
}

public protocol SourceTokenProvider: Sendable {
    func token() async throws -> String
}

public struct SourceTransport: SnapshotTransport {
    public static let maximumFileBytes = 32 * 1024 * 1024
    public static let maximumEventBytes = 1024 * 1024
    private let httpClient: any SourceHTTPClient
    private let tokenProvider: any SourceTokenProvider

    public init(httpClient: any SourceHTTPClient = URLSessionSourceHTTPClient(),
                tokenProvider: any SourceTokenProvider = GitHubCLITokenProvider()) {
        self.httpClient = httpClient
        self.tokenProvider = tokenProvider
    }

    public func fetchSnapshot(configuration: SourceConfiguration, previousRevision: String? = nil,
                              etag: String? = nil, repositoryID: Int? = nil) async throws -> SourceFetch {
        try configuration.validated()
        try Task.checkCancellation()
        switch configuration {
        case .local(let directory):
            if let previousRevision { try Self.validateHash(previousRevision, length: 64) }
            let data = try Self.readLocal(directory: directory, path: "snapshot.json", limit: Self.maximumFileBytes)
            let revision = Self.digest(data)
            return SourceFetch(data: revision == previousRevision ? nil : data, revision: revision,
                               etag: nil, repositoryID: nil)
        case .github(let repository, let branch):
            if let previousRevision { try Self.validateHash(previousRevision, length: 40) }
            try Self.validateETag(etag)
            let token = try await credential()
            let id = try await checkRepository(repository, pinnedID: repositoryID, token: token)
            let commitURL = try Self.apiURL(repository: repository, components: ["commits", branch])
            // The SHA media type avoids downloading commit patches just to identify the tip.
            let response = try await get(commitURL, token: token, accept: "application/vnd.github.sha",
                                         etag: previousRevision == nil ? nil : etag, limit: Self.maximumEventBytes)
            let responseETag = response.header("ETag")
            try Self.validateETag(responseETag)
            if response.statusCode == 304 {
                guard let previousRevision, etag != nil else { throw SourceTransportError.invalidResponse }
                return SourceFetch(data: nil, revision: previousRevision, etag: responseETag ?? etag, repositoryID: id)
            }
            try Self.requireOK(response)
            guard let text = String(data: response.data, encoding: .utf8) else {
                throw SourceTransportError.invalidRevision
            }
            let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateHash(revision, length: 40)
            if revision == previousRevision {
                return SourceFetch(data: nil, revision: revision, etag: responseETag, repositoryID: id)
            }
            let data = try await contents(repository: repository, path: "snapshot.json", revision: revision,
                                          token: token, limit: Self.maximumFileBytes)
            return SourceFetch(data: data, revision: revision, etag: responseETag, repositoryID: id)
        }
    }

    public func fetchBlob(path: String, sha256: String, size: Int, configuration: SourceConfiguration,
                          revision: String, repositoryID: Int? = nil) async throws -> Data {
        try configuration.validated()
        try Self.validateHash(sha256, length: 64)
        guard path == "blobs/sha256/\(sha256.prefix(2))/\(sha256)", size >= 0 else {
            throw SourceTransportError.unsafePath
        }
        guard size <= Self.maximumFileBytes else { throw SourceTransportError.tooLarge(limit: Self.maximumFileBytes) }
        let data = try await fetchFile(path: path, configuration: configuration, revision: revision,
                                       repositoryID: repositoryID, limit: size)
        guard data.count == size, Self.digest(data) == sha256 else {
            throw SourceTransportError.blobIntegrityMismatch
        }
        return data
    }

    public func fetchEvent(seq: Int, configuration: SourceConfiguration, revision: String,
                           repositoryID: Int? = nil) async throws -> Data {
        guard seq > 0 else { throw SourceTransportError.unsafePath }
        try configuration.validated()
        let number = String(seq)
        let path = "events/" + String(repeating: "0", count: 20 - number.count) + number + ".json"
        return try await fetchFile(path: path, configuration: configuration, revision: revision,
                                   repositoryID: repositoryID, limit: Self.maximumEventBytes)
    }

    private func fetchFile(path: String, configuration: SourceConfiguration, revision: String,
                           repositoryID: Int?, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        switch configuration {
        case .local(let directory):
            try Self.validateHash(revision, length: 64)
            return try Self.readLocal(directory: directory, path: path, limit: limit)
        case .github(let repository, _):
            try Self.validateHash(revision, length: 40)
            let token = try await credential()
            _ = try await checkRepository(repository, pinnedID: repositoryID, token: token)
            return try await contents(repository: repository, path: path, revision: revision, token: token, limit: limit)
        }
    }

    private func credential() async throws -> String {
        let token: String
        do { token = try await tokenProvider.token() }
        catch is CancellationError { throw CancellationError() }
        catch let error as SourceTransportError { throw error }
        catch { throw SourceTransportError.authenticationUnavailable }
        guard !token.isEmpty, token.utf8.count <= 16 * 1024,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw SourceTransportError.authenticationUnavailable
        }
        return token
    }

    private func checkRepository(_ repository: String, pinnedID: Int?, token: String) async throws -> Int {
        if let pinnedID, pinnedID <= 0 { throw SourceTransportError.repositoryChanged }
        let url = try Self.apiURL(repository: repository, components: [])
        let response = try await get(url, token: token, limit: Self.maximumEventBytes)
        try Self.requireOK(response)
        struct Repository: Decodable {
            let id: Int?
            let isPrivate: Bool?
            enum CodingKeys: String, CodingKey { case id; case isPrivate = "private" }
        }
        guard let metadata = try? JSONDecoder().decode(Repository.self, from: response.data),
              metadata.isPrivate == true else { throw SourceTransportError.privateRepositoryRequired }
        guard let id = metadata.id, id > 0 else { throw SourceTransportError.invalidResponse }
        if let pinnedID, id != pinnedID { throw SourceTransportError.repositoryChanged }
        return id
    }

    private func contents(repository: String, path: String, revision: String, token: String, limit: Int) async throws -> Data {
        let url = try Self.apiURL(repository: repository, components: ["contents"] + path.components(separatedBy: "/"),
                                  revision: revision)
        let response = try await get(url, token: token, accept: "application/vnd.github.raw+json", limit: limit)
        try Self.requireOK(response)
        return response.data
    }

    private func get(_ url: URL, token: String, accept: String = "application/vnd.github+json",
                     etag: String? = nil, limit: Int) async throws -> SourceHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TaskHubMac", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let response: SourceHTTPResponse
        do { response = try await httpClient.get(request, maximumBytes: limit) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SourceTransportError { throw error }
        catch let error as URLError where error.code == .timedOut { throw SourceTransportError.timedOut }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw SourceTransportError.networkUnavailable }
        guard Self.isAPIURL(response.url), response.url == url else { throw SourceTransportError.redirectRejected }
        if (300..<400).contains(response.statusCode), response.statusCode != 304 {
            throw SourceTransportError.redirectRejected
        }
        if response.statusCode != 304 { try Self.requireOK(response) }
        guard response.data.count <= limit else { throw SourceTransportError.tooLarge(limit: limit) }
        return response
    }

    private static func apiURL(repository: String, components: [String], revision: String? = nil) throws -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let segments = ["repos"] + repository.components(separatedBy: "/") + components
        var url = URLComponents()
        url.scheme = "https"
        url.host = "api.github.com"
        url.percentEncodedPath = "/" + segments.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "/")
        if let revision { url.queryItems = [URLQueryItem(name: "ref", value: revision)] }
        guard let result = url.url, isAPIURL(result) else { throw SourceTransportError.unsafePath }
        return result
    }

    fileprivate static func isAPIURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "api.github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.fragment == nil
    }

    private static func requireOK(_ response: SourceHTTPResponse) throws {
        guard response.statusCode == 200 else {
            let retry = response.header("Retry-After").flatMap(TimeInterval.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            throw SourceTransportError.httpStatus(response.statusCode, retryAfter: retry)
        }
    }

    private static func validateETag(_ etag: String?) throws {
        if let etag {
            guard !etag.isEmpty, etag.utf8.count <= 1024,
                  etag.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw SourceTransportError.invalidResponse }
        }
    }

    private static func validateHash(_ hash: String, length: Int) throws {
        guard hash.utf8.count == length,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SourceTransportError.invalidRevision
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readLocal(directory: String, path: String, limit: Int) throws -> Data {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SourceTransportError.unsafePath
        }
        var root = directory
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        var parent = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw localError() }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw localError() }
            close(parent)
            parent = next
        }
        // O_NONBLOCK prevents a substituted FIFO from blocking before fstat rejects it.
        let file = openat(parent, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw localError() }
        defer { close(file) }
        var before = stat()
        guard fstat(file, &before) == 0 else { throw SourceTransportError.localReadFailed }
        guard before.st_mode & S_IFMT == S_IFREG else { throw SourceTransportError.unsafePath }
        guard before.st_size >= 0, before.st_size <= limit else { throw SourceTransportError.tooLarge(limit: limit) }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SourceTransportError.localReadFailed
            }
            if count == 0 { break }
            guard count <= limit - data.count else { throw SourceTransportError.tooLarge(limit: limit) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(file, &after) == 0 else { throw SourceTransportError.localReadFailed }
        guard data.count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SourceTransportError.localFileChanged
        }
        return data
    }

    private static func localError() -> SourceTransportError {
        errno == ELOOP || errno == ENOTDIR ? .unsafePath : .localReadFailed
    }
}

public struct URLSessionSourceHTTPClient: SourceHTTPClient {
    private let protocolClasses: [AnyClass]?

    public init() { protocolClasses = nil }

    init(protocolClasses: [AnyClass]) { self.protocolClasses = protocolClasses }

    public func get(_ request: URLRequest, maximumBytes: Int) async throws -> SourceHTTPResponse {
        guard let url = request.url, SourceTransport.isAPIURL(url), request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil, maximumBytes >= 0,
              maximumBytes <= SourceTransport.maximumFileBytes else { throw SourceTransportError.unsafePath }
        let transfer = SourceHTTPTransfer(request: request, maximumBytes: maximumBytes, protocolClasses: protocolClasses)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: {
            transfer.cancel()
        }
    }
}

// URLSession delegates and cancellation run on different queues; the lock owns all mutable state.
final class SourceHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let maximumBytes: Int
    private let protocolClasses: [AnyClass]?
    private var continuation: CheckedContinuation<SourceHTTPResponse, any Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false

    init(request: URLRequest, maximumBytes: Int, protocolClasses: [AnyClass]? = nil) {
        self.request = request
        self.maximumBytes = maximumBytes
        self.protocolClasses = protocolClasses
    }

    func start(_ continuation: CheckedContinuation<SourceHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(CancellationError())) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(SourceTransportError.redirectRejected))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let url = response.url,
              SourceTransport.isAPIURL(url), url == request.url else {
            completionHandler(.cancel)
            finish(.failure(SourceTransportError.redirectRejected))
            return
        }
        if response.statusCode != 200 {
            completionHandler(.cancel)
            finish(.success(Self.value(response, data: Data())))
            return
        }
        guard response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(SourceTransportError.tooLarge(limit: maximumBytes)))
            return
        }
        lock.lock()
        self.response = response
        let active = !finished
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock()
            finish(.failure(SourceTransportError.tooLarge(limit: maximumBytes)))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = body
        lock.unlock()
        guard let response else {
            finish(.failure(SourceTransportError.invalidResponse))
            return
        }
        finish(.success(Self.value(response, data: data)))
    }

    private static func value(_ response: HTTPURLResponse, data: Data) -> SourceHTTPResponse {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return SourceHTTPResponse(url: response.url!, statusCode: response.statusCode, headers: headers, data: data)
    }

    private func finish(_ result: Result<SourceHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        body = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

public struct GitHubCLITokenProvider: SourceTokenProvider {
    public init() {}

    public func token() async throws -> String {
        let operation = GitHubTokenOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try operation.run()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class GitHubTokenOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    func run() throws -> String {
        try checkCancellation()
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SourceTransportError.authenticationUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
                               "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw SourceTransportError.authenticationUnavailable }
        do { try process.run() }
        catch { throw SourceTransportError.authenticationUnavailable }
        output.fileHandleForWriting.closeFile()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            output.fileHandleForReading.closeFile()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            try checkCancellation()
            guard ContinuousClock.now < deadline else { throw SourceTransportError.timedOut }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard count <= 16 * 1024 - data.count else { throw SourceTransportError.authenticationUnavailable }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.01)
            } else if errno == EAGAIN || errno == EINTR {
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                throw SourceTransportError.authenticationUnavailable
            }
        }
        guard process.terminationStatus == 0, let token = String(data: data, encoding: .utf8) else {
            throw SourceTransportError.authenticationUnavailable
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw SourceTransportError.authenticationUnavailable
        }
        return trimmed
    }

    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
