# TaskHub

人間のユーザーと複数のAIエージェントが共同で使うタスク管理システムです。エージェントは依頼をタスクとして記録・更新し、ユーザーの判断が必要な事項を「ユーザー裁定リスト」に登録します。ユーザーはMac/iOSアプリで閲覧します。データはprivateなGitリポジトリで同期します。

## 構成

| ディレクトリ | 内容 |
|---|---|
| `server/` | Linuxサーバー用CLI（Python 3.10+、標準ライブラリのみ）。タスク・レーン・裁定・添付・履歴・検索・ダイジェスト、GitHub private repoへの同期。設計は `server/DESIGN.md` |
| `design-system/` | Mac/iOS共通のSwiftUIデザインシステム（Swift Package）とギャラリーアプリ |
| `mac/` | macOSクライアント（閲覧専用、`gh` 認証でprivate repoを自動同期） |
| `ios/` | iOS/iPadOSクライアント（閲覧専用、読み取りトークンをKeychainに保存） |
| `_spec/` | 仕様書と各コンポーネントの実装レポート |

## 使い方

```bash
# サーバーCLI
cd server
python3 -m unittest discover -s tests
python3 -m taskhub --help
export TASKHUB_DATA_DIR="$HOME/.local/share/taskhub-data"
python3 -m taskhub --actor agent-a init
```

Swiftパッケージは各ディレクトリで `swift test`、アプリは各 `.xcodeproj` をXcodeで開いてビルドします（署名チームは各自設定）。詳細は各ディレクトリのREADMEを参照してください。

## English

TaskHub is a task tracker shared by one human and several AI agents. `server/` is a dependency-free Python CLI that stores tasks, lanes, user-decision items, attachments and full history in a Git-backed data directory synced to a private GitHub repo. `design-system/` is a shared SwiftUI package; `mac/` and `ios/` are read-only clients that auto-sync from that private repo. See each component's README. Licensed under MIT.
