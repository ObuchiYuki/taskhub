//
//  HubAttachmentRow.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

/// 添付名と登録情報の読み取り専用行。開く操作や取得処理は呼び出し側が管理する。
public struct HubAttachmentRow: View {
    public let attachment: HubAttachment

    public init(attachment: HubAttachment) {
        self.attachment = attachment
    }

    public var body: some View {
        HStack(alignment: .top, spacing: HubSpacing.sm) {
            Image(systemName: attachment.systemImage)
                .font(HubTypography.title)
                .foregroundStyle(HubColor.secondaryText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HubSpacing.xs) {
                Text(verbatim: attachment.fileName)
                    .font(HubTypography.body)
                    .foregroundStyle(HubColor.text)

                if let description = attachment.description {
                    Text(verbatim: description)
                        .font(HubTypography.callout)
                        .foregroundStyle(HubColor.text)
                }

                if let registeredBy = attachment.registeredBy {
                    HubMetadata(label: "登録者", value: registeredBy, systemImage: "person.crop.circle")
                }

                if let registeredAt = attachment.registeredAt {
                    Text("登録日時 \(registeredAt, format: .dateTime.year().month().day().hour().minute())")
                        .font(HubTypography.caption)
                        .foregroundStyle(HubColor.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .padding(.vertical, HubSpacing.xxs)
        .accessibilityElement(children: .combine)
    }
}
