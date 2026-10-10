# TaskHubDesignSystem

Mac／iOS共通のSwiftUIデザインシステム。Swift Package、外部依存なし。

**検証停止:** Mac UI自動操作にOS認証が必要。ライブラリは実装・両OSビルド済み。残りの検証と再開手順は [STOP_design.md](../_spec/STOP_design.md) を参照。

- macOS 14+／iOS 17+、Swift 6、Xcode 16+。
- 日本語ラベル、ライト／ダーク、Dynamic Type、コントラスト増加対応。
- タスク・ユーザー裁定・履歴・添付・同期状態を同じ部品で表示。
- コンポーネントカタログ: `Examples/TaskHubGallery.xcodeproj`。
- UI規約: [DESIGN_GUIDELINES.md](DESIGN_GUIDELINES.md)。全APIの使い方と検証結果: [REPORT_design.md](../_spec/REPORT_design.md)。

## 導入

Xcodeのアプリプロジェクトから **File → Add Package Dependencies… → Add Local…** で、この `design-system` ディレクトリを選ぶ。アプリターゲットに `TaskHubDesignSystem` を追加する。

別のSwift Packageから参照する場合:

```swift
// Package.swift
 dependencies: [
     .package(path: "../design-system")
 ],
 targets: [
     .target(
         name: "YourAppFeature",
         dependencies: [
             .product(name: "TaskHubDesignSystem", package: "design-system")
         ]
     )
 ]
```

```swift
import SwiftUI
import TaskHubDesignSystem

struct TaskList: View {
    let tasks: [HubTaskSummary]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List(tasks) { task in
                NavigationLink {
                    ScrollView {
                        HubTaskRow(task: task, now: context.date)
                            .padding(HubSpacing.md)
                    }
                } label: {
                    HubTaskRow(task: task, now: context.date)
                }
            }
        }
        .hubTheme()
    }
}
```

`NavigationStack`／`NavigationSplitView` の中で使用する。表示モデルへの変換はアプリ側に置く。サーバーの状態名を `HubTaskStatus` 等へ明示的にマッピングする。

## 部品

- 基礎: `HubColor`、`HubTypography`、`HubSpacing`、`HubRadius`、`HubMetrics`。
- 共通: `HubCard`、`HubBadge`、`HubMetadata`、`HubDueLabel`。
- 操作: `HubButton`、`HubButtonStyle`、`HubSearchField`、`HubFilterChip`。
- データ: `HubTaskRow`、`HubDecisionCard`、`HubLaneLabel`、`HubAttachmentRow`、`HubHistoryRow`。
- 状態: `HubEmptyState`、`HubLoadingState`、`HubErrorState`、`HubSyncBanner`。

## 検証

```sh
swift test

xcodebuild -project Examples/TaskHubGallery.xcodeproj \
  -scheme TaskHubGallery -destination 'platform=macOS' build

xcodebuild -project Examples/TaskHubGallery.xcodeproj \
  -scheme TaskHubGallery -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

カタログをXcodeで開き、`TaskHubGallery` スキームと実行先を選んで起動する。サンプルの回答や検索はプロセス内のデモデータを操作する。ライブラリ／カタログともに通信や外部公開を行わない。
