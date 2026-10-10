//
//  GalleryComponents.swift
//  TaskHubGallery
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubDesignSystem

struct GalleryComponents: View {
    @Binding var syncState: HubSyncState
    @State private var showsError = true
    @State private var actionResult = "未実行"

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpacing.lg) {
            GalleryHeading(title: "同期とエラー")
            Text("表示中：\(syncState.title)")
                .font(HubTypography.callout)
                .accessibilityIdentifier("demo.sync.status")
            HubButton(title: "オフライン表示", systemImage: "wifi.slash", role: .secondary) {
                syncState = .offline(lastUpdated: GalleryData.now)
            }
            .accessibilityIdentifier("sync.offline")
            HubButton(title: "同期エラー表示", systemImage: "exclamationmark.icloud", role: .secondary) {
                syncState = .failed(message: "サンプルの同期エラーです。再試行すると端末内の表示だけを同期済みに戻します。")
            }
            .accessibilityIdentifier("sync.error")
            HubButton(title: "同期中表示", systemImage: "arrow.triangle.2.circlepath", role: .secondary) {
                syncState = .syncing
            }
            .accessibilityIdentifier("sync.syncing")
            HubButton(title: "同期済みに戻す", systemImage: "checkmark.icloud", role: .secondary) {
                syncState = .synced(lastUpdated: GalleryData.now)
            }
            .accessibilityIdentifier("sync.reset")
            if showsError {
                HubErrorState(message: "読み取りに失敗した場合の表示例です。入力内容を失わずに再試行できることを確認します。") {
                    showsError = false
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("demo.error")
            } else {
                HubBadge(title: "再読み込みしました", systemImage: "checkmark.circle", tone: .success)
                    .accessibilityIdentifier("demo.error.recovered")
                HubButton(title: "エラーを再表示", role: .secondary) { showsError = true }
                    .accessibilityIdentifier("demo.error.reset")
            }

            GalleryHeading(title: "ボタン")
            HubCard {
                VStack(alignment: .leading, spacing: HubSpacing.sm) {
                    HubButton(title: "サンプルを実行", systemImage: "play.fill") { actionResult = "実行しました" }
                        .accessibilityIdentifier("demo.button.primary")
                    HubButton(title: "元に戻す", systemImage: "arrow.uturn.backward", role: .secondary) { actionResult = "未実行" }
                    HubButton(title: "ローカル表示をクリア", systemImage: "trash", role: .destructive) { actionResult = "表示をクリアしました" }
                    HubButton(title: "権限がない操作", systemImage: "lock") { actionResult = "操作しました" }
                        .disabled(true)
                        .accessibilityIdentifier("demo.button.disabled")
                    HubButton(title: "処理中", isLoading: true) { actionResult = "処理しました" }
                        .accessibilityIdentifier("demo.button.loading")
                    Text(actionResult).font(HubTypography.callout)
                        .accessibilityIdentifier("demo.button.result")
                }
            }

            DisclosureGroup("状態・優先度・期限") {
                VStack(alignment: .leading, spacing: HubSpacing.md) {
                    ForEach(HubTaskStatus.allCases) { status in
                        HubBadge(title: status.title, systemImage: status.systemImage, tone: status.tone)
                    }
                    Divider()
                    ForEach(HubDecisionStatus.allCases) { status in
                        HubBadge(title: status.title, systemImage: status.systemImage, tone: status.tone)
                    }
                    Divider()
                    ForEach(HubPriority.allCases) { priority in
                        HubBadge(title: priority.title, systemImage: priority.systemImage, tone: priority.tone)
                    }
                    Divider()
                    HubDueLabel(date: nil, now: GalleryData.now)
                    HubDueLabel(date: GalleryData.now.addingTimeInterval(-86_400), now: GalleryData.now)
                    HubDueLabel(date: GalleryData.now.addingTimeInterval(10_800), now: GalleryData.now)
                    HubDueLabel(date: GalleryData.now.addingTimeInterval(604_800), now: GalleryData.now)
                    HubDueLabel(date: GalleryData.now.addingTimeInterval(-86_400), now: GalleryData.now, isResolved: true)
                }
                .padding(.top, HubSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("demo.disclosure.status")

            DisclosureGroup("カラー・文字・余白") {
                VStack(alignment: .leading, spacing: HubSpacing.md) {
                    colorSamples
                    typographySamples
                    HubMetadata(label: "余白トークン", value: "xxs / xs / sm / md / lg / xl / xxl", systemImage: "arrow.left.and.right")
                    VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                        ForEach(Array(spacings.enumerated()), id: \.offset) { _, sample in
                            HStack {
                                Text(sample.0).font(HubTypography.identifier).frame(width: 52, alignment: .leading)
                                RoundedRectangle(cornerRadius: 2).fill(HubColor.accent)
                                    .frame(width: sample.1, height: 8)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .padding(.top, HubSpacing.sm)
            }
            .accessibilityIdentifier("demo.disclosure.tokens")

            DisclosureGroup("空状態・長い日本語") {
                VStack(alignment: .leading, spacing: HubSpacing.md) {
                    HubEmptyState(title: "まだタスクがありません", message: "新しい依頼が記録されると、このレーンに表示されます。")
                    HubCard {
                        VStack(alignment: .leading, spacing: HubSpacing.sm) {
                            Text(GalleryData.longTitle)
                                .font(HubTypography.headline)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("demo.longText")
                            HubMetadata(label: "長い担当者名", value: "日本語とアクセシビリティの確認を担当するエージェント")
                            HubAttachmentRow(attachment: GalleryData.attachment)
                        }
                    }
                }
                .padding(.top, HubSpacing.sm)
            }
            .accessibilityIdentifier("demo.disclosure.longText")
        }
        .foregroundStyle(HubColor.text)
    }

    private var colorSamples: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: HubSpacing.sm)], spacing: HubSpacing.sm) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, sample in
                HubCard {
                    VStack(alignment: .leading, spacing: HubSpacing.xs) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(sample.1)
                            .frame(height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(HubColor.separator))
                            .accessibilityHidden(true)
                        Text(sample.0).font(HubTypography.identifier)
                    }
                }
            }
        }
    }

    private var typographySamples: some View {
        VStack(alignment: .leading, spacing: HubSpacing.sm) {
            Text("大見出し・Large Title").font(HubTypography.largeTitle)
            Text("見出し・Title").font(HubTypography.title)
            Text("強調・Headline").font(HubTypography.headline)
            Text("本文・Body：判断の根拠を記録します。").font(HubTypography.body)
            Text("補足・Callout：次の操作を確認します。").font(HubTypography.callout)
            Text("注記・Caption：表示専用サンプル。").font(HubTypography.caption)
            Text("T-101 / D-201").font(HubTypography.identifier)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var colors: [(String, Color)] {
        [
            ("canvas", HubColor.canvas), ("surface", HubColor.surface), ("elevatedSurface", HubColor.elevatedSurface),
            ("text", HubColor.text), ("secondaryText", HubColor.secondaryText), ("separator", HubColor.separator),
            ("accent", HubColor.accent), ("onAccent", HubColor.onAccent), ("success", HubColor.success),
            ("warning", HubColor.warning), ("danger", HubColor.danger), ("info", HubColor.info)
        ]
    }

    private var spacings: [(String, CGFloat)] {
        [("xxs", HubSpacing.xxs), ("xs", HubSpacing.xs), ("sm", HubSpacing.sm), ("md", HubSpacing.md),
         ("lg", HubSpacing.lg), ("xl", HubSpacing.xl), ("xxl", HubSpacing.xxl)]
    }
}
