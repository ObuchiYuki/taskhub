# 系統1 サーバーCLI 実装結果

更新日: 2026-10-10
状態: **設計・ローカル実装・自動試験完了**。実GitHub同期とLinux本番配備は未実施。

## 成果物
- `server/DESIGN.md`: 技術選定、保存・同期プロトコル、snapshot v1の全キー・型、代替案比較、実装順序。
- `server/README.md`: 起動、全CLI操作、同期設定、Linux定期実行、容量・障害回復・保証範囲。
- `server/taskhub/`: Python 3.10以上のCLI。実行時Python依存は標準ライブラリのみ。
- `server/tests/`: 自動試験141件。
- `server/examples/snapshot.json`: 実装から生成した架空データのクライアント向けサンプル。対応添付は `server/examples/blobs/`。
- `server/examples/systemd/`: 利用者が設定して登録するLinux user service/timer例。
- `server/pyproject.toml`: パッケージ定義と `taskhub` エントリーポイント。

## 起動

```bash
cd <repo>/server
python3 -m taskhub --help
python3 -m taskhub --actor agent-a \
  --data-dir "$HOME/.local/share/taskhub-data" init
export TASKHUB_DATA_DIR="$HOME/.local/share/taskhub-data"
python3 -m taskhub --actor agent-a lane add --name TaskHub
```

初期化先は空の専用ディレクトリ。全エージェントが同じUnix UIDと同じローカルPOSIXデータディレクトリを使う。`python3 -m taskhub` はインストール不要。`taskhub` コマンドとしてのインストール方法はREADME参照。

変更時に `--actor` を必須とする。`--json` で機械処理向け応答、`--request-id UUID` で安全な再送、`--if-revision N` で古い状態からの更新を検出する。

## 実装した機能
- レーン登録・更新・一覧。正規化した同名レーンの重複を拒否する。
- ID指定のタスク登録・更新・閲覧・履歴。状態は未着手/進行中/ユーザー確認待ち/ブロック/完了/保留。
- 優先度、UTC期限、担当、十進文字列の金額と通貨、やり方、根拠、本文。任意値の解除に対応。
- 同一レーン内の親子タスク。自己参照・循環を拒否し、親子の状態を独立管理する。
- 追記専用のコメント/作業ログ。完了に非空証拠と `--verified` を要求する。再開理由と旧完了証拠も履歴に残す。
- タスクとは別のユーザー裁定リスト。依頼、選択肢、期限、理由、登録者を保存し、pending→answered→appliedを検証する。
- 回答者と代理記録者を区別する。反映証拠と任意の元タスク再開を単一イベントで確定する。
- `decision list --status pending` で今ユーザーに回答を求める項目をレーン横断表示。既定のopenはpendingとanswered。
- タスク/裁定/追記への添付。説明、ファイル名、登録者、日時、サイズ、SHA-256を記録し、同一内容を重複保存しない。
- 日本語を扱えるUnicode正規化付き全文部分一致検索。タイトル、本文、追記、裁定、証拠、添付説明・ファイル名を対象にする。レーン/状態/期間/担当で絞り込める。
- 期限切れ、72時間以内の期限、7日以上の停滞、同一レーンの正規化同名重複候補を検出し、日本語ダイジェストを生成する。閾値・基準時刻を指定できる。
- `fsck` でイベント/blob/スナップショットを検査し、`rebuild` で派生スナップショットを復元する。

## 保存・同期の判断
- 正本は追記専用の連番JSONイベント。全変更者・時刻・要求IDと、前イベントのhashを記録する。
- `fcntl.flock` でプロセス間排他。blobと必要な親ディレクトリのfsync後にイベントを原子的に公開し、その後snapshotを原子的に更新する。
- イベント確定後のsnapshot失敗は確定済みseq/対象IDを返す。再送またはrebuildで回復する。履歴欠損やhash不一致は中断する。
- SQLite正本も比較した。小規模共有CLIでは、可読な変更履歴をそのままprivate Gitで配布できるイベント正本を採用した。
- **同期はprivate GitHubを採用**。既存HTTPS認証、Git履歴、Mac/iOSからの標準HTTPS取得を共用できる。
- SSH/rsync・SMBは鍵/VPN・待受・端末到達性の運用が増え、特にiOS側の継続利用に追加構成が必要。今回の構成ではGitHubの方が運用を簡素化できる。詳細はDESIGN §11。
- 同期時はprivate状態を確認し、push直前にも再確認する。repo ID・branch・観測済みcommitを固定し、通常のfast-forward pushを使う。
- remote先行・分岐・巻戻し・既知branch消失・記録済みイベント/blobの変更は中断する。未送信ローカル履歴を保全する。
- 同期先は実行時に `sync --repo OWNER/REPOSITORY --branch main` で指定する。専用リポジトリの初回対象branchは空にする。以後は引数省略で固定済み同期先を使う。
- ネットワーク書込みは明示syncと利用者が有効化したtimerから行う。外部投稿・メール・telemetry・外部LLMへの本文送信は実装していない。

## Mac/iOS向け確定契約

入口は専用privateデータGitリポジトリ直下の **`snapshot.json`**。完全な型定義とJSON例は `server/DESIGN.md` §6。実装由来のサンプルは `server/examples/snapshot.json`。

- root: `schema_version=1`, `store_id`, `last_event_seq`, `last_event_hash`, `generated_at`, `lanes`, `tasks`, `decisions`, `comments`, `attachments`。
- 日時: ASCIIのUTC `YYYY-MM-DDTHH:MM:SSZ`。未設定はnull、任意テキストは空文字、配列は空配列。定義キーを常に出力する。
- タスク状態: `todo/in_progress/awaiting_user/blocked/done/on_hold`。優先度: `low/normal/high/urgent`。
- 裁定状態: `pending/answered/applied`。
- ID: `l_/t_/d_/c_/a_` + UUIDv4の32桁小文字hex。
- タスク金額: `{value: 十進文字列, currency: 3文字通貨コード}` またはnull。
- 完了証拠: `completion={evidence,verified_by,verified_at}`。doneの場合だけ非null。
- 裁定回答: `answer={text,respondent,recorded_by,recorded_at}`。反映記録: `application={evidence,applied_by,applied_at,resumed_task}`。
- lane/task/decision: `created_at,created_by,updated_at,updated_by,revision`。追記/添付: `created_at,created_by,event_seq`。
- 添付: `filename,description,media_type,size_bytes,sha256,blob_path`。blob_pathは `blobs/sha256/<hash先頭2桁>/<hash>`。
- commit SHAに固定してsnapshotとblobを取得し、添付サイズ/hashを照合する。同じstore_idでseq減少・同seqのhash変更を検出した場合、更新を保留する。未知schema_versionも適用を保留する。
- snapshotは最大32MiB。全変更履歴はevents配下に保存し、snapshotには現在状態と全追記を含める。
- `python3 -m taskhub snapshot` は契約JSONをそのまま出す。通常コマンドの `{ok,data,event_seq}` ラッパーは付かない。
- HTTPサーバーや独自通知サービスは設けていない。GitHub commit/ETagによる更新検知、取得周期、端末認証、OSバックグラウンド動作は各クライアントが担当する。

## 検証結果

実行環境: macOS、Python 3.10.4、Git 2.54.0。GitHub CLIの既存認証を確認した。

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
Ran 141 tests in 29.041s
OK
Python 3.10 syntax: 16 files passed
```

- CLIの別プロセス実行で、登録→状態更新→裁定登録→回答→反映/再開→添付→証拠確認付き完了→再開→履歴→検索/一覧を検証した。
- 不正入力、証拠欠落、古いrevision、再送、親循環、代理回答、全3種の添付対象、検索の日本語/全角、期間境界、日本語ダイジェストを検証した。
- 複数プロセス同時更新、同一要求の重複防止、lock timeout、イベント確定後のプロセス終了、snapshot回復を検証した。
- blob・各祖先ディレクトリのfsync障害、履歴破損/欠落、symlink/FIFO拒否、所有者/権限、容量境界、孤立blob保全を検証した。
- 実ローカルbare Gitとfake GitHub応答で、private確認、正常同期、競合/巻戻し/branch消失、再試行、認証失敗、Git設定隔離、timeout、履歴不変性を検証した。
- 設計レビュー2巡。保存ディレクトリの永続化と単一ファイル容量上限の2件を修正し、残件0で承認された。
- 実装試験で検出した保存失敗時のエラー変換、空の要求ID、symlink祖先/lock、添付上限下限を修正し再試験した。ASCII日時、容量警告、Linux keyring環境の保持、イベント固有サイズ上限も回帰試験を追加した。

## 未検証範囲・運用上の制約
- 実GitHubへの同期送信・LinuxクラウドPCへの配備・実ディスクの電源断試験は未実施。Dockerイメージ一覧の取得も失敗したため、Linuxコンテナ試験は未実施。Linux実機検証は残る。
- Mac/iOSアプリとの動的接続・端末上の自動同期は未検証。サーバー側JSONサンプルのキー・型・参照・添付hashは試験済み。
- パッケージのインストール試験とsystemd timerの実登録は未実施。モジュール起動を検証した。
- 添付は既定10MiB/件、設定可能範囲1byte〜32MiB。blob合計は最大1GiB。snapshotは絶対最大32MiBで、80%以上をstderrの `W_CAPACITY` と応答で警告する。超過する変更は確定前に拒否する。
- 同一UID・単一サーバー書込みを前提にする。NFS/SMBへの直接保存や複数サーバーの自動マージは対象外。全履歴再生により履歴量に比例して処理が増える。
- actor/回答者は申告値。本人認証や電子署名監査は提供しない。同一UIDの悪意ある操作、private確認直後のGitHub可視性変更を完全には防げない。
- 未送信データも別途バックアップする。Git履歴に全内容が残るため秘密鍵・トークンを登録しない。

## 停止条件
ローカル設計・実装・試験を妨げる技術的困難や必須のユーザー作業は発生しなかったため、`STOP_server.md` は作成していない。利用先のprivateリポジトリ・認証・データディレクトリは、実運用時のCLI設定として明示指定する。実運用の設定・接続検証を完了扱いにはしていない。
