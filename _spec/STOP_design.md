# STOP: デザインシステムのMac UI操作検証

2026-10-10

## 停止理由

共通SwiftUIライブラリとMac／iOSの部品カタログは実装済み。MacのUI自動操作テストを開始する段階でOS認証に阻まれたため、SPEC.mdの停止条件に従って作業を停止した。

ローカル署名済みのテストランナーから返されたエラー:

```text
Failed to initialize for UI testing:
Error Domain=com.apple.LocalAuthentication Code=-4
"System authentication is running."
NSLocalizedDescription=認証はキャンセルされました。
```

OSの認証・許可設定はユーザー作業が必要。認証の代行、セキュリティ設定の変更、認証回避は実施していない。

## 実装・検証済み

- `design-system/` に `TaskHubDesignSystem` Swift Packageを実装。
- macOS 14+／iOS 17+、Swift 6、外部依存なし。
- 色・文字・余白、タスク6状態、裁定3状態、優先度、期限、添付、履歴、検索入力、フィルタ、ボタン、同期・空・エラー表示。
- macOS・iOS Simulatorのライブラリビルド成功。各23件の単体／描画テスト成功。
- Mac／iOSカタログのビルド成功。MacカタログとUIテストランナーのローカル署名成功。
- iPhone 17／iOS Simulator 27.0で通常表示のUI操作6シナリオ成功。検索・クリア・空白入力、レーン、裁定回答と関連タスクへの反映、再起動によるサンプル回答初期化、再試行、無効ボタン、添付・履歴を検証。
- 最大Dynamic Type＋ダーク表示の検索→スクロール→詳細遷移も単独再実行で成功。最初の失敗は、テストがキーボードの下にある画面外の行をタップしていたため。テストのスクロール対象判定を修正した。
- 最終テスト補助コード変更後の全7シナリオ一括再実行と、MacのUI操作検証は未完了。

使い方・API・責務・ビルド方法は `REPORT_design.md` に記載済み。

## 選択肢

1. **OS認証を解消し、残りの検証を再開する（推奨）**。Mac／iOSの全UIテストを再実行してから完成判定する。
2. ビルド・単体テスト・iOS操作の検証範囲で採用し、Mac UI検証をアプリ実装時に行う。未検証範囲を受け入れるユーザー判断が必要。

## 必要なユーザー作業

1. Macに表示中のシステム認証ダイアログを確認し、内容に応じて完了またはキャンセルする。
2. Xcodeで `design-system/Examples/TaskHubGallery.xcodeproj` を開く。
3. `TaskHubGallery` スキーム、実行先 `My Mac` で **Product → Test** を実行する。UIテスト用のOS認証・許可が要求された場合はユーザー自身で確認する。
4. 認証が完了した環境で、下記コマンドによる検証を再開する。

```sh
cd <repo>/design-system

# Mac。新しいビルド領域を使用する。署名はプロジェクト内のローカル署名設定を使う。
xcodebuild -project Examples/TaskHubGallery.xcodeproj \
  -scheme TaskHubGallery -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/taskhub-design-resume-mac test

# iPhone。UUIDは xcrun simctl list devices available で確認する。
xcodebuild -project Examples/TaskHubGallery.xcodeproj \
  -scheme TaskHubGallery \
  -destination 'platform=iOS Simulator,id=89597416-CCBB-4D1C-92E4-EA8703CB2A98' \
  -derivedDataPath /tmp/taskhub-design-resume-ios \
  CODE_SIGNING_ALLOWED=NO test
```

Macテストでは `CODE_SIGNING_ALLOWED=NO` を指定しない。カタログはアカウント不要のアドホック署名を設定済み。初回の署名無効テストではAppleのテストランナーの署名不整合が発生したため、再検証には新しいDerivedDataディレクトリを使う。
