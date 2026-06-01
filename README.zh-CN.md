<h1 align="center">Chatmux</h1>
<p align="center"><a href="https://github.com/manaflow-ai/cmux">cmux</a> 的个人分支，集成了原生 Claude、GitLab 工作流工具以及其他便利功能。</p>

<p align="center">
  <a href="#从源代码安装">从源代码安装</a> · <a href="#此分支新增的功能">此分支新增的功能</a> · <a href="#与上游同步">与上游同步</a> · <a href="https://github.com/manaflow-ai/cmux">cmux 上游</a>
</p>

---

Chatmux 基于 [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) 构建——一款基于 Ghostty 的 macOS 终端，具有垂直标签页和针对 AI 编码代理的通知功能。上游 [README](https://github.com/manaflow-ai/cmux/blob/main/README.zh-CN.md) 中记录的所有内容（通知圆环、内置浏览器、垂直+水平标签页、SSH、Claude Code Teams、会话恢复、cmux CLI/socket API 等）仍然适用。

本文档仅介绍 Chatmux 在此基础上新增的内容。

## 此分支新增的功能

### Claude Chat 面板

集成在任意窗格中的 Claude SDK 面板——继承 workspace 的工作目录、流式响应、按 surface 持久化对话历史。

- MCP 集成：内置 **MCP Manager** 弹出窗口用于注册/管理 MCP 服务器，并通过 health prober 在线显示服务器状态
- Slash 命令注册表：为每个 chat 定义自己的 slash 命令
- 状态栏 runner：长时间运行的任务在 chat 标题处渲染实时状态行
- 会话历史：每个 chat 都会写入磁盘日志，并能跨 cmux 重启恢复
- 权限规则引擎：配置 chat 可以自动调用哪些工具、哪些需要确认

标签栏内置操作 `cmux.newClaudeChat` 会在聚焦的窗格中打开一个新的 Claude Chat。

### GitLab 集成

仅限当前 workspace 所对应 GitLab 项目的右侧栏面板：

- **Merge Requests** 列表，含被分配人/作者过滤器与一键打开
- **Issues** 列表，使用相同的过滤系统，由 `GitLabIssueFiltersStore` 支撑
- **Pipelines** 列表，含状态指示器
- **Releases** 列表
- **MR Discussions** 查看器，支持 three-way diff（`MRDiscussions.swift`）
- diff refs 与 merged-tree 存储，使 diff 查看器始终知道正确的 base/target SHA

使用您本地的 `glab` / `git` 配置——无需额外凭据。

### Git diff 查看器

针对任意 commit、分支或工作树的独立 diff 窗口（`GitDiffWindow.swift`）：

- 并排 `DiffCodeTextView` 与三方 `DiffThreeWayCodeTextView`
- 自定义 `LCSDiff` 引擎与 `SyntaxHighlighter`，支持 Swift、TypeScript、Markdown 等
- 与 GitLab MR Discussions 查看器共用

### Workspace Notes 侧栏

随 workspace 移动的 markdown 笔记：

- 在右侧栏内挂载于 GitLab 面板旁边的侧栏插槽
- 关闭 workspace 时自动归档——笔记永不被静默丢弃（详见 `TabManager.closeWorkspace` 中的安全网）
- 独立的 **Notes Manager** 窗口（`WorkspaceNotesManagerWindowController`），用于浏览和恢复所有 workspace 的归档笔记
- 标签栏内置操作 `cmux.toggleNotes`，通过键盘或自定义命令切换侧栏

### 会话预设

将当前会话布局（窗格、surface、终端、浏览器 URL、侧栏状态）保存为命名预设，然后再恢复：

- 保存：`File → Save Session as Preset…`（或命令面板）
- 加载：`File → Load Preset → …`
- 更新：`File → Update Current Preset`
- 存储按 bundle-id 隔离，因此 cmux 与 Chatmux 各自维护独立的预设集（`SessionPresetSchema.defaultDirectoryURL`）

### MCP Manager + Background Shells 弹出窗口

可从标题栏访问的两个弹出窗口：

- **MCP Manager** — 发现、启用、禁用并对 Claude chat 使用的 MCP 服务器进行健康检查
- **Background Shells** — 浏览由 chat / surface API 启动的分离 shell，查看其输出，并将其恢复到可见的 surface

### Open in Sourcetree

新的标签栏内置操作 `cmux.openInSourcetree`，位于 `openInFinder` 和 `openInIDE` 旁边。将聚焦窗格的工作目录在 [Atlassian Sourcetree](https://www.sourcetreeapp.com/) 中打开（如果 Sourcetree 未安装在 `/Applications/Sourcetree.app`，则会发出蜂鸣声）。

可在 `~/.config/cmux/cmux.json` 中自定义按钮布局，或使用默认标签栏。

### 自安装脚本

`scripts/install-fork.sh` 构建 Release 配置、以独立 bundle id 进行 ad-hoc 签名，并将 bundle 复制到 `/Applications/Chatmux.app`，使其与上游 cmux 并行运行：

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

默认身份：

| 字段 | 值 |
|---|---|
| 应用名 | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| 安装路径 | `/Applications/Chatmux.app` |

使用 `--name`、`--bundle-id` 或 `--dest` 可覆盖（例如，staging 构建）。通过 `codesign -i <bundle-id>` 固定 bundle id 对 macOS TCC 权限的稳定性至关重要——否则每次启动都会重新请求 Documents/App Management 权限。

Workspace、会话快照、预设、笔记、MCP 配置和 TCC 授权都以 `CFBundleIdentifier` 作为索引键，因此只要保持相同的 bundle id，它们在重新安装后都会保留。

### `/sync-upstream` slash 命令

自定义的 Claude Code slash 命令（位于 `.claude/commands/`）自动化 chatmux ↔ upstream 合并流程：

- 将 `main` 快进合并到 `manaflow-ai/cmux:main`
- 将对应的 `vendor/bonsplit` 子模块指针镜像到您的 bonsplit fork
- 创建临时分支 `chatmux-merge-<timestamp>` 并将 upstream 合并进去
- 通过两侧合并 + 按 ID 去重自动解决 `cmux.xcodeproj/project.pbxproj` 冲突
- 当 `Sources/`、`Packages/` 或 `Resources/` 出现冲突时停止并提示人工处理
- 推送临时分支并等待构建确认，然后再快进 `chatmux`

完整工作流参见 `.claude/commands/sync-upstream.md`，pbxproj 助手参见 `scripts/sync-upstream-resolve.py`。

## 从源代码安装

Chatmux 不以 DMG 发布。使用 fork 脚本构建并安装：

```bash
# 带子模块克隆
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# 一次性设置（获取 Ghostty 子模块、GhosttyKit 等）
./scripts/setup.sh

# 构建 Release + 安装到 /Applications/Chatmux.app + 启动
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

为什么使用 `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1` 前缀？我们本地运行 Zig 0.16，但 Ghostty 要求 0.15.2。跳过 zig 构建会强制脚本使用 `manaflow-ai/ghostty` 发布的预构建 GhosttyKit.xcframework。清理 `zig-pkg/` 让 build key 保持干净，使预构建缓存命中可用。

## 与上游同步

```bash
# 在本仓库的 Claude Code 会话中：
/sync-upstream
```

该 slash 命令处理整个合并工作流，包括冲突分流。参见 [此分支新增的功能 → /sync-upstream](#sync-upstream-slash-命令)。

如需手动合并，请遵循 `.claude/commands/sync-upstream.md` 中的相同步骤。

## 键盘快捷键

所有上游 cmux 快捷键均无变化。完整表格请参见 [上游 README](https://github.com/manaflow-ai/cmux/blob/main/README.zh-CN.md#keyboard-shortcuts)。Chatmux 专属快捷键可在 Settings → Keyboard Shortcuts 中配置，并像其他 cmux 快捷键一样出现在 `~/.config/cmux/cmux.json` 中。

## 致谢

Chatmux 是 [Manaflow](https://manaflow.com) 所开发的 [cmux](https://github.com/manaflow-ai/cmux) 的分支。上游的所有功能和终端引擎均归他们所有——请为原项目点 star 并予以支持。

## 许可证

与上游相同：[GPL-3.0-or-later](LICENSE)。
