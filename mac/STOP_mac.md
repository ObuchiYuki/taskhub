# STOP: Mac実操作テストのOS認証

2026-10-10

## 停止理由

Macアプリの実装、ローカル署名付きビルド、77件の自動テストは成功した。Mac実操作テストはランナー初期化時にOS認証で停止し、操作シナリオを開始できなかった。

```text
Failed to initialize for UI testing:
Error Domain=com.apple.LocalAuthentication Code=-4
"System authentication is running."
NSLocalizedDescription=認証はキャンセルされました。
```

`xcodebuild ... test-without-building` は終了コード65。共通デザイン側の `STOP_design.md` と同じ種類の停止原因。

SPEC.mdの「ユーザー作業が必要なら停止」に従い、ここで実装・検証を止めた。認証の代行、許可設定の変更、認証回避は実施していない。完成判定は保留。

## 保存した成果

- `mac/TaskHubMac.xcodeproj`、Swift Package、タスク・裁定・履歴・添付・検索・ダイジェスト画面。
- GitHub private／ローカル取得、60秒周期の変更検知、保全付きcache、commit／hash検証。
- 77件の成功済み試験。サーバーCLIが生成したsnapshot、3添付、20イベントの検証を含む。
- 実操作テスト2シナリオのソース。接続、検索、絞込み、関連遷移、同期、履歴、オフライン表示、再起動を対象にする。
- 詳細な結果・未検証範囲: [REPORT_mac.md](REPORT_mac.md)。起動方法: [README.md](../mac/README.md)。

## 選択肢

1. **このMacのOS認証を解消し、実操作検証を再開する（推奨）。** コードとテストは保存済み。
2. ログイン済みでUIテストを許可できる別のMacへ、`mac/`・`design-system/`・`server/` の相対配置を保って移し、同じ検証を実施する。

## 必要なユーザー作業

1. Macをロック解除し、表示中のシステム認証ダイアログの内容を確認して完了またはキャンセルする。
2. Xcodeで `mac/TaskHubMac.xcodeproj` を開く。
3. `TaskHubMac` スキーム、`My Mac` を選び、**Product → Test** を実行する。
4. UIテスト用の認証・許可が表示された場合は、ユーザー自身が内容を確認して操作する。Apple開発者アカウントを使う署名設定は不要。
5. 認証解消後、下記コマンドで検証を再開する。

```sh
cd <repo>/mac

# Macアプリを再ビルドし、実操作テストを実行
xcodebuild -project TaskHubMac.xcodeproj -scheme TaskHubMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/taskhub-mac-resume \
  -parallel-testing-enabled NO test

# 単体・通信mock・描画・実サーバー契約の再確認
FIXTURE="$(python3 Scripts/make-server-fixture.py)"
TASKHUB_CONTRACT_FIXTURE="$FIXTURE" swift test
```

Intel Macではdestinationの `arch=arm64` を外す。UIテストはプロジェクト既定のアドホック署名を使用する。`CODE_SIGNING_ALLOWED=NO` は指定しない。

## 再開後の確認対象

- 接続設定→全レーンの未対応裁定→元タスク→検索・レーン／状態／担当／期間絞込み。
- サーバーで裁定回答後の同期と、裁定一覧・元タスク・ダイジェスト間の表示整合。
- 添付保存パネル、キャンセル、保存したファイルの内容。
- 全変更履歴の追加読込み、取得失敗と再試行。
- ローカル取得失敗時の既存表示、アプリ再起動後のcache復元。
- 小さい／大きいウインドウ、ライト／ダーク、VoiceOver。
- 利用者が指定した実privateリポジトリで、既存gh認証・push後の自動同期・スリープ復帰を確認。

一時ビルド・検証fixture・画像は清掃し、ソースと再現手順を残す。本書は `mac/STOP_mac.md` と `_spec/STOP_mac.md` に配置した。
