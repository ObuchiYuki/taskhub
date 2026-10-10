//
//  UITestTransport.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

#if DEBUG
import Foundation
import TaskHubCore

actor UITestTransport: HTTPTransport {
    private var generation = 0

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> HTTPResponse {
        guard let url = request.url else { throw GitHubSyncError.invalidResponse }
        let path = url.path
        if path == "/repos/ui-fixture/taskhub" {
            return HTTPResponse(statusCode: 200, body: Data("{\"id\":777,\"private\":true}".utf8))
        }
        if path.contains("/commits/") {
            generation += 1
            if generation >= 3 { throw URLError(.notConnectedToInternet) }
            let sha = String(repeating: generation == 1 ? "a" : "b", count: 40)
            return HTTPResponse(statusCode: 200, headers: ["ETag": "\"fixture-\(generation)\""], body: Data("{\"sha\":\"\(sha)\"}".utf8))
        }
        if path.contains("/compare/") {
            let sha = String(repeating: "a", count: 40)
            return HTTPResponse(statusCode: 200, body: Data("{\"status\":\"ahead\",\"merge_base_commit\":{\"sha\":\"\(sha)\"}}".utf8))
        }
        if path.hasSuffix("/snapshot.json") {
            guard let source = Bundle.main.url(forResource: "demo-snapshot", withExtension: "json") else {
                throw GitHubSyncError.invalidSnapshot
            }
            let original = try Data(contentsOf: source)
            if generation == 1 { return HTTPResponse(statusCode: 200, body: original) }
            var snapshot = try Snapshot.decode(original)
            guard let index = snapshot.decisions.firstIndex(where: { $0.title == "同期先リポジトリを選んでほしい" }) else {
                throw GitHubSyncError.invalidSnapshot
            }
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            snapshot.lastEventSeq += 1
            snapshot.lastEventHash = String(repeating: "b", count: 64)
            snapshot.generatedAt = now
            snapshot.decisions[index].status = .answered
            snapshot.decisions[index].answer = Answer(text: "専用privateリポジトリを使用", respondent: "fixture-user", recordedBy: "fixture-agent", recordedAt: now)
            snapshot.decisions[index].updatedAt = now
            snapshot.decisions[index].updatedBy = "fixture-agent"
            snapshot.decisions[index].revision = snapshot.lastEventSeq
            return HTTPResponse(statusCode: 200, body: try Snapshot.makeEncoder().encode(snapshot))
        }
        if path.contains("/contents/blobs/") { return HTTPResponse(statusCode: 200) }
        throw GitHubSyncError.notFound
    }
}
#endif
