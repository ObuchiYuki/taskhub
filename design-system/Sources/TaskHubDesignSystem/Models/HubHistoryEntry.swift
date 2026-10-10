//
//  HubHistoryEntry.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

/// 追記履歴の読み取り専用スナップショット。保存や並べ替えは行わない。
public struct HubHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// 操作したユーザーまたはエージェントの表示名。
    public let actor: String
    public let timestamp: Date
    public let message: String
    public let evidence: String?
    public let attachments: [HubAttachment]

    /// 添付の表示順は渡された配列の順序を維持する。
    public init(
        id: String,
        actor: String,
        timestamp: Date,
        message: String,
        evidence: String? = nil,
        attachments: [HubAttachment] = []
    ) {
        self.id = id
        self.actor = actor
        self.timestamp = timestamp
        self.message = message
        self.evidence = evidence
        self.attachments = attachments
    }
}
