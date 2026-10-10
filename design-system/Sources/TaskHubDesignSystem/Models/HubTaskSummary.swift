//
//  HubTaskSummary.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

/// 一覧向けの読み取り専用タスク情報。保存形式や状態遷移を定義しない。
public struct HubTaskSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: HubTaskStatus
    public let lane: HubLane
    public let priority: HubPriority
    public let assignee: String?
    public let dueDate: Date?
    /// 最後の操作を行ったユーザーまたはエージェントの表示名。
    public let updatedBy: String?
    public let updatedAt: Date?
    /// 呼び出し側で集計した非負のサブタスク総数。
    public let subtaskCount: Int
    /// 0以上、サブタスク総数以下の完了件数。
    public let completedSubtaskCount: Int
    /// 完了時の必須チェックは呼び出し側が行う。
    public let evidence: String?

    /// 渡された表示値を保持する。件数の検証や完了の認定は行わない。
    public init(
        id: String,
        title: String,
        status: HubTaskStatus = .notStarted,
        lane: HubLane,
        priority: HubPriority = .normal,
        assignee: String? = nil,
        dueDate: Date? = nil,
        updatedBy: String? = nil,
        updatedAt: Date? = nil,
        subtaskCount: Int = 0,
        completedSubtaskCount: Int = 0,
        evidence: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.lane = lane
        self.priority = priority
        self.assignee = assignee
        self.dueDate = dueDate
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
        self.subtaskCount = subtaskCount
        self.completedSubtaskCount = completedSubtaskCount
        self.evidence = evidence
    }
}
