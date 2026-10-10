//
//  HubLane.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

/// 複数の担当者で共有するレーンの表示情報。
public struct HubLane: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    /// IDの採番や名称の検証は呼び出し側が行う。
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
