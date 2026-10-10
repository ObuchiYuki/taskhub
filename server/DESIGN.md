# TaskHub Server 設計 v1

## 1. 対象・目的
- 根拠: `../_spec/SPEC.md`。初稿着手時の `server/` は空で、既存実装・review_file はなかった。
- 複数AIエージェントが共有Linux上で依頼を記録し、履歴・証拠を残し、ユーザー裁定を回収するCLIを作る。
- 本設計の対象は系統1とMac/iOS向け読み取り契約。クライアント実装、アカウント作成、リポジトリ作成、デプロイは対象外。
- GitHub設定なしでもローカル操作・テストは全機能使用可能。同期実行だけに既存privateリポジトリと認証を要求する。
- 日本語進捗・結果は親エージェントが `../_spec/REPORT_server.md` に記録する。現時点で実装を止める技術的阻害要因はない。

## 2. 構成と前提
- Python 3.10+、実行時は標準ライブラリのみ。起動基準は `python3 -m taskhub`。以下では `taskhub` と略記する。
- モジュールをCLI、ドメイン/reducer、イベントストア、検索/整理、GitHub同期に分離する。Webサーバー・DBサーバー・常駐プロセスは不要。
- 全エージェントが同一Unix UID・同一の明示的データディレクトリを使う。ローカルPOSIXファイルシステムを前提とし、NFS/SMB上の直接書き込みは非対応。
- データディレクトリだけを専用Gitリポジトリにする。ソースリポジトリや利用者の既存作業ツリーをデータ置場として使わない。
- 正本は単一サーバーの順序付きイベント列。GitHubはprivateな配布・バックアップ先、Mac/iOSは読み取り専用。多拠点書き込み・自動マージは実装しない。
- `fcntl.flock(LOCK_EX)` を全CLI読書き・同期で取得する。読取時のsnapshot修復も排他範囲内。待機上限とネットワーク上限を設け、無期限停止を避ける。

## 3. 保存構造・イベント
- データ直下: `manifest.json`、`events/00000000000000000001.json`、`snapshot.json`、`blobs/sha256/ab/<64桁sha256>`、`.git/`、`.taskhub/`。
- `manifest.json` は不変の `{schema_version: 1, store_id: UUID文字列, created_at: UTC日時}`。空ストアのsnapshotも作る。
- `.taskhub/` 内に固定inodeの `lock`、ローカル設定、同期状態、作業用tempを置く。Git登録しない。lockは置換・削除しない。
- Git登録対象はmanifest、確定イベント、blob、snapshotだけ。CLIは対象パスを列挙してstageし、`git add .` は使わない。
- イベントはUTF-8 JSONの `{schema_version, seq, id, request_id, request_hash, actor, occurred_at, prev_hash, type, payload}`。`seq` は1始まり連続整数、`id` はUUID。
- `request_id` はUUID、`request_hash` は正規化した要求のSHA-256。`prev_hash` は直前イベントの保存済みバイト列のSHA-256、先頭のみnull。
- イベントJSONはキー順固定・余分な空白なし・末尾LFで保存する。イベントファイルは作成後一切変更しない。未知version/type、欠番、重複ID、hash不一致は停止する。
- 型は `lane.created/updated`、`task.created/updated/completed/reopened`、`comment.added`、`decision.created/answered/applied`、`attachment.added`。
- payloadは各コマンドの正規化入力と割当ID。reducerは過去状態・actor・occurred_atから決定的に状態を作り、入力時とreplay時に同じドメイン制約を検証する。
- `decision.applied` の裁定変更と任意のタスク再開は単一イベント。snapshotを書換えるだけの変更経路や削除イベントは用意しない。

## 4. 書込み手順・クラッシュ回復
1. 排他lock取得。manifestとイベント列をreplayし、参照・状態・連番・hashを検証する。snapshotは正本として信用しない。
2. actor、要求、参照整合性を検証する。添付は同一ファイルシステムのtempへストリーム読込しhash/サイズを確定する。reducer適用後のイベントバイト列/hashとsnapshotをメモリ上で生成し、§6のサイズ上限を検査する。超過は `E_CAPACITY` とし、blob・イベントを公開せず既存状態を保つ。
3. 添付tempを `fsync` 後、最終blob名へ上書きなしで公開する。新規mkdirによる親エントリを含め、prefix→sha256→blobs→data-dirの順で全ディレクトリを `fsync` する。initでdata-dir自体を新設した場合はその親も永続化する。blobへの全パスのfsync成功をイベント公開の前提とし、いずれか失敗ならイベント未確定のまま停止する。
4. イベントtempを書き `fsync`。hard link等の上書きしない原子的公開で最終名を作り、eventsディレクトリを `fsync`。ここが論理コミット点。
5. 手順2で検査した同一snapshotバイト列をtempへ書き `fsync`、`os.replace`、親ディレクトリを `fsync`。成功応答は最後に出す。
- 確定名になる前のtempは読まない。blobだけ残る事故は孤立blobとして検出し、容量に計上する。自動削除しない。
- イベント確定後のsnapshot失敗はイベントを取り消さない。`E_COMMITTED_VIEW_STALE` と確定seq/対象IDを返す。次回CLI読取または `rebuild` がsnapshotを復元する。
- 確定イベントの破損・欠落、参照blobの欠落/不一致は自動修正せず `E_INTEGRITY`。正常なバックアップから別ディレクトリへ復旧する。
- 既存snapshotのseqがイベント列より先、または同seqでhash不一致なら、末尾欠落/改変の疑いとして停止する。古いsnapshotの修復と、正本の巻戻しを混同しない。
- ドメイン変更コマンドは `--request-id UUID` に対応する。同一actor・request_id・要求なら元のseq/対象IDを返し、異なる要求なら拒否する。未指定時はCLIが生成する。
- request_hashは自動生成ID・実行日時を除く要求を対象にする。添付要求には内容hashを含める。タイムアウト後の安全な再実行には呼出元がrequest_idを固定する。
- `fsck` は全イベントreplay・全blobのhash/サイズ・snapshot一致・余分なファイルを検査する。通常読取はblobの存在/サイズを検証し、hash全読込は追加時・fsck・同期時に行う。

## 5. ドメイン制約
- すべての変更に非空の `--actor` を必須とし、OSユーザー名から暗黙補完しない。actorは監査ラベルであり、認証・電子署名ではない。
- レーンは不変IDと変更可能な名前/説明を持つ。NFKC+casefold後の同名レーンを禁止する。レーンは削除しない。
- タスク状態は `todo`（未着手）、`in_progress`（進行中）、`awaiting_user`（ユーザー確認待ち）、`blocked`（ブロック）、`done`（完了）、`on_hold`（保留）。
- 作成時はtodo。通常状態間は明示更新可能。doneへは `task complete --evidence TEXT --verified` のみ。非空証拠と明示確認を必須とし、確認者/時刻を記録する。
- 完了済みタスクの属性変更は先に `task reopen --reason TEXT` でtodoへ戻す。completionをnullにするが旧証拠は履歴に残す。追記・添付は完了後も許可する。
- 親は同じレーンの既存タスクのみ。自己参照・循環を拒否する。作成後のlane_id変更はv1非対応。親子の状態は独立し、自動完了・自動再開しない。
- 属性はtitle、body、priority、due_at、assignee、amount、method、rationale。priorityは `low/normal/high/urgent`、既定値normal。金額は非負の十進文字列と通貨コードで保持し、浮動小数点にしない。
- actor/回答者は制御文字なし・UTF-8で1〜128byte、name/titleは空白だけを禁止し1〜512byte。必須の証拠・回答・理由・本文も空白だけの値を拒否する。
- 裁定は必ず既存のlane/taskに紐づく別エンティティ。lane_idは元タスクと一致する。依頼内容、選択肢、期限、理由、登録者を保存する。
- 裁定状態は `pending → answered → applied` の一方向。回答は本文・回答者・記録者・記録日時を保存する。代理入力と本人の回答を混同しない。
- `decision apply --evidence TEXT [--resume]` はansweredだけに許可する。--resumeは元タスクがblocked/awaiting_userの場合だけin_progressへ変更し、それ以外なら全体を拒否する。
- 裁定登録/回答だけではタスク状態を変えない。反映済み裁定の修正は追記と新しい裁定で残す。追記も変更・削除しない。
- 追記の対象はtask/decision、添付の対象はtask/decision/comment。参照先は既存必須。追記・添付追加で対象task/decisionのupdated_at/updated_by/revisionも進める。
- `--if-revision N` を任意の既存エンティティ更新で指定できる。不一致は `E_CONFLICT`。lockだけでは防げない古い画面/判断による上書きを検出する。

## 6. 安定した読み取りJSON契約
- 公開パスは専用データGitリポジトリ直下の **`snapshot.json`**。HTTPサービスやクライアント書込みAPIは設けない。
- snapshotは保存時のUTF-8シリアライズ済みバイト列（末尾LF込み）で絶対上限32MiB（33,554,432byte）。設定による引上げは不可。上限以下は許可し、80%以上ならCLI読取/変更/sync時に `W_CAPACITY` と使用量をstderrへ出す。超過する変更はイベント確定前に `E_CAPACITY` で拒否する。既存データの読取・同期は継続でき、切捨て・削除・自動分割はしない。
- JSONはUTF-8、`schema_version: 1`。全定義キーを常に出し、未設定はnull、空リストは[]、任意テキストは空文字にする。日時はUTCの `YYYY-MM-DDTHH:MM:SSZ`、日付だけの入力は拒否する。
- root: `schema_version: integer`、`store_id: string(UUID)`、`last_event_seq: integer >= 0`、`last_event_hash: string(64桁小文字hex)|null`、`generated_at: string|null`、下記5配列。
- generated_atは最終イベントのoccurred_at、空ストアのみnull。rebuildで変えない。表示順や更新検知に壁時計ではなくseqを使う。
- IDは型接頭辞 `l_/t_/d_/c_/a_` とUUIDv4の32桁小文字hex。参照先の型も検証する。store_idが違えば別データ、同一store_idのseq減少は巻戻りとして扱う。
- lane/task/decision共通: `id:string, created_at:string, created_by:string, updated_at:string, updated_by:string, revision:integer>=1`。revisionはそのエンティティに影響した最新イベントseq。
- `lanes: array<共通 + {name:string, description:string}>`。
- `tasks: array<共通 + {lane_id:string, parent_id:string|null, title:string, body:string, status:enum, priority:enum, due_at:string|null, assignee:string|null, amount:Money|null, method:string, rationale:string, completion:Completion|null}>`。
- Money: `{value:string, currency:string}`。valueは `^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$`、currencyは `[A-Z]{3}`。換算・税込計算はしない。
- Completion: `{evidence:string, verified_by:string, verified_at:string}`。doneと非null completionは同値。verified_byは完了イベントのactor。
- `decisions: array<共通 + {lane_id:string, task_id:string, title:string, body:string, options:array<string>, reason:string, due_at:string|null, status:pending|answered|applied, answer:Answer|null, application:Application|null}>`。
- Answer: `{text:string, respondent:string, recorded_by:string, recorded_at:string}`。Application: `{evidence:string, applied_by:string, applied_at:string, resumed_task:boolean}`。
- pendingはanswer/application=null、answeredはanswerのみ非null、appliedは両方非null。
- `comments: array<{id:string, target_type:task|decision, target_id:string, body:string, created_at:string, created_by:string, event_seq:integer}>`。
- `attachments: array<{id:string, target_type:task|decision|comment, target_id:string, filename:string, description:string, media_type:string, size_bytes:integer>=0, sha256:string, blob_path:string, created_at:string, created_by:string, event_seq:integer}>`。
- blob_pathは必ず `blobs/sha256/<sha256先頭2桁>/<sha256>`。相対POSIXパスでありURLではない。filenameは表示専用。snapshotに外部URLや認証情報を含めない。
- lanes/tasks/decisionsはid昇順、comments/attachmentsは `(event_seq,id)` 昇順。全追記を含むが全変更履歴は含めない。監査履歴はeventsとCLI historyで読む。
- 未知の追加キーはクライアントが無視できる。既存型・必須キー・enumの意味変更はschema_versionを上げる。未知versionは更新を適用せず、最後の対応済み表示とエラーを残す。

### JSON例（1タスク、回答・反映済み裁定、追記、空ファイル添付）
```json
{
  "schema_version": 1,
  "store_id": "12345678-1234-4234-8234-123456789abc",
  "last_event_seq": 8,
  "last_event_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "generated_at": "2026-10-10T12:07:00Z",
  "lanes": [{
    "id": "l_11111111111141118111111111111111", "name": "TaskHub", "description": "共同開発",
    "created_at": "2026-10-10T12:00:00Z", "created_by": "agent-server",
    "updated_at": "2026-10-10T12:00:00Z", "updated_by": "agent-server", "revision": 1
  }],
  "tasks": [{
    "id": "t_22222222222242228222222222222222", "lane_id": "l_11111111111141118111111111111111",
    "parent_id": null, "title": "CLI検証", "body": "ローカル環境で要件を確認する。", "status": "done",
    "priority": "high", "due_at": "2026-10-11T09:00:00Z", "assignee": "agent-server",
    "amount": {"value": "0", "currency": "JPY"}, "method": "unittest", "rationale": "外部公開しない。",
    "completion": {"evidence": "全テスト成功。追記の実行記録を確認。", "verified_by": "agent-server", "verified_at": "2026-10-10T12:07:00Z"},
    "created_at": "2026-10-10T12:01:00Z", "created_by": "agent-server",
    "updated_at": "2026-10-10T12:07:00Z", "updated_by": "agent-server", "revision": 8
  }],
  "decisions": [{
    "id": "d_33333333333343338333333333333333", "lane_id": "l_11111111111141118111111111111111",
    "task_id": "t_22222222222242228222222222222222", "title": "検証範囲", "body": "今回はローカル検証でよいか。",
    "options": ["ローカルのみ", "配備も実施"], "reason": "配備は今回の依頼範囲外。", "due_at": null, "status": "applied",
    "answer": {"text": "ローカルのみ", "respondent": "yuki", "recorded_by": "agent-server", "recorded_at": "2026-10-10T12:03:00Z"},
    "application": {"evidence": "外部接続なしで検証する手順を選択。", "applied_by": "agent-server", "applied_at": "2026-10-10T12:04:00Z", "resumed_task": false},
    "created_at": "2026-10-10T12:02:00Z", "created_by": "agent-server",
    "updated_at": "2026-10-10T12:04:00Z", "updated_by": "agent-server", "revision": 5
  }],
  "comments": [{
    "id": "c_44444444444444448444444444444444", "target_type": "task", "target_id": "t_22222222222242228222222222222222",
    "body": "検証コマンド終了コード0。標準エラーは空。", "created_at": "2026-10-10T12:05:00Z", "created_by": "agent-server", "event_seq": 6
  }],
  "attachments": [{
    "id": "a_55555555555545558555555555555555", "target_type": "comment", "target_id": "c_44444444444444448444444444444444",
    "filename": "stderr.txt", "description": "検証時の標準エラー", "media_type": "text/plain", "size_bytes": 0,
    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "blob_path": "blobs/sha256/e3/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "created_at": "2026-10-10T12:06:00Z", "created_by": "agent-server", "event_seq": 7
  }]
}
```
- 例のlast_event_hashだけは説明用の値。実データではイベント8の保存バイト列から計算する。
- クライアントは設定済みrepo/branchのcommit SHAを確認し、そのSHAのsnapshotとblobを取得する。GitHub Contents APIのraw応答を利用できる。添付はサイズ/hashを検証し実行しない。
- 更新検知はcommit SHA/ETagで行い、snapshot内store_id/seq/hashも確認する。同じseqでhash変更、seq減少、参照不整合は採用しない。成功時だけローカルcacheを原子的に置換する。
- サーバーはGitHub push以外の通知を送らない。Mac/iOSの取得周期・バックグラウンド制約は各系統が担当し、リアルタイム通知保証は提供しない。

## 7. CLI契約
- 共通: `--data-dir PATH`（省略時は `TASKHUB_DATA_DIR`、両方なければエラー）、変更時 `--actor NAME`、`--json`、`--lock-timeout SECONDS`。デフォルトのlock待機は30秒。
- `init [--repo OWNER/NAME] [--branch main]`: 空ディレクトリにローカルストア/Gitを初期化する。ネットワーク接続・リポジトリ作成はしない。
- `lane add --name TEXT [--description TEXT]`、`lane update ID ...`、`lane list`。
- `task add --lane ID --title TEXT [--body TEXT] [--parent ID]`、`task update ID`、`task show ID`、`task list`、`task history ID`。
- task add/updateの属性: `--title`、`--body`、`--priority`、`--due-at`、`--assignee`、`--amount/--currency`、`--method`、`--rationale`。updateは `--status`、`--parent` にも対応。null化は `--clear parent|due_at|assignee|amount` を使い、設定との併用を拒否する。
- `task complete ID --evidence TEXT --verified`、`task reopen ID --reason TEXT`。done指定による完了ゲート迂回は拒否する。
- `comment add --task ID|--decision ID --body TEXT`。対象は排他的に1つ。body/evidence/answerを取るコマンドはそれぞれ `--body-file/--evidence-file/--answer-file` も受け付け、直接値との併用を拒否して通常ファイルをUTF-8で読む。
- `decision add --task ID --title TEXT --body TEXT --reason TEXT [--option TEXT ...] [--due-at UTC]`。
- `decision answer ID --answer TEXT --respondent NAME`、`decision apply ID --evidence TEXT [--resume]`、`decision show ID`、`decision history ID`、`decision list [--status pending|answered|applied|open]`。openは未反映2状態。
- `attachment add --task ID|--decision ID|--comment ID --file PATH --description TEXT`。ファイル名はsourceのbasenameを記録する。
- `search QUERY`、`digest [--now UTC] [--upcoming-hours 72] [--stale-days 7]`。list/search共通フィルタは `--lane`、`--status`、`--since`、`--until`、`--assignee`。
- `snapshot`、`rebuild`、`fsck`、`sync [--repo OWNER/NAME] [--branch main]`、`sync-status`。snapshotはv1 JSONをそのままstdoutに出す。
- 通常の--json応答は `{ok:true,data:...,event_seq:N}`、失敗は `{ok:false,error:{code,message,committed_event_seq:null|N}}`。診断はstderr、秘密を含めない。
- 終了コード: 0成功、2入力/設定/遷移/容量エラー、3競合/lock timeout、4整合性または確定後snapshot失敗、5認証/同期失敗。失敗で例外スタックを通常表示しない。

## 8. 検索・日本語ダイジェスト
- 外部検索エンジンなし。NFKC+casefoldしたUnicode部分一致でtitle/body/comment、裁定の選択肢/理由/回答/反映証拠、添付filename/descriptionを走査する。バイナリ内容・OCRは対象外。
- 検索結果はtask/decision単位に集約し、一致した追記/添付IDとフィールドを返す。裁定一致は裁定として返し、元タスクとの関連を残す。
- 期間はエンティティupdated_atについて `[since,until)`。裁定の担当フィルタは元タスクのassigneeを使う。状態語は対象種別と照合し、未知状態を拒否する。
- 整理は読み取り専用。期限切れはdue_at < now、間近はnow <= due_at <= now+72時間、停滞はupdated_at <= now-7日。タスクdone・裁定appliedは対象外。
- 重複候補は同一レーン内の未完了タスクで、NFKC+casefold+連続空白圧縮したtitleが一致する組。推測的な意味検索・自動統合はしない。
- 「期限切れ」「期限間近」「停滞」「重複候補」「ユーザー裁定」の固定順で日本語要約を出す。各項目は期限（null最後）→ID順、ゼロ件も件数を表示する。
- `--now` と同じイベント列なら出力は完全に同じ。期限間近/停滞の閾値は非負整数に限定する。LLMや外部サービスに本文を送らない。

## 9. 添付・セキュリティ・プライバシー
- 初期化時 `umask 077`、ディレクトリ0700、ファイル0600。広い権限・非所有データ領域は黙認しない。複数UID共有はv1の保証外。
- sourceは明示指定された通常ファイルのみ。`O_NOFOLLOW` と `fstat` を使い、symlink、device、FIFO、directoryを拒否する。読取後もサイズ変化を検出する。
- データ配下のsymlink・想定外パスを拒否し、ID/hashからパスを構築する。元ファイル名を保存先に使わず、制御文字・区切り文字を含む表示名も拒否する。
- 添付上限は1ファイル10MiB、ユニークblob合計1GiBを初期値とし、ローカル設定で変更可能。ただし1ファイルの設定値は1byte〜32MiB、実ファイルも絶対最大32MiBで、超過設定を拒否する。stream中にも上限を検査する。既存hashはサイズ/hash確認後に再利用する。
- 本文系フィールドは各64KiB、イベント全体1MiB、表示ファイル名はUTF-8で255byteを上限とする。media_typeは推定メタデータであり安全性の保証ではない。
- 認証情報は保存/出力しない。既存 `gh` credentialをGit credential helperとして使い、shell=Falseのargv呼出しを徹底する。利用者入力をshellやGitオプションへ展開しない。
- 公開リポジトリへの送信、issue/comment/メール投稿、telemetry、外部LLM呼出しはない。明示syncと利用者が有効化したtimerだけがネットワーク書込みを行う。
- privateは暗号化・完全なアクセス制御の代替ではない。Git履歴に全内容が残るため、秘密鍵・トークン・不要な個人情報を登録しない。blob/履歴の削除や秘密抹消はv1非対応。
- actor/回答者は申告値。同一UIDの悪意あるプロセスによる改竄や窃取は防げない。hash列は事故検出であり署名付き監査ではない。

## 10. GitHub同期プロトコル
1. lock取得、イベント/blob検証、snapshot修復。固定のHTTPS GitHub.com repoとbranchを検証する。URL・任意host・不正ref・オプション風入力は受け付けない。
2. `gh api --hostname github.com repos/OWNER/NAME` でprivate=trueとリポジトリIDを確認する。未認証/未設定/存在しない/publicなら送信せず、具体的な設定方法を示す。repo IDとbranchをpinし、以後の変更を拒否する。
3. 明示refをfetchする。保存済みlast_remote_commitが取得tipの祖先でなければ履歴巻戻し/書換えとして停止する。既知branchの消失やrepo ID変更も停止する。
4. 取得tipがlocal HEADの祖先であることを要求する。未知のremote先行・分岐は停止する。初回の空remote branchだけは作成可能。local HEAD未作成ならremote branchも未作成の場合だけ続行する。
5. 前回Git記録済みmanifest/events/blobが不変であることを確認する。全stage候補を種類別上限（snapshot/blobは32MiB以下、イベント1MiB以下、その他も絶対最大32MiB）で検査し、超過なら `E_CAPACITY` でcommit/pushせず停止する。検査済みの専用作業ツリー変更だけをcommitする。authorは明示actor、emailは固定の `taskhub@localhost`。global Git設定は変更しない。
6. push直前にもprivate確認を行い、通常のnon-force pushで設定branchへ送る。成功または既に同じcommitなら同期状態を原子的に保存する。force、rebase、merge、resetは行わない。
- 初回remote tipとlocalに祖先関係がなければエラー。ローカル作業継続は可能。既存remoteの復旧は空の別ディレクトリを使う管理者作業であり、syncの暗黙pullにしない。
- push拒否/一時通信失敗は最大3回、再試行前にprivate/ref/祖先条件を再検証する。分岐・巻戻しを検出した時点で即停止し、無条件再試行しない。
- 外部コマンドは1回30秒、sync全体180秒を上限とする。対話プロンプト・Git hooks・自動署名を無効化し、credential helperは固定文字列で指定する。
- Git subprocessはsystem/global設定と継承された追加Git設定を無効化し、URL書換えや任意helperの混入を避ける。ghの既存認証ストアは利用する。`.taskhub/` はローカルの `.git/info/exclude` に登録する。
- `.taskhub/sync-state.json` にrepo ID、branch、最後に確認したremote commit、同期成功時刻を保存する。認証secretは含めない。sync-statusは正規データパスだけの未送信有無と最終成功をローカル表示する。
- GitHubでprivate確認直後に可視性を変えられる競合や、観測の間に消えた一時的履歴改変は完全検出できない。管理者はrepoの可視性変更とforce pushを禁止する。

## 11. 選択肢比較
- **SQLite正本 + JSON export**: トランザクション・索引が強い。一方DBバイナリのGit履歴は変更監査に不向きで、読める監査exportを別途必要とする。小規模共有CLIでは直接履歴を配布できるイベント正本を選ぶ。
- **単一JSONを直接更新**: 実装最小だが全変更履歴と証拠の不変性が弱い。バックアップ差分だけで監査しないため不採用。
- **HTTPS API + PostgreSQL**: 多拠点書込み・認証・大規模検索には適する。常駐運用、TLS、資格情報、iOS同期が増えるため現段階では不要。
- **SSH/rsyncまたはSMB**: GitHub依存を減らせるが、待受公開・鍵/VPN・端末到達性が必要。特にiOS常時接続と権限管理が重い。SMB上の直接イベント更新もしない。
- **private GitHub配布（採用）**: 既存gh認証、変更履歴、標準HTTPSの読み取りが利用できる。代償は全履歴増大、同期遅延、GitHubへの機密データ保管。SSH方式は閉域運用要求が出た時に再検討する。

## 12. 運用・テスト・段階導入
- 運用順は「task add→作業→追記/状態更新→証拠確認→complete」。裁定はdecision list --status openでレーン横断確認する。
- 定期同期は利用者が選んでsystemd user timerを設定する。専用data-dirとactorでsyncを起動し、失敗はjournalで確認する。CLI自身はtimerを勝手に登録しない。
- バックアップはlock下でデータディレクトリとローカル同期pinを保全する。private GitHubは送信済みデータだけの副本であり、未送信イベントの唯一のバックアップにしない。
- 復旧はprivate確認済みGitコピー/バックアップを新規0700ディレクトリへ展開し、fsck/rebuild後にdata-dirを明示切替する。既存正本を上書きしない。pin紛失時は過去のremote書換え検出を保証できない。
- stdlib unittestで状態遷移、親循環、必須証拠/確認、回答者履歴、再開の原子性、添付全対象、Unicode検索、絞込み、固定時刻digestを検証する。
- 別プロセス同時更新、各fsync/公開境界の障害注入、snapshot欠落、イベント破損、同一request-id再送、quota/symlink、古いrevision拒否を検証する。
- 初使用CAS prefixのmkdirから各祖先fsyncまで障害注入し、全パス永続化後だけイベントを公開すること、親fsync失敗時にイベント未確定であることを検証する。
- snapshotの80%警告境界・32MiB直前/一致/1byte超過（UTF-8/末尾LF込み）、超過時の状態不変、添付設定/実サイズ32MiB境界、全stage候補の上限検査と不適合時にcommitが増えないことを検証する。
- 一時bare Gitとghのfakeで正常FF、拒否再試行、remote先行/分岐/巻戻し/branch消失、public/認証不足、タイムアウトを検証する。テストはライブGitHubへ接続しない。
- 導入順はローカルCLI→固定snapshot fixtureをクライアントと照合→模擬同期→利用者が指定したprivate repoで任意の実機検証。実機Linux/GitHub配備は未検証と報告する。
- v1は毎回O(イベント数) replay。数万イベント/数十MiB snapshotで計測し、必要になった時だけ検証済みcheckpoint・検索索引・履歴配布分割を検討する。今は第二の正本を増やさない。
- 破壊的schema移行・イベント圧縮は行わない。将来の移行は旧データを残して新ディレクトリへexportし、対応クライアントを確認して切替する。

## 13. リスク・未決事項
- 長大履歴/添付によるGit容量、全量replay時間、snapshot通信量を監視する。snapshot絶対32MiB・80%警告と添付絶対32MiBで配布可能な有限容量に制限する。満杯後の容量拡張は将来設計であり、履歴削除や上限緩和で回避しない。
- 複数Unix UID、暗号化保存、承認者本人の認証、完全な秘密抹消、実時間push通知が必須になれば追加設計が必要。現在の要件・実装着手の阻害要因ではない。
- 運用時に決める事項はrepo/branch、サーバーdata-dir、actor命名、容量上限、timer周期、端末の読み取り認証。ローカル開発にユーザー作業を要求しない。
- 実GitHub private連携とLinux永続ストレージ上の障害耐性はローカルテストだけでは証明しない。未実施の実機検証を完了扱いしない。

## Key Decisions
- 正本は単一共有サーバーの不変イベント列。排他lockとdurable commitで並行更新・クラッシュ時の不変条件を守る。blob自身・新規ディレクトリエントリ・全祖先の永続化をイベント公開条件にする。
- snapshot v1を固定読み取り契約とし、証拠・裁定・追記・添付・操作主体を型付きで出す。snapshot/添付単体は絶対32MiB以下とし、snapshot超過はイベント確定前、配布ファイル超過はcommit前に拒否する。クライアントにイベントreplayを要求しない。
- 完了は証拠と明示確認の両方が必須。削除・追記上書き・暗黙状態遷移・多拠点マージはしない。
- ローカル完結を標準にし、private GitHubへの同期だけを明示的に許可する。設定/配備不足はsyncの実行時エラーであり実装停止理由ではない。

## PR Plan
1. CLI入口・型/validator・manifest/event reducer・lock/原子的永続化を実装し、各祖先fsync失敗時にイベント未確定となるcrash/idempotencyテストを整える。
2. lane/task/コメント/裁定・証拠付き完了と履歴を実装し、snapshot v1 fixtureとドメインテストを固定する。
3. 添付CAS・quota・安全なファイル操作、Unicode検索・フィルタ・日本語digestを実装する。初使用prefixのmkdir/fsync障害、snapshotの80%警告/32MiB境界/超過原子性、添付設定と実サイズの絶対32MiB上限をテストする。
4. GitHub private確認・FF限定同期・ローカル同期状態・mock Git/ghテストを追加し、全stage候補のサイズ不適合時にcommit/pushしないことを検証する。
5. fsync障害・容量境界を含む全テストと有限容量のクライアント契約を照合し、実施済み/未検証範囲を日本語で報告する。実際のcommit/PR作成・デプロイはこの計画に含めない。
