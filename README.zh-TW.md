<h1 align="center">Chatmux</h1>
<p align="center"><a href="https://github.com/manaflow-ai/cmux">cmux</a> 的個人分支，整合了原生 Claude、GitLab 工作流工具以及其他便利功能。</p>

<p align="center">
  <a href="#從原始碼安裝">從原始碼安裝</a> · <a href="#此分支新增的功能">此分支新增的功能</a> · <a href="#與上游同步">與上游同步</a> · <a href="https://github.com/manaflow-ai/cmux">cmux 上游</a>
</p>

---

Chatmux 建立於 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 之上——一款基於 Ghostty 的 macOS 終端，具有垂直分頁與針對 AI 編碼代理的通知功能。上游 [README](https://github.com/manaflow-ai/cmux/blob/main/README.zh-TW.md) 中記載的所有內容（通知圓環、內建瀏覽器、垂直+水平分頁、SSH、Claude Code Teams、工作階段恢復、cmux CLI/socket API 等）依然適用。

本文件僅介紹 Chatmux 在此基礎上新增的內容。

## 此分支新增的功能

### Claude Chat 面板

整合在任意窗格中的 Claude SDK 面板——繼承 workspace 的工作目錄、串流回應、按 surface 持久化對話歷史。

- MCP 整合：內建 **MCP Manager** 彈出視窗用於註冊/管理 MCP 伺服器，並透過 health prober 在線顯示伺服器狀態
- Slash 指令登錄：為每個 chat 定義自訂的 slash 指令
- 狀態列 runner：長時間執行的任務在 chat 標題處渲染即時狀態列
- 工作階段歷史：每個 chat 都會寫入磁碟日誌，並能跨 cmux 重啟恢復
- 權限規則引擎：設定 chat 可以自動呼叫哪些工具、哪些需要確認

分頁列內建動作 `cmux.newClaudeChat` 會在聚焦的窗格中開啟一個新的 Claude Chat。

### GitLab 整合

僅限當前 workspace 所對應 GitLab 專案的右側欄面板：

- **Merge Requests** 清單，含被指派人/作者過濾器與一鍵開啟
- **Issues** 清單，使用相同的過濾系統，由 `GitLabIssueFiltersStore` 支撐
- **Pipelines** 清單，含狀態指示器
- **Releases** 清單
- **MR Discussions** 檢視器，支援 three-way diff（`MRDiscussions.swift`）
- diff refs 與 merged-tree 儲存，使 diff 檢視器始終知道正確的 base/target SHA

使用您本機的 `glab` / `git` 設定——無需額外憑證。

### Git diff 檢視器

針對任意 commit、分支或工作樹的獨立 diff 視窗（`GitDiffWindow.swift`）：

- 並排 `DiffCodeTextView` 與三方 `DiffThreeWayCodeTextView`
- 自訂 `LCSDiff` 引擎與 `SyntaxHighlighter`，支援 Swift、TypeScript、Markdown 等
- 與 GitLab MR Discussions 檢視器共用

### Workspace Notes 側欄

隨 workspace 移動的 markdown 筆記：

- 在右側欄中掛載於 GitLab 面板旁邊的側欄插槽
- 關閉 workspace 時自動封存——筆記永不被靜默捨棄（詳見 `TabManager.closeWorkspace` 中的安全網）
- 獨立的 **Notes Manager** 視窗（`WorkspaceNotesManagerWindowController`），用於瀏覽和恢復所有 workspace 的封存筆記
- 分頁列內建動作 `cmux.toggleNotes`，透過鍵盤或自訂指令切換側欄

### 工作階段預設

將目前的工作階段配置（窗格、surface、終端、瀏覽器 URL、側欄狀態）儲存為命名預設，之後再恢復：

- 儲存：`File → Save Session as Preset…`（或指令面板）
- 載入：`File → Load Preset → …`
- 更新：`File → Update Current Preset`
- 儲存按 bundle-id 隔離，因此 cmux 與 Chatmux 各自維護獨立的預設集合（`SessionPresetSchema.defaultDirectoryURL`）

### MCP Manager + Background Shells 彈出視窗

可從標題列存取的兩個彈出視窗：

- **MCP Manager** — 探索、啟用、停用並對 Claude chat 使用的 MCP 伺服器執行健康檢查
- **Background Shells** — 瀏覽由 chat / surface API 啟動的分離 shell，查看其輸出，並將其恢復到可見的 surface

### Open in Sourcetree

新的分頁列內建動作 `cmux.openInSourcetree`，位於 `openInFinder` 與 `openInIDE` 旁邊。將聚焦窗格的工作目錄在 [Atlassian Sourcetree](https://www.sourcetreeapp.com/) 中開啟（若 Sourcetree 未安裝於 `/Applications/Sourcetree.app`，則會發出嗶聲）。

可在 `~/.config/cmux/cmux.json` 中自訂按鈕配置，或使用預設分頁列。

### 自安裝指令稿

`scripts/install-fork.sh` 建置 Release 配置、以獨立 bundle id 進行 ad-hoc 簽章，並將 bundle 複製到 `/Applications/Chatmux.app`，使其與上游 cmux 並行運作：

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

預設身份：

| 欄位 | 值 |
|---|---|
| 應用程式名稱 | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| 安裝路徑 | `/Applications/Chatmux.app` |

使用 `--name`、`--bundle-id` 或 `--dest` 可覆蓋（例如，staging 建置）。透過 `codesign -i <bundle-id>` 固定 bundle id 對 macOS TCC 權限的穩定性至關重要——否則每次啟動都會重新請求 Documents/App Management 權限。

Workspace、工作階段快照、預設、筆記、MCP 設定與 TCC 授權都以 `CFBundleIdentifier` 作為索引鍵，因此只要保持相同的 bundle id，它們在重新安裝後都會保留。

### `/sync-upstream` slash 指令

自訂的 Claude Code slash 指令（位於 `.claude/commands/`）自動化 chatmux ↔ upstream 合併流程：

- 將 `main` 快進合併到 `manaflow-ai/cmux:main`
- 將對應的 `vendor/bonsplit` 子模組指標鏡像到您的 bonsplit fork
- 建立暫時分支 `chatmux-merge-<timestamp>` 並將 upstream 合併進去
- 透過兩側合併 + 按 ID 去重自動解決 `cmux.xcodeproj/project.pbxproj` 衝突
- 當 `Sources/`、`Packages/` 或 `Resources/` 出現衝突時停止並提示人工處理
- 推送暫時分支並等待建置確認，然後再快進 `chatmux`

完整工作流參見 `.claude/commands/sync-upstream.md`，pbxproj 助手參見 `scripts/sync-upstream-resolve.py`。

## 從原始碼安裝

Chatmux 不以 DMG 發行。使用 fork 指令稿建置並安裝：

```bash
# 連同子模組複製
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# 一次性設定（取得 Ghostty 子模組、GhosttyKit 等）
./scripts/setup.sh

# 建置 Release + 安裝到 /Applications/Chatmux.app + 啟動
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

為什麼使用 `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` 前綴？本機我們執行 Zig 0.16，但 Ghostty 要求 0.15.2。跳過 zig 建置會強制指令稿使用 `manaflow-ai/ghostty` 發行的預建 GhosttyKit.xcframework。清理 `zig-pkg/` 讓 build key 保持乾淨，使預建快取命中可用。

## 與上游同步

```bash
# 在本儲存庫的 Claude Code 工作階段中：
/sync-upstream
```

該 slash 指令處理整個合併工作流，包括衝突分流。參見 [此分支新增的功能 → /sync-upstream](#sync-upstream-slash-指令)。

如需手動合併，請遵循 `.claude/commands/sync-upstream.md` 中的相同步驟。

## 鍵盤快捷鍵

所有上游 cmux 快捷鍵均無變更。完整表格請參見 [上游 README](https://github.com/manaflow-ai/cmux/blob/main/README.zh-TW.md#keyboard-shortcuts)。Chatmux 專屬快捷鍵可在 Settings → Keyboard Shortcuts 中設定，並像其他 cmux 快捷鍵一樣出現在 `~/.config/cmux/cmux.json` 中。

## 致謝

Chatmux 是 [Manaflow](https://manaflow.com) 所開發的 [cmux](https://github.com/manaflow-ai/cmux) 的分支。上游的所有功能與終端引擎均歸他們所有——請為原專案點 star 並予以支持。

## 授權

與上游相同：[GPL-3.0-or-later](LICENSE)。
