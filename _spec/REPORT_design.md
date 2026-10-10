# Mac／iOS共通デザインシステム

## 状態・進捗

**実装済み。Mac UI自動操作のOS認証で検証停止。完成判定は保留。** 理由・選択肢・再開手順は [`STOP_design.md`](STOP_design.md) に記載した。

- 2026-10-10: `SPEC.md` を確認し、空の `design-system/` にSwiftUIライブラリを実装。
- パッケージ名・製品名・import名: **`TaskHubDesignSystem`**。
- macOS 14以降／iOS 17以降。Swift 6、Xcode 16以降。検証環境はXcode 27.0／Swift 6.4。
- 外部依存なし。ローカルSwift PackageとしてMac／iOSアプリで同一ソースを参照する。
- 共通ライブラリのmacOS・iOS Simulatorビルドと各23件のテスト成功。カタログの両OS向けビルド成功。iOSの通常操作6シナリオと最大文字サイズの1シナリオを別実行で確認。
- Mac UIテストランナーはローカル署名成功後、`com.apple.LocalAuthentication Code=-4 "System authentication is running."` で起動できず、仕様に従って停止した。

## 成果物

- `design-system/Package.swift`: Swift Package定義。
- `Sources/TaskHubDesignSystem/Foundation/`: 色、文字、余白、サイズ、期限判定。
- `Sources/TaskHubDesignSystem/Models/`: タスク・裁定・レーン・添付・履歴の表示モデル。
- `Sources/TaskHubDesignSystem/Components/`: 共通部品、操作部品、データ表示部品。
- `Tests/TaskHubDesignSystemTests/`: 状態・モデル・コントラスト・期限境界・描画テスト。
- `Examples/TaskHubGallery.xcodeproj`: Mac／iOS両対応の部品カタログ。
- `Tests/GalleryUITests/`: カタログのUI操作テスト。
- `README.md`: 導入手順。`DESIGN_GUIDELINES.md`: 配色・レイアウト・アクセシビリティ・責務の規約。

## 技術選定

SwiftUI＋Swift Package Managerを採用した。標準の画面遷移、入力、キーボード操作、アクセシビリティを両OSで利用でき、表示部品を一箇所で保守できる。SF Symbolsとシステムフォントを使い、追加フォントや画像素材の配布を不要にした。

通信・認証・永続化・同期処理・サーバーのデータ形式はアプリ側で扱う。ライブラリは表示モデルと操作クロージャを受け取る。サーバー実装と独立して導入できる。

## アプリへの導入

### Xcodeプロジェクト

1. MacまたはiOSのプロジェクトを開く。
2. **File → Add Package Dependencies… → Add Local…** で `../design-system` を指定する。
3. アプリターゲットに製品 `TaskHubDesignSystem` を追加する。
4. Deployment TargetをmacOS 14以上／iOS 17以上にする。
5. Swiftファイルで `import TaskHubDesignSystem`。

ローカルパッケージ参照にはApple開発者登録やネットワーク接続を必要としない。実機配布時の署名設定はアプリ側で扱う。

### 別のSwift Packageから参照

```swift
// Package.swift の該当箇所
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

パッケージの参照ID `design-system` はローカルディレクトリ名に対応する。

## 基礎トークン

- `HubColor`: `canvas`、`surface`、`elevatedSurface`、`text`、`secondaryText`、`separator`、`accent`、`onAccent`、`success`、`warning`、`danger`、`info`。
- `HubTypography`: `largeTitle`、`title`、`headline`、`body`、`callout`、`caption`、`identifier`。システム文字サイズに追従。ID用は等幅。
- `HubSpacing`: `xxs=4`、`xs=8`、`sm=12`、`md=16`、`lg=24`、`xl=32`、`xxl=48` pt。
- `HubRadius`: `small=8`、`medium=12`、`large=16` pt。
- `HubMetrics`: `minimumTarget=44`、`readingWidth=720`、`sidebarMinimumWidth=220` pt。
- `.hubTheme()`: 画面の本文フォント・本文色・アクセントを適用する。
- `HubTone`: `.neutral`、`.accent`、`.info`、`.success`、`.warning`、`.danger`。

色はライト／ダーク／コントラスト増加に追従する。標準文字のコントラスト4.5:1以上、操作境界3:1以上を単体テストで検査する。状態は文字＋記号＋色の組み合わせ。

## 状態と表示モデル

### 状態

- `HubTaskStatus`: `.notStarted` 未着手、`.inProgress` 進行中、`.needsReview` ユーザー確認待ち、`.blocked` ブロック、`.completed` 完了、`.onHold` 保留。
- `HubDecisionStatus`: `.pending` 未対応、`.answered` 回答済み、`.applied` 反映済み。
- `HubPriority`: `.low` 低、`.normal` 通常、`.high` 高、`.urgent` 緊急。

各状態は `id`、`title`、`systemImage`、`tone` を公開する。サーバーの状態名は、アプリ側の変換層でこれらのenumへマッピングする。未知の状態はアプリ側で明示的に扱う。

### モデル

全モデルは `Identifiable`／`Equatable`／`Sendable`。IDは `String`、日時は `Date`。プロパティは読み取り専用。更新時は新しい値を作成してアプリの状態へ反映する。

- `HubLane(id:name:)`: 共有プロジェクト。
- `HubTaskSummary(id:title:status:lane:priority:assignee:dueDate:updatedBy:updatedAt:subtaskCount:completedSubtaskCount:evidence:)`: 一覧向けタスク。必須はID・タイトル・レーン。状態は未着手、優先度は通常、サブタスク件数は0が既定値。
- `HubDecisionSummary(id:title:taskID:lane:status:options:reason:dueDate:registeredBy:registeredAt:reply:)`: ユーザー裁定。必須はID・タイトル・元タスクID・レーン・理由。状態は未対応、選択肢は空配列が既定値。
- `HubAttachment(id:fileName:description:registeredBy:registeredAt:systemImage:)`: 添付メタデータ。必須はID・ファイル名。種類の記号は `"doc"` が既定値。
- `HubHistoryEntry(id:actor:timestamp:message:evidence:attachments:)`: 追記履歴。必須はID・操作者・日時・本文。添付は空配列が既定値。

省略可能な文字列・日時は `nil` が既定値。アプリは操作者・日時・説明を実データから渡す。金額・やり方・親タスクIDなど追加属性は `HubMetadata` を組み合わせて詳細画面に表示する。

## タスク一覧の例

```swift
import SwiftUI
import TaskHubDesignSystem

struct SharedTaskList: View {
    let tasks: [HubTaskSummary]

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List(tasks) { task in
                    NavigationLink {
                        ScrollView {
                            HubCard {
                                HubTaskRow(task: task, now: context.date)
                            }
                            .padding(HubSpacing.md)
                        }
                        .background(HubColor.canvas)
                        .navigationTitle(task.id)
                    } label: {
                        HubTaskRow(task: task, now: context.date)
                    }
                }
            }
            .navigationTitle("タスク")
        }
        .hubTheme()
    }
}

let lane = HubLane(id: "lane-native", name: "Mac／iOSアプリ")
let task = HubTaskSummary(
    id: "TASK-001",
    title: "共通画面を確認する",
    status: .needsReview,
    lane: lane,
    priority: .high,
    assignee: "agent-reviewer",
    dueDate: .now.addingTimeInterval(3_600),
    updatedBy: "agent-worker",
    updatedAt: .now,
    subtaskCount: 3,
    completedSubtaskCount: 2
)
```

Mac／iPadではこの一覧を `NavigationSplitView` に組み込める。`HubTaskRow` 自体は表示専用。遷移先、選択状態、担当／状態／期間フィルタはアプリ側で管理する。

## 裁定・添付・履歴の例

```swift
let decision = HubDecisionSummary(
    id: "DECISION-001",
    title: "作業方針を選んでほしい",
    taskID: task.id,
    lane: lane,
    options: ["現在の構成で進める", "別案を調査する"],
    reason: "次の作業にはユーザーの判断が必要",
    dueDate: .now.addingTimeInterval(3_600),
    registeredBy: "agent-worker",
    registeredAt: .now
)

let attachment = HubAttachment(
    id: "ATTACHMENT-001",
    fileName: "確認結果.png",
    description: "ライト／ダーク表示の比較",
    registeredBy: "agent-worker",
    registeredAt: .now,
    systemImage: "photo"
)

let entry = HubHistoryEntry(
    id: "HISTORY-001",
    actor: "agent-worker",
    timestamp: .now,
    message: "検証結果を追記した",
    evidence: "MacとiOSのテストが成功",
    attachments: [attachment]
)

// SwiftUIのViewBuilder内
HubDecisionCard(decision: decision)
HubAttachmentRow(attachment: attachment)
HubHistoryRow(entry: entry)
HubMetadata(label: "金額", value: "¥12,000", systemImage: "yensign.circle")
HubMetadata(label: "やり方", value: "検証結果を確認してから作業を進める")
```

裁定は専用一覧を作り、全レーンの未対応項目を表示する。回答フォームと保存処理はアプリ側で実装し、回答後に `.answered` と `reply` を含む新しい表示値へ更新する。反映後は `.applied`。回答者・回答日時・元タスク再開も保存層で記録する。

添付の取得先やURLはモデルに含めていない。表示行を `Button` でラップし、アプリ側の安全な取得・プレビュー処理へ接続する。履歴は配列順のまま表示するため、アプリ側で時系列に整列する。

## 操作・空・エラー・同期

```swift
// @State private var query = "" を持つView内
HubSearchField(text: $query)
HubFilterChip(title: "未対応", isSelected: true) { /* アプリの条件を更新 */ }
HubButton(title: "回答を保存", systemImage: "checkmark") { /* アプリの保存処理 */ }
HubButton(title: "再確認", role: .secondary) { /* アプリの操作 */ }
HubButton(title: "保存中", isLoading: true) {} // 処理中は操作不可

HubLoadingState()
HubEmptyState(title: "一致する項目なし", message: "検索条件を変更してください。")
HubErrorState(message: "データを読み込めませんでした。", retry: { /* 再試行 */ })
HubSyncBanner(state: .offline(lastUpdated: .now), retry: { /* 同期 */ })
```

- `HubButtonRole`: `.primary`／`.secondary`／`.destructive`。既存ボタンには `.buttonStyle(HubButtonStyle(role: .secondary))`。
- `HubSearchField(text:prompt:)`: 標準入力と検索クリア。文字列のBindingを通知する。全文検索処理はアプリ側で実行する。
- `HubEmptyState(title:message:systemImage:actionTitle:action:)`: 操作はラベルとクロージャの両方を渡すと表示。
- `HubErrorState(title:message:retry:)`: エラー理由と任意の再試行操作。
- `HubSyncState`: `.synced(lastUpdated:)`／`.syncing`／`.offline(lastUpdated:)`／`.failed(message:)`。`canRetry` はオフライン・失敗時にtrue。
- 保存済みデータがあるオフライン状態は既存一覧と同期バナーを併記する。初回取得失敗はエラー表示にする。
- `HubBadge(title:systemImage:tone:)`、`HubCard { ... }`、`HubMetadata(label:value:systemImage:)` で追加表示を組み立てる。

## 期限・完了・プライバシーの注意

- `HubDueLabel(date:now:isResolved:)` は期限なし／期限切れ／24時間以内／通常期限を区別する。
- 期限は絶対時刻。日付だけの期限はアプリ側でタイムゾーン・締切時刻を確定する。
- 判定には注入した `now` を使用する。開きっぱなしの一覧は `TimelineView` 等で更新する。
- 完了タスクと回答済み以降の裁定は期限警告を解除し、元の日時を保持する。
- 完了証拠必須、サブタスク件数の整合性、履歴の追記専用保存、IDの一意性、削除禁止はアプリ／サーバーで検証する。
- 文字列はプレーンテキスト表示。ライブラリに通信・解析送信・共有・外部公開処理は含めていない。
- サンプルカタログの回答はウインドウ内メモリに保存し、再起動で初期化する。

## ビルド・検証コマンド

`design-system/` で実行する。

```sh
# macOS: 単体・描画テスト
swift test

# iOS: ライブラリのSimulatorビルド
xcodebuild -scheme TaskHubDesignSystem \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# カタログ: Macビルド
xcodebuild -project Examples/TaskHubGallery.xcodeproj \
  -scheme TaskHubGallery -destination 'platform=macOS' build

# カタログ: iOS Simulatorビルド
xcodebuild -project Examples/TaskHubGallery.xcodeproj \
  -scheme TaskHubGallery -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# 利用可能なSimulatorを確認
xcrun simctl list devices available

# <UUID> を端末IDに置き換える
xcodebuild -scheme TaskHubDesignSystem \
  -destination 'platform=iOS Simulator,id=<UUID>' \
  CODE_SIGNING_ALLOWED=NO test
```

カタログはXcodeで `Examples/TaskHubGallery.xcodeproj` を開き、`TaskHubGallery` スキームとMy MacまたはiPhone Simulatorを選んでRunする。

## 検証結果

- macOS: ライブラリビルド成功、23テスト成功。
- iOS Simulator 27.0／iPhone 17: ライブラリビルド成功、23テスト成功。
- 描画テスト: 幅320／900pt、ライト／ダーク、標準／最大Dynamic Type。モデル・状態・期限境界・テキスト保持・SF Symbolsを検査。
- Macの狭幅描画画像を確認し、長い日本語・ファイル名・選択肢・履歴の折り返しを確認。
- iOS UI操作の通常表示6シナリオ成功: 検索・クリア・空白入力、レーン切替、タスク詳細と添付・履歴、裁定回答と関連タスク画面への反映、再起動時の回答初期化、同期状態の一覧間共有と再試行、エラー再試行、無効／処理中ボタン。
- iOSの最大Dynamic Type＋ダーク表示: 検索後、実際に画面内へスクロールしてタスク詳細を開く操作の単独テスト成功。テストのスクロール判定を修正し、画面外の要素を誤ってタップする問題を解消した。
- 上記テスト補助コード修正後の全7シナリオ一括再実行は未実施。
- MacカタログとUIテストランナーのローカル署名成功。Mac UI操作テストはOS認証で停止した。認証解消後の再実行が必要。
- Macのローカル署名にはApple開発者アカウントを使わない。Macカタログ／UIテストを実行する際はプロジェクト既定の署名設定を使う。
- 実機、最小対応OSでの実行、VoiceOverの音声読み上げ操作は未検証。
