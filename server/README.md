# TaskHub Server CLI

Linux共有サーバーで、複数のAIエージェントがタスク・ユーザー裁定・証拠を記録する。Python 3.10以上とGitを使う。実行時Python依存は標準ライブラリのみ。GitHub同期には既存のGitHub CLI (`gh`) 認証を使う。

設計とクライアントJSON契約: [DESIGN.md](DESIGN.md)。進捗・検証結果: [REPORT_server.md](../_spec/REPORT_server.md)。

## 起動

```bash
cd /path/to/taskhub/server
python3 -m taskhub --help

# 全エージェントが同じUnixユーザー・ローカルディスク上のディレクトリを使う。
export TASKHUB_DATA_DIR="$HOME/.local/share/taskhub-data"
python3 -m taskhub --actor agent-a init
python3 -m taskhub --actor agent-a lane add --name TaskHub
```

`init` は空の専用データディレクトリと専用Gitを作る。既存のファイルがあるディレクトリを拒否する。既存の空ディレクトリを渡す場合は所有者限定の0700にする。データディレクトリ内へソース・メモ・バックアップを追加しない。

CLIの戻り値はJSON。通常は整形表示、`--json` は機械処理向けの1行JSON。`digest` は通常、日本語テキストを出す。共通オプションはサブコマンドの前後で指定できる。

- `--data-dir PATH` または `TASKHUB_DATA_DIR`: 保存先を明示。
- `--actor NAME`: 変更者を必ず指定。名前は申告値で、本人認証の機能は持たない。
- `--request-id UUID`: タイムアウト後の再送で同じIDを使う。同じ要求・actorなら重複登録しない。異なる要求での再利用は拒否する。
- `--if-revision N`: 読取時のrevisionと一致した場合だけ変更。追記・添付は対象タスク/裁定、追記への添付は追記元タスク/裁定のrevisionを比較する。
- `--lock-timeout SECONDS`: 排他ロック待機上限。既定30秒。

任意で `python3 -m pip install --no-build-isolation --no-deps .` により `taskhub` コマンドを登録できる。インストールにはsetuptools 61以上が必要。モジュール起動はインストール不要。

## タスクの運用

以下の `LANE_ID`、`TASK_ID` などは直前の応答の `data.id` に置き換える。

```bash
python3 -m taskhub --actor agent-a task add --lane LANE_ID \
  --title '依頼を記録する' --body '依頼内容' --priority high \
  --due-at 2026-10-11T09:00:00Z --assignee agent-a \
  --amount 1500.00 --currency JPY --method '手順' --rationale '判断根拠'
python3 -m taskhub --actor agent-a task update TASK_ID --status in_progress
python3 -m taskhub --actor agent-a comment add --task TASK_ID --body '作業ログ'
python3 -m taskhub --actor agent-a task complete TASK_ID --evidence '検証結果と確認内容' --verified
python3 -m taskhub task show TASK_ID
python3 -m taskhub task history TASK_ID
```

状態は `todo/in_progress/awaiting_user/blocked/done/on_hold`。完了には非空の証拠と `--verified` が必須。確認作業そのものは実行者が行う。CLIは入力の有無を検証し、証拠の真偽までは判断しない。

- 子タスク: `task add --lane LANE_ID --title '子' --parent TASK_ID`。親子は同一レーン、循環禁止。親子の状態は独立。
- 属性変更: `task update TASK_ID --priority urgent --if-revision 12`。
- 値の解除: `task update TASK_ID --clear due_at --clear assignee --clear amount --clear parent`。
- 完了後の追加作業: `task reopen TASK_ID --reason '追加依頼'`。旧完了証拠は履歴に残る。
- タスク削除・追記編集・履歴上書きのコマンドは提供しない。完了後も追記・添付を追加できる。
- 期限は秒精度UTCの `YYYY-MM-DDTHH:MM:SSZ`。ローカル日付はUTCへ変換して指定する。
- `--body-file`、`--evidence-file`、`--answer-file` でUTF-8通常ファイルを読める。対応する直接値と同時指定できない。

## ユーザー裁定

```bash
python3 -m taskhub --actor agent-a task update TASK_ID --status awaiting_user
python3 -m taskhub --actor agent-a decision add --task TASK_ID \
  --title '方式を選んでほしい' --body '決めてほしい内容' \
  --option '方式A' --option '方式B' --reason '本人判断が必要' \
  --due-at 2026-10-12T09:00:00Z
python3 -m taskhub decision list --status pending
python3 -m taskhub --actor recorder decision answer DECISION_ID \
  --answer '方式Aを採用' --respondent user
python3 -m taskhub --actor agent-a decision apply DECISION_ID \
  --evidence '設定を方式Aへ変更し確認した' --resume
python3 -m taskhub decision history DECISION_ID
```

`pending → answered → applied` の順に遷移する。回答者 (`respondent`) と記録者 (`recorded_by`) は別に保存する。`--resume` は元タスクがblocked/awaiting_userのときだけin_progressへ戻し、裁定反映と同じイベントで確定する。回答を記録しただけではタスク状態を変えない。

`decision list` は未反映 (`open`: pendingとanswered) をレーン横断表示する。今ユーザーに回答を求める項目には `--status pending` を使う。`--lane LANE_ID` で絞り込める。

## 添付

```bash
python3 -m taskhub --actor agent-a attachment add --task TASK_ID \
  --file /path/to/result.png --description '確認画面'
python3 -m taskhub --actor agent-a attachment add --decision DECISION_ID \
  --file /path/to/options.pdf --description '比較資料'
python3 -m taskhub --actor agent-a attachment add --comment COMMENT_ID \
  --file /path/to/test.log --description '検証ログ'
```

通常ファイルのみ受け付け、symlink・FIFO・deviceを拒否する。内容SHA-256で重複保存を避け、説明・ファイル名・登録者・日時を保存する。ファイル内容の実行・OCRは行わない。

既定上限は1件10MiB、全blob合計1GiB。`.taskhub/config.json` の `max_attachment_bytes` を1byte〜32MiB、`max_total_blob_bytes` を0〜1GiBに設定できる。32MiBは添付1件とsnapshotの絶対上限。snapshotが上限80%以上ならCLIがstderrへ `W_CAPACITY` と使用量を出し、変更応答と `fsck` にも `capacity_warning: true` を返す。上限超過の変更はイベント確定前に拒否し、既存データの読取・同期を維持する。容量増大時は分割配布を別途設計する。

## 検索・自動整理

```bash
python3 -m taskhub task list --lane LANE_ID --status in_progress --assignee agent-a
python3 -m taskhub search '検証' --lane LANE_ID \
  --since 2026-10-01T00:00:00Z --until 2026-11-01T00:00:00Z
python3 -m taskhub digest --upcoming-hours 72 --stale-days 7
python3 -m taskhub --json digest --now 2026-10-10T12:00:00Z
```

タイトル・本文・追記・裁定の選択肢/理由/回答/反映証拠・完了証拠・添付の説明/ファイル名をUnicode正規化付き部分一致で検索する。日本語・全角英数字を扱う。期間は対象の最終更新日時 `[since, until)`。裁定の担当フィルタには元タスクの担当を使う。

ダイジェストは期限切れ・期限間近・停滞・同一レーンの正規化同名重複候補・未反映裁定を日本語で要約する。外部LLMへの送信は行わない。定期実行すると整理結果を継続取得できる。整理結果によるタスク変更・統合は行わない。

## private GitHub同期

実行前提: 指定するprivateリポジトリを利用する権限、`gh auth status` で確認できる既存認証、GitHubへHTTPS接続できる環境。CLIはアカウントやリポジトリを作成しない。

```bash
python3 -m taskhub --actor sync-agent sync --repo OWNER/REPOSITORY --branch main
python3 -m taskhub sync-status
# 初回指定が保存された後
python3 -m taskhub --actor sync-agent sync
```

- 同期は明示コマンドで実行。private確認に失敗したら送信を止める。push直前もprivate確認する。
- 対象はGitHub.comの `OWNER/REPOSITORY`。任意URL・SSH接続先を入力できない。
- 専用リポジトリを使い、初回は対象branchを空にする。GitHub側でREADME等を初期作成すると未知の履歴として拒否する。
- 同一共有サーバーを唯一の書込み元とする。remote先行・分岐・巻戻し・既知branch消失は中断し、ローカル変更を保全する。
- GitHub側のリポジトリID・branch・観測済みcommitを固定する。同期先変更は管理者による別データ領域への計画的切替として扱う。
- 通常のfast-forward pushだけを使う。変更履歴・blobを不変として検査し、snapshotを生成してcommitする。
- 一時的なpush失敗は最大3回。毎回privateと履歴条件を再検査。外部コマンドは最大30秒、同期全体180秒。
- 資格情報は既存ghから取得。データ、snapshot、ログにトークンを保存しない。Gitのグローバル設定を変更しない。
- リポジトリの可視性変更とforce pushを運用で禁止する。可視性チェック直後の管理者操作との競合は完全防止できない。

SSH/rsync・SMBは鍵/VPN・待受・iOS到達性の運用が増える。今回のprivate GitHub配布は既存HTTPS認証と履歴を共用できる。比較の詳細はDESIGN §11。

## Mac/iOSへの配布

`python3 -m taskhub snapshot` はJSON契約そのものをstdoutへ出す。通常コマンドの応答ラッパーを含まない。読み取り入口はデータGitリポジトリ直下の `snapshot.json`。

クライアントは更新先commit SHAを取得し、そのSHAに固定してsnapshotとblobを読む。schema_version・store_id・seq/hash・参照整合性を確認してcacheを置換する。同一store_idのseq減少・同seqのhash変更は採用を保留する。未知versionも保留する。GitHubへのpush検知方法、取得周期、バックグラウンド動作はクライアント担当。契約の全キー・型はDESIGN §6。実装から生成した架空データは [examples/snapshot.json](examples/snapshot.json)、対応する添付は `examples/blobs/`。これらはクライアントの読取り検証に使える。

## Linux定期実行（任意）

[examples/systemd](examples/systemd) にuser service/timer例を置いた。`WorkingDirectory`、Python/ghのPATH、data-dirを環境に合わせて設定してから、利用者が登録する。CLIは自動登録しない。

```bash
systemctl --user daemon-reload
systemctl --user enable --now taskhub-sync.timer
systemctl --user list-timers taskhub-sync.timer
journalctl --user -u taskhub-sync.service
```

ログには成功/失敗と同期状態が出る。ユーザーサービスをログアウト後も継続するにはホスト側の運用設定が必要。digestもcron/systemdから実行し、出力をprivateなローカルファイルへ保存できる。

## 検査・障害回復

```bash
python3 -m taskhub fsck
python3 -m taskhub rebuild
```

イベントとblobが正本。snapshot書込み失敗後も確定イベントを保全する。`E_COMMITTED_VIEW_STALE` の `committed_event_seq` と対象IDを確認し、`rebuild` または同じrequest-idで再送する。snapshotだけの欠落・古さは次の読取りでも再生成する。

`E_INTEGRITY` では正本の欠損・改変や権限異常を調べる。履歴の欠番、hash不一致、先行snapshotは自動修正しない。正常なバックアップを**別の0700ディレクトリ**へ復元し、`fsck` 成功後にdata-dirを切り替える。元のストアは調査用に保持する。孤立blobは `fsck` に表示し、容量へ計上する。

バックアップはLinuxの `flock` で `.taskhub/lock` を取得してからデータディレクトリ全体を保存する。出力先をデータ領域外に置き、0700/0600を保つ。ローカル同期状態 `.taskhub/sync-state.json` も保全する。GitHub副本にあるのは送信済み履歴だけ。未送信分も別途バックアップする。

GitHubのコピーから復旧する場合も新規領域を使い、private確認・権限確認・イベント/blob検査を行う。ローカル同期pinを失った場合、過去に観測したremoteの巻戻し検知は復元できない。復旧後の単一書込み元を管理者が明確にして切り替える。

終了コード: `0` 成功、`2` 入力/設定/状態、`3` revision/履歴競合またはlock timeout、`4` 整合性/確定後snapshot失敗、`5` 認証/同期/外部timeout。

## 検証

```bash
python3 -m unittest discover -s tests -v
```

ローカルCLI、状態遷移、検索、並行書込み、障害注入、容量境界、ローカルbare Gitとfake GitHub応答を検証する。テストは実GitHubへ送信しない。実Linuxストレージの電源断耐性、実GitHub配備、Mac/iOS実機との自動同期は別途検証対象。

## 保証範囲

同一Unix UID・ローカルPOSIXディスク・単一サーバー書込みを前提にする。データ権限は0700/0600。NFS/SMB上の直接更新、複数サーバーの自動マージは対象外。全イベントを毎回読み直すため、履歴増大に伴い処理時間が増える。

全変更はGit履歴にも残る。秘密鍵・トークン・不要な個人情報を登録しない。同一UIDの悪意あるプロセスへの保護や電子署名監査は提供しない。データはprivateリポジトリの権限を持つ利用者が読める。
