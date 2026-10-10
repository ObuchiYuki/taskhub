//
//  RenderingTests.swift
//  TaskHubDesignSystemTests
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import XCTest
@testable import TaskHubDesignSystem
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class RenderingTests: XCTestCase {
    @MainActor
    func testPrimitivesRenderAtCompactAndWideSizes() throws {
        for width in [320.0, 900.0] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility5] {
                    let content = primitiveGallery
                        .padding(HubSpacing.md)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(HubColor.canvas)
                        .hubTheme()
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(width))
                    XCTAssertGreaterThan(image.height, 400)
                    try save(image, name: "primitives-\(Int(width))-\(scheme)-\(size)")
                }
            }
        }
    }

    @MainActor
    private var primitiveGallery: some View {
        VStack(alignment: .leading, spacing: HubSpacing.md) {
            Text("TaskHub 共通部品").font(HubTypography.title)
            HubFilterChip(title: "共有プロジェクト・ユーザー確認待ち", isSelected: true) {}
            ForEach(HubTone.allCases, id: \.self) { tone in
                HubBadge(title: "状態を色と文字と記号で表示", systemImage: "checkmark.circle", tone: tone)
            }
            HubButton(title: "長い説明のある主要操作を実行", systemImage: "checkmark") {}
            HubButton(title: "無効な操作", role: .secondary) {}.disabled(true)
            HubMetadata(label: "根拠", value: "日本語の長い根拠やファイル名は折り返して表示する。")
            HubDueLabel(date: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 200))
            HubDueLabel(date: nil)
            HubSyncBanner(state: .offline(lastUpdated: nil)) {}
            HubSyncBanner(state: .failed(message: "ローカルの表示内容を確認し、通信の回復後に再試行。")) {}
            HubEmptyState(title: "該当するタスクがありません", message: "検索条件を変更してください。",
                          actionTitle: "条件をリセット", action: {})
            HubErrorState(message: "添付ファイルを読み込めませんでした。") {}
        }
    }

    @MainActor
    func testSemanticSymbolsExistOnHostPlatform() {
        let symbols = Set(HubDueState.allCases.map(\.systemImage) + [
            HubSyncState.synced(lastUpdated: nil).systemImage,
            HubSyncState.syncing.systemImage,
            HubSyncState.offline(lastUpdated: nil).systemImage,
            HubSyncState.failed(message: "").systemImage,
            "magnifyingglass", "xmark.circle.fill", "checkmark.circle.fill", "circle",
            "tray", "arrow.clockwise", "exclamationmark.triangle"
        ])
        for symbol in symbols {
            #if os(macOS)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
            #else
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
            #endif
        }
    }

    @MainActor
    private func save(_ image: CGImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TASKHUB_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        #else
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        #endif
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
