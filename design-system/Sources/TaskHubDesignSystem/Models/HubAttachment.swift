//
//  HubAttachment.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

/// 添付の表示情報。ファイルの取得先や開く操作は保持しない。
public struct HubAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    /// Markdownとして解釈しないファイル名。
    public let fileName: String
    public let description: String?
    public let registeredBy: String?
    public let registeredAt: Date?
    /// ファイルの種類を示すSF Symbol名。
    public let systemImage: String

    /// 表示用メタデータだけを受け取る。
    public init(
        id: String,
        fileName: String,
        description: String? = nil,
        registeredBy: String? = nil,
        registeredAt: Date? = nil,
        systemImage: String = "doc"
    ) {
        self.id = id
        self.fileName = fileName
        self.description = description
        self.registeredBy = registeredBy
        self.registeredAt = registeredAt
        self.systemImage = systemImage
    }
}
