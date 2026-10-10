# TaskHub Mac

macOS 14以降の読み取り専用SwiftUIクライアント。サーバーのsnapshot v1を読み、`../design-system` の `TaskHubDesignSystem` で表示する。Swift 6／Xcode 16以降、外部Swift依存なし。

## 起動

1. `TaskHubMac.xcodeproj` をXcodeで開く。
2. `TaskHubMac` スキームと `My Mac` を選び、Run。
3. 「同期元を設定」でGitHub privateリポジトリ、またはローカルデータフォルダを指定する。

アプリとテストランナーはアカウント不要のアドホック署名。開発実行向けで、App Store配布・公証は含まない。既存 `gh` 実行と明示選択されたローカルフォルダの読取りに対応するためApp Sandboxは無効。ネットワークはGitHub.comのHTTPS GETに限定する。

```sh
xcodebuild -project TaskHubMac.xcodeproj -scheme TaskHubMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/taskhub-mac-build build
open /tmp/taskhub-mac-build/Build/Products/Debug/TaskHubMac.app
```

Intel Macではdestinationの `arch=arm64` を外す。検証環境はApple Silicon。

## 同期元

### GitHub private

- `OWNER/REPOSITORY` とブランチ名を指定する。
- サーバーが同期する専用privateデータリポジトリを使用する。対象ブランチ直下に `snapshot.json` が必要。
- `/opt/homebrew/bin/gh`、`/usr/local/bin/gh`、`/usr/bin/gh` の順でGitHub CLIを検出し、既存の `gh auth token --hostname github.com` 認証を利用する。
- 対象リポジトリの読み取り権限が必要。Fine-grained tokenの場合はContents: Read権限を付けた既存gh認証を利用する。
- 認証の新規作成・リポジトリ作成・認証情報の入力保存はアプリから行わない。既存認証が読めなければエラーを表示する。
- アプリのウインドウが開いている間、60秒ごとにcommit SHA／ETagを確認する。起動・アプリ復帰・Macスリープ復帰時にも確認。手動はツールバーか `⌘R`。
- 毎回private属性と保存済みリポジトリIDを確認し、snapshot・添付・イベントをcommit SHA固定で取得する。
- サーバーはpush通知サービスを提供しない。検知遅延はサーバーのpush周期、Mac側の確認周期、通信状態に依存する。スリープ中・終了中の取得とリアルタイム通知は保証しない。最後のウインドウを閉じるとアプリ終了。

### ローカルフォルダ

サーバーのデータフォルダ、またはそのコピーを選択する。

```text
data/
  snapshot.json
  events/00000000000000000001.json
  blobs/sha256/ab/<SHA-256>
```

`server` のソースフォルダとは別の、CLIで初期化したデータフォルダを指定する。通常ファイルのみ読み、データ配下のsymlink・FIFOを拒否する。ローカルも60秒ごとに再確認する。添付は内容hash、履歴はsnapshotからのhash連鎖で整合を確認する。

## 画面

- **ユーザー裁定**: 初期表示は全レーン・未対応。回答済み・反映済み・未反映（未対応＋回答済み）も選択可能。元タスク、依頼、理由、選択肢、回答者・記録者・日時、反映証拠を表示。
- **タスク**: レーン、6状態、優先度、期限、担当、金額（十進文字列を維持）、やり方、根拠、完了証拠、登録／更新者、親子タスク、関連裁定。
- **全文検索・絞り込み**: タイトル・本文・追記・裁定の理由／選択肢／回答／反映証拠・添付名／説明。Unicode正規化・大文字小文字を無視。レーン・状態・担当・更新期間で絞る。裁定の担当は元タスクから参照する。タスクと裁定は各一覧で検索する。
- **更新期間**: 端末のタイムゾーンで開始日0時以上、終了日の翌日0時未満。タスクと裁定の検索条件は独立。
- **添付**: タスク・裁定・追記の説明、登録者、日時を表示。「検証して保存…」で保存先を選び、サイズとSHA-256を検証した内容を保存する。自動実行・自動オープンなし。
- **追記・作業ログ**: 元のイベント順で表示。
- **変更履歴**: 同期済みcommitの全イベントを、新しい順に25件ずつ明示取得。操作者・日時・変更種別・元JSONを表示し、全変更と以前の証拠を確認できる。snapshot自体に含まれない履歴も取得する。
- **ダイジェスト**: 全レーンの期限切れ・72時間以内の期限・7日以上の停滞・同レーン同名の重複候補・未反映裁定を日本語集計。タスクdone・裁定appliedを整理対象から外す。通常行の期限間近表示はデザインシステムの24時間基準。

回答・タスク変更・追記はサーバーCLIで記録する。Macはサーバーの単一書込み元設計に従い、同期で反映を確認する。

## データ保全・プライバシー

- `schema_version=1`、ID・型・必須キー・UTC日時・参照・親子循環・状態整合を検証する。
- 未知schema、同一ストアのseq減少、同seqのhash変更、同じ同期元でのstore ID変更は採用を保留する。
- 検証成功時だけ `~/Library/Application Support/TaskHubMac/snapshot-cache.json` を原子的に更新する。認証情報をcacheへ含めない。
- 取得失敗時は保存済み一覧とエラーを併記する。初回失敗と空一覧を区別する。破損cacheを黙って削除しない。
- snapshot／添付は32MiB、イベントは1MiBが取得上限。HTTPリダイレクトを拒否し、1HTTP要求とgh呼出しに30秒上限を設ける。
- 外部への投稿、リポジトリ変更、解析送信、LLM呼出し、データ削除は実装しない。
- CacheはOSユーザーのローカル領域。ディスク暗号化や同一ユーザー権限の悪意あるプロセスへの防御はOSの管理範囲。hash検証は電子署名ではない。

## テスト

```sh
# 単体・通信mock・描画テスト
swift test

# 実サーバーCLIが生成したsnapshot・全添付・全履歴との統合検証
FIXTURE="$(python3 Scripts/make-server-fixture.py)"
TASKHUB_CONTRACT_FIXTURE="$FIXTURE" swift test --filter StoreTests
# FIXTUREは検証専用の一時ディレクトリ。確認後に削除する。

# Mac実操作テスト（OSのUIテスト認証が必要な環境ではユーザーが許可）
xcodebuild -project TaskHubMac.xcodeproj -scheme TaskHubMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/taskhub-mac-ui-tests test
```

UIテストはサーバーCLIから一時データを作り、接続、検索、レーン／状態絞込み、裁定と元タスク間の遷移、同期後の回答表示、ダイジェスト、変更履歴、通信失敗後の表示、再起動cacheを操作する。Debugビルドのテスト用環境変数 `TASKHUB_TEST_CACHE` と `TASKHUB_TEST_SOURCE` で専用データを指定する。本番cacheへ触れない。

最終の実施結果・未検証範囲は [REPORT_mac.md](REPORT_mac.md) を参照する。停止条件に該当した場合は `STOP_mac.md` に再開手順を記載する。

## 構成

- `App/`: アプリ入口、単一ウインドウ、同期ショートカット。
- `Sources/TaskHubMacCore/`: snapshot契約、検索／整理、取得、キャッシュ／同期状態、検証付き履歴。
- `Sources/TaskHubMacUI/`: デザインシステムへの表示変換、一覧・詳細・接続・履歴画面。
- `Tests/TaskHubMacCoreTests/`: schema、検索、境界、transport、状態管理、サーバー連携。
- `Tests/TaskHubMacUITests/`: 表示変換・幅340／720pt、ライト／ダーク・文字サイズの描画検証。
- `Tests/ApplicationUITests/`: XcodeのMac実操作テスト。
