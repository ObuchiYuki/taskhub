//
//  AuditHistory.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import CryptoKit
import Foundation
import Observation

public struct AuditContext: Sendable {
    public let configuration: SourceConfiguration
    public let revision: String
    public let repositoryID: Int?
    public let snapshot: Snapshot
    public let transport: any SnapshotTransport
}

public struct AuditEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    public let actor: String
    public let timestamp: Date
    public let type: String
    public let entityID: String
    public let payload: String
    public var title: String {
        switch type {
        case "lane.created": "レーン登録"
        case "lane.updated": "レーン更新"
        case "task.created": "タスク登録"
        case "task.updated": "タスク更新"
        case "task.completed": "完了・証拠確認"
        case "task.reopened": "タスク再開"
        case "decision.created": "裁定登録"
        case "decision.answered": "裁定回答"
        case "decision.applied": "裁定反映"
        case "comment.added": "追記追加"
        case "attachment.added": "添付追加"
        default: type
        }
    }
}

public enum AuditError: LocalizedError {
    case integrity(Int)
    public var errorDescription: String? {
        switch self {
        case .integrity(let seq): "変更履歴 \(seq) の形式またはSHA-256が一致しません。取得済み履歴を保持して読み込みを停止しました。"
        }
    }
}

@MainActor @Observable
public final class AuditHistory {
    public private(set) var entries: [AuditEntry] = []
    public private(set) var nextSequence: Int
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private var expectedHash: String?
    @ObservationIgnored private let context: AuditContext

    public init(context: AuditContext) {
        self.context = context
        nextSequence = context.snapshot.lastEventSeq
        expectedHash = context.snapshot.lastEventHash
    }

    public func loadMore(count: Int = 25) async {
        guard !isLoading, nextSequence > 0 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            for _ in 0..<min(max(count, 1), 50) {
                guard nextSequence > 0 else { break }
                try Task.checkCancellation()
                let data = try await context.transport.fetchEvent(seq: nextSequence, configuration: context.configuration,
                    revision: context.revision, repositoryID: context.repositoryID)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count <= 1_048_576, hash == expectedHash,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["schema_version"] as? Int, version == 1,
                      let seq = json["seq"] as? Int, seq == nextSequence,
                      let actor = json["actor"] as? String, !actor.isEmpty,
                      let time = json["occurred_at"] as? String,
                      let timestamp = ISO8601DateFormatter().date(from: time),
                      let type = json["type"] as? String,
                      let payload = json["payload"] as? [String: Any],
                      let entityID = payload["id"] as? String else { throw AuditError.integrity(nextSequence) }
                let previous = json["prev_hash"] as? String
                guard (seq == 1 && json["prev_hash"] is NSNull) ||
                        (seq > 1 && previous?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil) else {
                    throw AuditError.integrity(seq)
                }
                let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                entries.append(AuditEntry(id: seq, actor: actor, timestamp: timestamp, type: type,
                    entityID: entityID, payload: String(decoding: payloadData, as: UTF8.self)))
                nextSequence -= 1
                expectedHash = previous
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
