<h1 align="center">Chatmux</h1>
<p align="center"><a href="https://github.com/manaflow-ai/cmux">cmux</a> の個人フォークで、Claude の統合、GitLab ワークフローツール、その他の品質改善機能を追加しています。</p>

<p align="center">
  <a href="#ソースからのインストール">ソースからのインストール</a> · <a href="#このフォークが追加する機能">このフォークが追加する機能</a> · <a href="#upstream-との同期">upstream との同期</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux は [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) の上に構築されています。Ghostty ベースの macOS ターミナルで、AI コーディングエージェント向けの垂直タブと通知機能を備えています。upstream の [README](https://github.com/manaflow-ai/cmux/blob/main/README.ja.md) に記載されているすべて（通知リング、アプリ内ブラウザ、垂直＋水平タブ、SSH、Claude Code Teams、セッション復元、cmux CLI/socket API など）はそのまま使えます。

このドキュメントでは Chatmux が追加で提供する機能のみを説明します。

## このフォークが追加する機能

### Claude Chat パネル

任意のペイン内で動作する組み込みの Claude SDK パネル。ワークスペースの作業ディレクトリを引き継ぎ、応答をストリーミングし、会話履歴をサーフェスごとに永続化します。

- MCP 統合: 組み込みの **MCP Manager** ポップオーバーで MCP サーバーを登録・管理し、ヘルスプローバーがサーバーの状態をインラインで表示
- スラッシュコマンドレジストリ: チャットごとに独自のスラッシュコマンドを定義可能
- ステータスラインランナー: 長時間実行されるタスクはチャットヘッダーにライブステータスラインをレンダリング
- セッション履歴: 各チャットはディスクにジャーナリングされ、cmux の再起動を跨いで再開可能
- 権限ルールエンジン: チャットが自動的に呼び出せるツールと、確認を求めるツールを設定

タブバーの組み込みアクション `cmux.newClaudeChat` でフォーカス中のペインに新しい Claude Chat を開きます。

### GitLab 統合

ワークスペースの GitLab プロジェクトにスコープされた右サイドバーパネル:

- 担当者/作成者フィルタとワンクリックオープンを備えた **Merge Requests** リスト
- `GitLabIssueFiltersStore` がバックエンドの同じフィルタシステムを持つ **Issues** リスト
- ステータスインジケータ付きの **Pipelines** リスト
- **Releases** リスト
- three-way diff サポートを備えた **MR Discussions** ビューア (`MRDiscussions.swift`)
- diff refs と merged-tree ストアにより、diff ビューアは常に正しい base/target SHA を把握

ローカルの `glab` / `git` 設定を使用するため、追加の認証情報は不要です。

### Git diff ビューア

任意のコミット、ブランチ、または作業ツリー用のスタンドアロン diff ウィンドウ (`GitDiffWindow.swift`):

- 横並びの `DiffCodeTextView` と three-way の `DiffThreeWayCodeTextView`
- Swift、TypeScript、Markdown などをサポートするカスタムの `LCSDiff` エンジンと `SyntaxHighlighter`
- GitLab MR Discussions ビューアと共有

### ワークスペースノートサイドバー

ワークスペースに紐づくマークダウンノート:

- GitLab パネルの隣（右サイドバー）にマウントされるサイドバースロット
- ワークスペース終了時に自動アーカイブ — ノートが静かに失われることはありません（`TabManager.closeWorkspace` のセーフティネットを参照）
- 全ワークスペースのアーカイブされたノートを閲覧・復元するスタンドアロン **Notes Manager** ウィンドウ (`WorkspaceNotesManagerWindowController`)
- キーボードまたはカスタムコマンドからサイドバーを切り替えるタブバーの組み込みアクション `cmux.toggleNotes`

### セッションプリセット

現在のセッションレイアウト（ペイン、サーフェス、ターミナル、ブラウザ URL、サイドバーの状態）を名前付きプリセットとして保存し、後で再インスタンス化できます:

- 保存: `File → Save Session as Preset…`（またはコマンドパレット）
- 読み込み: `File → Load Preset → …`
- 更新: `File → Update Current Preset`
- ストレージは bundle-id ごとにスコープされているため、cmux と Chatmux は独立したプリセットコレクションを保持します (`SessionPresetSchema.defaultDirectoryURL`)

### MCP Manager + Background Shells ポップオーバー

タイトルバーから到達可能な 2 つのポップオーバー:

- **MCP Manager** — Claude チャットが使用する MCP サーバーを検出、有効化、無効化、ヘルスチェック
- **Background Shells** — チャット / サーフェス API によって起動された切り離されたシェルを閲覧し、出力を確認し、見えるサーフェスに再開

### Open in Sourcetree

`openInFinder` と `openInIDE` の隣に新しいタブバーの組み込みアクション `cmux.openInSourcetree`。フォーカス中のペインの作業ディレクトリを [Atlassian Sourcetree](https://www.sourcetreeapp.com/) で開きます（`/Applications/Sourcetree.app` に Sourcetree がインストールされていない場合はビープ音）。

`~/.config/cmux/cmux.json` で独自のボタン配置に組み込むか、デフォルトのタブバーに依存します。

### セルフインストールスクリプト

`scripts/install-fork.sh` は Release 構成でビルドし、別の bundle id で ad-hoc 署名し、upstream cmux と並べて動作するようにバンドルを `/Applications/Chatmux.app` にコピーします:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

デフォルトの ID:

| フィールド | 値 |
|---|---|
| アプリ名 | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| インストールパス | `/Applications/Chatmux.app` |

`--name`、`--bundle-id`、または `--dest` で異なる ID を指定できます（例: ステージングビルド）。`codesign -i <bundle-id>` による bundle id の固定は、macOS TCC 権限を安定させるために重要です。これがないと、Documents/App Management の権限が起動のたびに再要求されます。

ワークスペース、セッションスナップショット、プリセット、ノート、MCP 設定、TCC 許可はすべて `CFBundleIdentifier` でキー付けされているため、bundle id を同じにしておけば再インストール時にも維持されます。

### `/sync-upstream` スラッシュコマンド

Claude Code のカスタムスラッシュコマンド（`.claude/commands/` 内）が chatmux ↔ upstream のマージ作業を自動化します:

- `main` を `manaflow-ai/cmux:main` に fast-forward
- 対応する `vendor/bonsplit` サブモジュールポインタを bonsplit fork にミラー
- 一時的な `chatmux-merge-<timestamp>` ブランチを作成し、upstream をマージ
- `cmux.xcodeproj/project.pbxproj` のコンフリクトを両側を結合し ID でデュープして自動解決
- `Sources/`、`Packages/`、`Resources/` のコンフリクトは停止して人間による解決を求める
- 一時ブランチをプッシュし、ビルド確認を待ってから `chatmux` を fast-forward

完全なワークフローは `.claude/commands/sync-upstream.md`、pbxproj ヘルパーは `scripts/sync-upstream-resolve.py` を参照してください。

## ソースからのインストール

Chatmux は DMG として公開されていません。フォークスクリプトでビルドしてインストールしてください:

```bash
# サブモジュール付きでクローン
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# 初期セットアップ（Ghostty サブモジュール、GhosttyKit などをフェッチ）
./scripts/setup.sh

# Release をビルド + /Applications/Chatmux.app にインストール + 起動
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

なぜ `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` のプレフィックスが必要なのか？ ローカルでは Zig 0.16 が動作していますが、Ghostty は 0.15.2 を要求します。Zig ビルドをスキップすると、スクリプトは `manaflow-ai/ghostty` のリリースから事前ビルドされた GhosttyKit.xcframework を使用します。`zig-pkg/` のクリーンアップにより、ビルドキーがクリーンに保たれ、事前ビルドのキャッシュヒットが機能します。

## upstream との同期

```bash
# このリポジトリの Claude Code セッション内で:
/sync-upstream
```

このスラッシュコマンドはコンフリクトトリアージを含む完全なマージワークフローを処理します。[このフォークが追加する機能 → /sync-upstream](#sync-upstream-スラッシュコマンド) を参照してください。

手動マージの場合は、`.claude/commands/sync-upstream.md` の同じステップに従ってください。

## キーボードショートカット

upstream cmux のすべてのショートカットはそのまま機能します。完全な一覧は [upstream README](https://github.com/manaflow-ai/cmux/blob/main/README.ja.md#keyboard-shortcuts) を参照してください。Chatmux 専用のショートカットは Settings → Keyboard Shortcuts で設定可能で、他の cmux ショートカットと同様に `~/.config/cmux/cmux.json` に反映されます。

## クレジット

Chatmux は [Manaflow](https://manaflow.com) による [cmux](https://github.com/manaflow-ai/cmux) のフォークです。upstream のすべての機能とターミナルエンジンは彼らのものです。オリジナルのプロジェクトにスターを付けてサポートしてください。

## ライセンス

upstream と同じ: [GPL-3.0-or-later](LICENSE)。
