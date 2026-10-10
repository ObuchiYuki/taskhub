//
//  HubDecisionSummary.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

/// 元タスクに紐づくユーザー裁定の表示情報。
public struct HubDecisionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let taskID: String
    public let lane: HubLane
    public let status: HubDecisionStatus
    /// 表示順を維持する選択肢。空配列は選択肢の指定なし。
    public let options: [String]
    public let reason: String
    public let dueDate: Date?
    /// 登録したユーザーまたはエージェントの表示名。
    public let registeredBy: String?
    public let registeredAt: Date?
    /// 記録済みのユーザー回答。状態遷移は呼び出し側が管理する。
    public let reply: String?

    /// 通信形式への変換や回答内容の検証は行わない。
    public init(
        id: String,
        title: String,
        taskID: String,
        lane: HubLane,
        status: HubDecisionStatus = .pending,
        options: [String] = [],
        reason: String,
        dueDate: Date? = nil,
        registeredBy: String? = nil,
        registeredAt: Date? = nil,
        reply: String? = nil
    ) {
        self.id = id
        self.title = title
        self.taskID = taskID
        self.lane = lane
        self.status = status
        self.options = options
        self.reason = reason
        self.dueDate = dueDate
        self.registeredBy = registeredBy
        self.registeredAt = registeredAt
        self.reply = reply
    }
}
