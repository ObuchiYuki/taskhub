//
//  AttachmentDetailView.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import PDFKit
import SwiftUI
import TaskHubCore
import TaskHubDesignSystem

struct AttachmentDetailView: View {
    let id: String
    @EnvironmentObject private var store: AppStore
    @State private var data: Data?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        DetailContainer(title: "添付") {
            if let attachment = store.snapshot?.attachments.first(where: { $0.id == id }) {
                HubCard { HubAttachmentRow(attachment: attachment.display) }
                HubMetadata(label: "サイズ", value: ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
                HubMetadata(label: "形式", value: attachment.mediaType)
                Text(verbatim: "SHA-256: \(attachment.sha256)")
                    .font(HubTypography.identifier).textSelection(.enabled)
                if let error { HubErrorState(message: error) }
                HubButton(title: data == nil ? "取得してプレビュー" : "再取得", systemImage: "arrow.down.doc", isLoading: loading) {
                    Task {
                        loading = true
                        error = nil
                        defer { loading = false }
                        do { data = try await store.attachmentData(attachment) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                if let data {
                    AttachmentPreview(data: data, mediaType: attachment.mediaType)
                } else {
                    Text("取得時に同じcommitの内容・サイズ・SHA-256を検証します。ファイルは実行しません。")
                        .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
                }
            }
        }
    }
}

private struct AttachmentPreview: View {
    let data: Data
    let mediaType: String

    var body: some View {
        Group {
            if data.isEmpty {
                Text("空のファイル（0バイト）").accessibilityIdentifier("empty-file-preview")
            } else if ["image/png", "image/jpeg", "image/heic", "image/gif"].contains(mediaType), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("添付画像")
            } else if mediaType == "application/pdf" {
                PDFPreview(data: data)
            } else if mediaType.hasPrefix("text/") || ["application/json", "application/xml"].contains(mediaType) {
                let prefix = Data(data.prefix(256 * 1_024))
                Text(verbatim: String(decoding: prefix, as: UTF8.self))
                    .font(HubTypography.identifier).textSelection(.enabled)
                if data.count > prefix.count { Text("先頭256KiBを表示しています。").font(HubTypography.caption) }
            } else {
                HubEmptyState(title: "検証済み", message: "このファイル形式はプレビューに対応していません。サーバー側で内容を確認してください。", systemImage: "checkmark.shield")
            }
        }
    }
}

private struct PDFPreview: View {
    let data: Data
    @State private var pageIndex = 0

    var body: some View {
        if let document = PDFDocument(data: data), document.pageCount > 0 {
            VStack(spacing: HubSpacing.md) {
                if let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
                    Image(uiImage: page.thumbnail(of: CGSize(width: 1_024, height: 1_448), for: .mediaBox))
                        .resizable().scaledToFit().accessibilityLabel("PDF・\(pageIndex + 1)ページ")
                }
                HStack {
                    Button("前へ") { pageIndex -= 1 }.disabled(pageIndex == 0)
                    Spacer()
                    Text("\(pageIndex + 1) / \(document.pageCount)")
                    Spacer()
                    Button("次へ") { pageIndex += 1 }.disabled(pageIndex >= document.pageCount - 1)
                }
                .buttonStyle(HubButtonStyle(role: .secondary))
            }
        } else {
            HubErrorState(message: "このPDFを描画できません。")
        }
    }
}
