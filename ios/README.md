# TaskHub iOS

iOS 17以降の読み取り専用クライアント。SwiftUIと `../design-system` の `TaskHubDesignSystem` を使う。サーバー契約は `../server/DESIGN.md` §6のsnapshot v1。実装・検証結果は [REPORT_ios.md](REPORT_ios.md)。

## 起動

1. Xcode 16以降で `TaskHub.xcodeproj` を開く。
2. `TaskHub` スキームとiPhoneまたはiPad Simulatorを選んでRun。
3. 初期画面の「サンプルを見る」で、通信なしに全画面を確認できる。

ローカルの2パッケージを使う。追加のパッケージ取得や開発者アカウントはSimulator実行に不要。SimulatorでもKeychain利用のためアドホック署名とアクセスグループを設定する。Xcodeプロジェクト既定の署名設定で実行する。データの書込みと裁定回答の記録はサーバーCLIが担当する。

## 画面

- **裁定**: 起動時は全レーンの未対応。状態を切り替え、回答者・記録者・回答日時・反映証拠・タスク再開を確認する。元タスクに移動できる。
- **タスク**: 6状態、優先度、期限、担当、金額、やり方、根拠、完了証拠、親子タスク、関連裁定、追記、添付を表示する。
- **整理**: 期限切れ、72時間以内、7日以上停滞、同一レーンの正規化同名タスク、未反映裁定を端末内で日本語集計する。部品の期限強調は共通規約の24時間以内。
- **設定**: 接続情報、同期、JSON読込、サンプルを切り替える。

タイトル・本文・根拠・証拠・裁定の選択肢や回答・追記・添付の説明とファイル名をUnicode正規化付きで検索。タスクと裁定それぞれの一覧で検索する。レーン・状態・担当・最終更新日時 `[開始, 終了)` を併用できる。裁定の担当は元タスクの担当。日時は端末のタイムゾーンで表示。

iPhoneはタブとスタック遷移、iPadはサイドバーと詳細領域。ライト／ダーク、Dynamic Type、システムのアクセシビリティに共通部品で対応。

## サーバーのJSONで確認

サーバー側の既存データ領域で `python3 -m taskhub snapshot` を実行し、出力した `snapshot.json` をiOSのファイルアプリへ用意する。アプリの「snapshot.jsonを読み込む」で選択する。

- JSONは端末内に保存する。自動更新にはGitHub接続が必要。
- JSONには添付の説明とハッシュを含む。添付本体は接続後、ユーザー操作で取得する。
- 同一ストアの古いJSON、同イベント連番の変更、未知schema、破損参照を拒否する。
- GitHub接続や表示データを置き換える場合、アプリで確認する。
- サンプルは一時表示。実データの保存領域を置き換えない。

## private GitHub接続

サーバーから同期済みの専用privateリポジトリが必要。次をアプリに設定する。

- 所有者、リポジトリ名、ブランチ名。
- 対象リポジトリ限定のFine-grained Personal Access Token。権限は **Contents: Read-only**。GitHubのMetadata読取りも使用する。
- 保存後のトークン更新では新しいトークンを入力する。空欄なら同じ接続先のKeychain資格情報を再利用する。

トークンは `AfterFirstUnlockThisDeviceOnly` のKeychainへ保存する。GitHub.comのAPIへGETだけを送る。公開リポジトリ、リポジトリID変更、リダイレクトを拒否。資格情報をJSONやログへ書かない。既存のMacのgh認証を自動利用しない。

### 更新検知

- フォアグラウンド: 60秒周期、復帰時、ツールバーの同期、引いて更新。
- バックグラウンド: `BGAppRefreshTask` で15分以降の実行を要求。iOSが時刻を決める。強制終了中やOS設定・電池状況によって実行されない。
- サーバーはAPNsやHTTPの通知を提供しない。GitHubのcommitとETagを確認し、変更を検知する。即時のpush通知保証はない。

毎回private属性を確認する。commit SHAに固定してsnapshotを取得し、参照整合性とstore ID・seq/hashを検査する。前回commitからの祖先関係も確認。成功時にキャッシュを原子的に置き換える。失敗時は最後の保存済み表示を維持し、バナーと再試行を表示する。

### 添付

snapshotと同じcommitから取得し、SHA-256・サイズ・hash由来のパスを検査する。32MiBが上限。テキストは先頭256KiB、画像は対応形式、PDFはページ単位の画像プレビュー。未対応形式は検証結果とメタデータを表示する。ファイルの実行や外部URLの自動取得は行わない。取得した添付はメモリ内のみ。

キャッシュはApplication Support配下の専用領域。ファイル保護 `completeUntilFirstUserAuthentication`、バックアップ除外、ディレクトリ0700／ファイル0600を適用。再起動後の初回アンロック前には資格情報・キャッシュを利用できない。

## 検証コマンド

```sh
# ドメイン・検索・同期・キャッシュ。macOS上で実行。
swift test

# Simulator向けビルド
xcodebuild -project TaskHub.xcodeproj -scheme TaskHub \
  -destination 'generic/platform=iOS Simulator' build

# 利用可能なSimulatorのUUIDを確認
xcrun simctl list devices available

# UI操作テスト
xcodebuild -project TaskHub.xcodeproj -scheme TaskHub \
  -destination 'platform=iOS Simulator,id=<UUID>' -collect-test-diagnostics never test
```

UIテストはDebug専用の `UITestTransport` でGitHub応答を置換する。接続→更新→関連画面の反映→通信失敗→保存済み表示→再起動を検査し、実GitHubへ接続しない。テストは `TaskHubUITests` 専用保存領域と架空の資格情報を使用する。通常起動・Releaseにはテスト通信を適用しない。

`Scripts/generate-demo.py` は未変更のサーバーCLIを一時データ領域で実行し、fixtureとサンプルを再生成する。IDは再発行される。単体テストはタイトルで対象を選ぶ。外部通信は行わない。

## 構成

- `App/`: SwiftUI画面、表示モデル変換、状態管理、バックグラウンド更新。
- `Sources/TaskHubCore/`: snapshot契約、検証、検索、ダイジェスト、GitHub通信、Keychain、キャッシュ。
- `Tests/TaskHubCoreTests/`: サーバー生成fixtureによる契約・失敗系テスト。
- `Tests/TaskHubUITests/`: Simulator上の実操作テスト。
- `TaskHub.xcodeproj/`: iPhone／iPadアプリとUIテスト。

全変更履歴の正本はサーバーのevents。snapshotが持つ追記を時系列に表示する。過去の属性変更はCLIの `task history` / `decision history` で確認する。

## 実機・本番接続

実機RunにはXcodeのSigning & Capabilitiesで利用者のTeamを設定し、端末を選ぶ。配布方法に応じて利用者のApple開発者設定が必要。アプリはリポジトリやアカウントを作成しない。実GitHub・実機・OSによるバックグラウンド実行の検証状況はREPORTを参照。
