//
//  HubHistoryRow.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

/// 操作者、日時、根拠、添付を示す追記履歴。編集・削除操作を内包しない。
public struct HubHistoryRow: View {
    public let entry: HubHistoryEntry

    public init(entry: HubHistoryEntry) {
        self.entry = entry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HubSpacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: HubSpacing.sm) {
                    actorLabel
                    timestampLabel
                }
                .fixedSize(horizontal: true, vertical: true)

                VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                    actorLabel
                    timestampLabel
                }
            }

            Text(verbatim: entry.message)
                .font(HubTypography.body)
                .foregroundStyle(HubColor.text)

            if let evidence = entry.evidence {
                VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                    Label("根拠", systemImage: "checkmark.seal")
                        .font(HubTypography.caption)
                        .foregroundStyle(HubColor.secondaryText)
                    Text(verbatim: evidence)
                        .font(HubTypography.callout)
                        .foregroundStyle(HubColor.text)
                }
            }

            if !entry.attachments.isEmpty {
                VStack(alignment: .leading, spacing: HubSpacing.xs) {
                    Label("添付", systemImage: "paperclip")
                        .font(HubTypography.caption)
                        .foregroundStyle(HubColor.secondaryText)

                    ForEach(entry.attachments) { attachment in
                        HubAttachmentRow(attachment: attachment)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .padding(.leading, HubSpacing.md)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(HubColor.separator)
                .frame(width: 2)
                .accessibilityHidden(true)
        }
        .padding(.vertical, HubSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var actorLabel: some View {
        HubMetadata(label: "操作者", value: entry.actor, systemImage: "person.crop.circle")
    }

    private var timestampLabel: some View {
        Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
            .font(HubTypography.caption)
            .foregroundStyle(HubColor.secondaryText)
    }
}
