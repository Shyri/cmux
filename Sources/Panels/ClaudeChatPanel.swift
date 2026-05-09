import AppKit
import Combine
import Foundation

/// Status of the chat conversation.
enum ChatStatus: Equatable {
    case idle
    case sending
    case error(String)
}

/// A file attached to the next user message. The file lives on disk so
/// Claude Code can read it through `@<path>` expansion (which produces
/// multimodal image blocks for image files).
struct ChatAttachment: Identifiable, Equatable {
    let id: UUID
    /// Path to the (cmux-managed) copy of the file.
    let url: URL
    /// Human-readable name shown in the preview chip.
    let displayName: String
    /// True for `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, etc.
    let isImage: Bool

    init(url: URL, displayName: String, isImage: Bool) {
        self.id = UUID()
        self.url = url
        self.displayName = displayName
        self.isImage = isImage
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tiff", "tif"
    ]

    static func isImageFile(at url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Build the user-visible text for a turn that may include attached
    /// files. Attachments are surfaced as `@<path>` mentions which Claude
    /// Code expands into multimodal content blocks (images become image
    /// blocks; other files are read as text).
    static func composeUserMessage(text: String, attachments: [ChatAttachment]) -> String {
        guard !attachments.isEmpty else { return text }
        let mentions = attachments.map { "@\($0.url.path)" }.joined(separator: " ")
        if text.isEmpty {
            return mentions
        }
        return "\(mentions)\n\n\(text)"
    }
}

/// Permission modes mapped 1:1 to Claude Code's four canonical modes.
/// (Claude Code interactive uses Shift+Tab to cycle through them.)
enum ChatPermissionMode: String, CaseIterable, Identifiable {
    /// `--permission-mode plan`. Claude can read and reason but cannot
    /// modify the workspace (no Edit/Write/Bash side effects).
    case plan
    /// `--permission-mode default` + our `--permission-prompt-tool`. Claude
    /// asks before every tool use; the inline Allow/Deny card appears in
    /// the chat. Equivalent of Claude Code's "Normal" mode.
    case normal
    /// `--permission-mode acceptEdits` + our `--permission-prompt-tool`.
    /// File edits (Edit/Write/NotebookEdit) auto-allow; everything else
    /// (Bash, etc.) still surfaces an Allow/Deny card.
    case acceptEdits
    /// `--permission-mode bypassPermissions`. All tools auto-execute; no
    /// approval card surfaces. Equivalent of Claude Code's "Bypass" mode.
    case bypass

    var id: String { rawValue }

    var claudeFlag: String {
        switch self {
        case .plan: return "plan"
        case .normal: return "default"
        case .acceptEdits: return "acceptEdits"
        case .bypass: return "bypassPermissions"
        }
    }

    /// Whether this mode wants `--permission-prompt-tool` wired so non-
    /// auto-allowed tools get an inline Allow/Deny card.
    var usesPermissionPromptTool: Bool {
        switch self {
        case .normal, .acceptEdits: return true
        case .plan, .bypass: return false
        }
    }

    var label: String {
        switch self {
        case .plan:
            return String(localized: "claudeChat.mode.plan", defaultValue: "Plan")
        case .normal:
            return String(localized: "claudeChat.mode.normal", defaultValue: "Normal")
        case .acceptEdits:
            return String(localized: "claudeChat.mode.acceptEdits", defaultValue: "Auto-edits")
        case .bypass:
            return String(localized: "claudeChat.mode.bypass", defaultValue: "Bypass")
        }
    }

    var iconName: String {
        switch self {
        case .plan: return "list.bullet.rectangle"
        case .normal: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .bypass: return "bolt.fill"
        }
    }
}

/// A panel that renders a conversation with Claude Code. The MVP fase 1 does
/// not yet wire up the subprocess or the MCP approval helper — it stands up
/// the panel, the SwiftUI view, and a mock transcript so the rest of the
/// integration (menu, persistence, focus, layout) can be exercised first.
@MainActor
final class ClaudeChatPanel: Panel, ObservableObject, ChatMcpHttpServerDelegate {
    let id: UUID
    let panelType: PanelType = .claudeChat

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Working directory passed to `claude` when a turn is sent. Inherited
    /// from the workspace's focused terminal panel at creation time.
    @Published private(set) var workingDirectory: String

    /// Chat transcript. Fase 1 ships with a small mock transcript; fase 2
    /// will replace this with live events from `ClaudeChatRunner`.
    @Published private(set) var messages: [ChatMessage]

    /// Session id emitted by Claude on the first `system/init` event of a
    /// conversation. Required for `--resume` on subsequent turns.
    @Published private(set) var sessionId: String?

    /// Active model name, sourced from `system/init`. Displayed as a chip
    /// in the chat header so the user can tell which Claude variant they
    /// are talking to.
    @Published private(set) var modelName: String?

    /// Cumulative USD cost of the conversation, summed across `result`
    /// events. Reset by `clearTranscript()`.
    @Published private(set) var totalCostUSD: Double = 0

    /// Conversation status drives input affordances (send/cancel/error banner).
    @Published private(set) var status: ChatStatus = .idle

    /// Tool-use requests waiting for the user to allow/deny.
    @Published var pendingApprovals: [ChatApprovalRequest] = []

    /// User-question prompts (ask_user_question) waiting for an answer.
    @Published var pendingQuestions: [ChatUserQuestionRequest] = []

    /// Tool results indexed by their `tool_use_id`. The transcript view
    /// looks up the result for each `tool_use` block from this map and
    /// renders both inside one collapsible row, instead of showing the
    /// command and its output as separate sibling rows.
    @Published private(set) var toolResultsByToolUseId: [String: ChatMessageBlock.ToolResult] = [:]

    /// Resolvers waiting for the panel to call them with the user's reply.
    /// Keyed by request id.
    private var approvalResolvers: [String: (ChatApprovalResponse) -> Void] = [:]
    private var questionResolvers: [String: (ChatUserQuestionResponse) -> Void] = [:]

    /// Tools the user marked "Allow always" within this chat. Future
    /// approval requests for these tools auto-allow without surfacing the
    /// card. Cleared on `clearTranscript()`. In-memory only (phase 4 will
    /// persist this alongside the session).
    @Published private(set) var alwaysAllowedTools: Set<String> = []

    /// Pending file attachments that will be referenced in the next user
    /// turn. Files are copied into the panel's temp dir and surfaced to
    /// claude via `@<path>` mentions, which Claude Code expands into
    /// multimodal content blocks.
    @Published private(set) var pendingAttachments: [ChatAttachment] = []

    /// Edits (Edit/MultiEdit/Write/NotebookEdit tool_use blocks) emitted
    /// during the current — or just-finished — turn. Cleared when the user
    /// sends a new message so the side pane always reflects "what claude
    /// did since I last spoke."
    @Published private(set) var lastTurnEdits: [TurnEdit] = []

    /// Stack of rewind checkpoints, one per finished turn (oldest first).
    /// The view layer reads this to expose a "↶" button next to every
    /// user message. Each checkpoint anchors itself to the user message
    /// that started the turn so the user can rewind to *just before
    /// claude replied to this prompt*.
    @Published private(set) var undoCheckpoints: [RewindCheckpoint] = []

    struct RewindCheckpoint: Identifiable, Equatable {
        let id: UUID
        let userMessageId: UUID
        let userMessageIndex: Int
        let backupPaths: [String]
        /// Internal handle used to actually restore. Equatable wraps the
        /// session id + paths only; backup URLs are not part of identity.
        fileprivate let backups: ClaudeSessionHistory.TurnFileBackups?

        init(
            userMessageId: UUID,
            userMessageIndex: Int,
            backups: ClaudeSessionHistory.TurnFileBackups?
        ) {
            self.id = UUID()
            self.userMessageId = userMessageId
            self.userMessageIndex = userMessageIndex
            self.backupPaths = backups?.backups.keys.sorted() ?? []
            self.backups = backups
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.userMessageId == rhs.userMessageId
                && lhs.userMessageIndex == rhs.userMessageIndex
                && lhs.backupPaths == rhs.backupPaths
        }
    }

    struct TurnEdit: Identifiable, Equatable {
        let id: UUID
        let toolName: String
        let inputJSON: String

        init(toolName: String, inputJSON: String) {
            self.id = UUID()
            self.toolName = toolName
            self.inputJSON = inputJSON
        }
    }

    private static let editToolNames: Set<String> = [
        "Edit", "MultiEdit", "Write", "NotebookEdit"
    ]

    /// Pre-staged turn anchor: the id and index of the user message that
    /// started the in-flight turn. Filled in `send()` and consumed in
    /// `handle(.result)` once we know which file backups claude wrote.
    private var pendingTurnStaging: (userMessageId: UUID, userMessageIndex: Int)?

    /// Cached rules from `.claude/settings*.json`. Reloaded on every
    /// approval request so changes to the file are picked up live.
    private var cachedRulesCwd: String?
    private var cachedRulesMtimes: [String: Date] = [:]
    private var cachedRules: ChatPermissionRules = .empty

    /// HTTP MCP server for inline allow/deny + ask-user-question. Created on
    /// demand (first turn that runs in `.allowDeny` mode) and reused for the
    /// life of the panel.
    private var mcpServer: ChatMcpHttpServer?
    private var mcpConfigPath: String?

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Token bumped to ask the chat input view to claim first-responder.
    /// Driven by `focus()` (called by bonsplit when the pane becomes
    /// active) and by attachment drops, so keystrokes always land in the
    /// chat — not in a sibling terminal pane.
    @Published private(set) var inputFocusRequestToken: Int = 0

    /// User-overridable title (e.g. via tab "Rename"). When nil we derive
    /// the title from the first user message.
    @Published private(set) var customTitleOverride: String?

    /// Permission mode used for the next turn. Persists across turns within
    /// the same panel; the UI exposes a 4-way picker in the input bar.
    @Published var permissionMode: ChatPermissionMode = .normal

    /// Terminal background/foreground sourced from `~/.config/ghostty/config`
    /// so the chat panel matches whatever theme the user uses for terminals.
    /// Refreshed when `Notification.Name.ghosttyConfigDidReload` fires.
    @Published private(set) var terminalBackgroundColor: NSColor = NSColor(srgbRed: 0x2B/255.0, green: 0x2B/255.0, blue: 0x2B/255.0, alpha: 1.0)
    @Published private(set) var terminalForegroundColor: NSColor = NSColor(srgbRed: 0xBB/255.0, green: 0xBB/255.0, blue: 0xBB/255.0, alpha: 1.0)
    private var ghosttyConfigObserver: NSObjectProtocol?

    var displayTitle: String {
        if let custom = customTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let first = messages.first(where: { $0.role == .user })?.plainText
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return String(first.prefix(40))
        }
        return String(localized: "claudeChat.newTab.title", defaultValue: "Claude Chat")
    }

    var displayIcon: String? {
        "bubble.left.and.bubble.right"
    }

    var isDirty: Bool { false }

    private let runner = ClaudeChatRunner()

    init(
        workspaceId: UUID,
        workingDirectory: String,
        sessionId: String? = nil,
        initialMessages: [ChatMessage] = ClaudeChatPanel.welcomeMessages()
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory
        self.sessionId = sessionId
        self.messages = initialMessages

        bootstrapAlwaysAllowedFromSettings()
        refreshTerminalColors()
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTerminalColors()
            }
        }
    }

    deinit {
        if let observer = ghosttyConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Hydrate `alwaysAllowedTools` from `<cwd>/.claude/settings.local.json`
    /// only — that's the file cmux owns and writes to via "Allow always".
    /// Rules in `<cwd>/.claude/settings.json` (project shared) and
    /// `~/.claude/settings.json` (global) are still honoured by the rule
    /// engine for auto-allow, but they are NOT surfaced as revocable chips
    /// (the user authored those elsewhere; cmux should not offer to delete
    /// them from its UI).
    private func bootstrapAlwaysAllowedFromSettings() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsLocalPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any],
              let allowList = permissions["allow"] as? [String]
        else {
            alwaysAllowedTools = []
            return
        }
        let plain: [String] = allowList
            .compactMap(ChatPermissionPattern.parse)
            .compactMap { $0.argument == nil ? $0.toolName : nil }
        alwaysAllowedTools = Set(plain)
    }

    private func refreshTerminalColors() {
        let config = GhosttyConfig.load()
        if terminalBackgroundColor != config.backgroundColor {
            terminalBackgroundColor = config.backgroundColor
        }
        if terminalForegroundColor != config.foregroundColor {
            terminalForegroundColor = config.foregroundColor
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Bonsplit calls this when the chat tab becomes the active pane.
        // Without an explicit focus pull the workspace's last-focused
        // terminal can keep first-responder and steal subsequent keystrokes.
        inputFocusRequestToken &+= 1
    }

    func unfocus() {
        // No-op.
    }

    func close() {
        runner.cancel()
        mcpServer?.stop()
        mcpServer = nil
        if let path = mcpConfigPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        mcpConfigPath = nil
        // Drop the panel's attachments dir too — the files were copies we
        // owned for this chat's lifetime.
        let attachmentsBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claudechat-\(id.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: attachmentsBase)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Workspace coordination

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func updateWorkingDirectory(_ newWorkingDirectory: String) {
        let trimmed = newWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workingDirectory else { return }
        workingDirectory = trimmed
    }

    func setCustomTitle(_ title: String?) {
        customTitleOverride = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Conversation

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumedAttachments = pendingAttachments
        // Allow sending an attachment-only message (e.g. drag a screenshot
        // and just hit Enter) — claude can describe / OCR it without a
        // text prompt.
        guard !trimmed.isEmpty || !consumedAttachments.isEmpty else { return }
        if case .sending = status { return }

        // The text claude sees is the user's prompt prefixed with @<path>
        // mentions for each attachment — that triggers Claude Code's
        // multimodal expansion. The local transcript stores only the
        // user's own text plus a sidecar list of attachments, so the UI
        // can render thumbnails instead of long file paths.
        let userText = ChatAttachment.composeUserMessage(text: trimmed, attachments: consumedAttachments)
        let visibleText = trimmed
        let attachmentURLs = consumedAttachments.map { $0.url }
        var localMessage = ChatMessage(role: .user, blocks: visibleText.isEmpty ? [] : [.text(visibleText)])
        localMessage.attachmentURLs = attachmentURLs
        messages.append(localMessage)
        pendingAttachments.removeAll()
        // Each user prompt starts a new "turn" — drop the previous turn's
        // edit list so the diff side pane always shows what claude did in
        // response to the most recent message.
        lastTurnEdits.removeAll()
        // Stage a checkpoint anchored just AFTER the user message — an
        // undo will keep the user prompt visible and remove only what
        // claude streams below it. The file-backups are filled in once
        // the turn finishes (we read them out of claude's session JSONL).
        pendingTurnStaging = (userMessageId: localMessage.id, userMessageIndex: messages.count)
        status = .sending

        let cwd = workingDirectory
        let resumeId = sessionId
        let mode = permissionMode

        // The MCP server is started for every chat (regardless of mode) so
        // we can disable Claude Code's built-in `AskUserQuestion` (which
        // self-denies in headless mode) and route questions through our
        // own MCP tool. The HTTP listener is async — hop off main while it
        // binds so the UI stays responsive.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mcpConfigPath: String?
            do {
                mcpConfigPath = try await self.ensureMcpServerStarted()
            } catch {
                self.status = .error(error.localizedDescription)
                return
            }
            // Re-check status — user may have hit Clear or Cancel while we
            // were waiting for the server to bind.
            guard case .sending = self.status else { return }
            self.runner.start(
                userMessage: userText,
                cwd: cwd,
                sessionId: resumeId,
                permissionMode: mode.claudeFlag,
                mcpConfigPath: mcpConfigPath,
                permissionPromptTool: mode.usesPermissionPromptTool ? "mcp__cmux__approval_prompt" : nil,
                appendSystemPrompt: ClaudeChatPanel.cmuxToolsSystemPrompt,
                onEvent: { event in
                    Task { @MainActor [weak self] in
                        self?.handle(event: event)
                    }
                },
                onComplete: { result in
                    Task { @MainActor [weak self] in
                        self?.handle(completion: result)
                    }
                }
            )
        }
    }

    func cancel() {
        runner.cancel()
    }

    /// Rewind the conversation to *just after* `userMessageId` was sent
    /// — the prompt itself stays visible, every claude reply since is
    /// removed, and the matching file-history backup is replayed onto
    /// disk. Returns the number of files restored, or `nil` if no
    /// checkpoint matches that message id.
    ///
    /// Side effects:
    ///   - Drops every checkpoint at or after the rewind point (those
    ///     futures no longer exist).
    ///   - Clears the session id so the next prompt starts a fresh
    ///     conversation (Claude Code's CLI does not expose a way to
    ///     rewind its own memory mid-session).
    @discardableResult
    func rewindTo(userMessageId: UUID) -> Int? {
        guard let checkpointIdx = undoCheckpoints.firstIndex(
            where: { $0.userMessageId == userMessageId }
        ) else { return nil }
        let checkpoint = undoCheckpoints[checkpointIdx]

        var restoredFiles = 0
        if let backups = checkpoint.backups {
            restoredFiles = ClaudeSessionHistory.restore(backups).count
        }
        if checkpoint.userMessageIndex < messages.count {
            messages.removeSubrange(checkpoint.userMessageIndex ..< messages.count)
        }
        // Drop this checkpoint and every later one — they describe a
        // future that no longer exists.
        undoCheckpoints.removeSubrange(checkpointIdx ..< undoCheckpoints.count)

        lastTurnEdits.removeAll()
        toolResultsByToolUseId.removeAll()
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        approvalResolvers.removeAll()
        questionResolvers.removeAll()
        sessionId = nil
        pendingTurnStaging = nil
        if case .sending = status { status = .idle }
        return restoredFiles
    }

    /// Convenience: rewind to the most recent checkpoint.
    @discardableResult
    func undoLastTurn() -> Int? {
        guard let last = undoCheckpoints.last else { return nil }
        return rewindTo(userMessageId: last.userMessageId)
    }

    // MARK: - Attachments

    /// Copy `sourceURL` into the panel's attachment temp dir and add it
    /// to `pendingAttachments`. The original file is left untouched.
    @discardableResult
    func attachFile(at sourceURL: URL) -> ChatAttachment? {
        do {
            let dir = try ensureAttachmentDirectory()
            let ext = sourceURL.pathExtension
            let filename = ext.isEmpty
                ? UUID().uuidString
                : "\(UUID().uuidString).\(ext)"
            let dest = dir.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            let attachment = ChatAttachment(
                url: dest,
                displayName: sourceURL.lastPathComponent,
                isImage: ChatAttachment.isImageFile(at: sourceURL)
            )
            pendingAttachments.append(attachment)
            return attachment
        } catch {
            #if DEBUG
            NSLog("ClaudeChatPanel.attachFile failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// Persist arbitrary image data (e.g. from a clipboard / drop NSImage
    /// representation) to the attachments dir as a PNG.
    @discardableResult
    func attachImageData(_ data: Data, suggestedExtension: String = "png", baseName: String = "image") -> ChatAttachment? {
        do {
            let dir = try ensureAttachmentDirectory()
            let filename = "\(baseName)-\(UUID().uuidString.prefix(6)).\(suggestedExtension)"
            let dest = dir.appendingPathComponent(filename)
            try data.write(to: dest, options: .atomic)
            let attachment = ChatAttachment(
                url: dest,
                displayName: filename,
                isImage: true
            )
            pendingAttachments.append(attachment)
            return attachment
        } catch {
            #if DEBUG
            NSLog("ClaudeChatPanel.attachImageData failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    private func ensureAttachmentDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claudechat-\(id.uuidString)", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func ensureMcpServerStarted() async throws -> String {
        if let existing = mcpConfigPath, mcpServer != nil {
            return existing
        }
        let server = try ChatMcpHttpServer()
        try await server.start()
        server.delegate = self
        mcpServer = server

        let config: [String: Any] = [
            "mcpServers": [
                "cmux": [
                    "type": "http",
                    "url": server.endpointURL.absoluteString
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        let tmpDir = NSTemporaryDirectory()
        let path = (tmpDir as NSString).appendingPathComponent("cmux-claudechat-\(id.uuidString).json")
        try data.write(to: URL(fileURLWithPath: path))
        mcpConfigPath = path
        return path
    }

    /// Reset the conversation: cancel any in-flight turn, drop the messages
    /// transcript, forget the session id (so the next turn starts a fresh
    /// claude session, not a `--resume`), and clear errors.
    func clearTranscript() {
        runner.cancel()
        messages = ClaudeChatPanel.welcomeMessages()
        sessionId = nil
        modelName = nil
        totalCostUSD = 0
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        toolResultsByToolUseId.removeAll()
        pendingAttachments.removeAll()
        lastTurnEdits.removeAll()
        undoCheckpoints.removeAll()
        pendingTurnStaging = nil
        // Note: alwaysAllowedTools is intentionally preserved — it's persisted
        // in `.claude/settings.local.json` and represents user preferences
        // that should outlive a single conversation.
        status = .idle
    }

    func approve(toolUseId: String) {
        guard let resolver = approvalResolvers.removeValue(forKey: toolUseId) else {
            pendingApprovals.removeAll { $0.id == toolUseId }
            return
        }
        pendingApprovals.removeAll { $0.id == toolUseId }
        resolver(.allow)
    }

    /// Approve this request and add the tool to the workspace's
    /// `.claude/settings.local.json` so subsequent calls to the same tool
    /// skip the UI prompt — both for the rest of this chat and for any
    /// future chat in the same workspace.
    func approveAlways(toolUseId: String, toolName: String) {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            alwaysAllowedTools.insert(trimmed)
            try? ChatPermissionRules.writeAllowEntry(trimmed, toFileAt: settingsLocalPath)
            invalidatePermissionRulesCache()
        }
        approve(toolUseId: toolUseId)
    }

    func deny(toolUseId: String, reason: String?) {
        guard let resolver = approvalResolvers.removeValue(forKey: toolUseId) else {
            pendingApprovals.removeAll { $0.id == toolUseId }
            return
        }
        pendingApprovals.removeAll { $0.id == toolUseId }
        resolver(.deny(reason: reason))
    }

    /// Revoke a tool from the "always allow" set (UI exposes this as a
    /// chip in the header). Also removes it from the workspace's
    /// `.claude/settings.local.json`.
    func revokeAlwaysAllowed(toolName: String) {
        alwaysAllowedTools.remove(toolName)
        try? ChatPermissionRules.removeAllowEntry(toolName, fromFileAt: settingsLocalPath)
        invalidatePermissionRulesCache()
    }

    private var settingsLocalPath: String {
        (workingDirectory as NSString).appendingPathComponent(".claude/settings.local.json")
    }

    private func invalidatePermissionRulesCache() {
        cachedRulesCwd = nil
        cachedRulesMtimes = [:]
    }

    func answer(questionId: String, answers: [[String]]) {
        guard let resolver = questionResolvers.removeValue(forKey: questionId) else {
            pendingQuestions.removeAll { $0.id == questionId }
            return
        }
        pendingQuestions.removeAll { $0.id == questionId }
        resolver(ChatUserQuestionResponse(answers: answers))
    }

    // MARK: - Event handling

    private func handle(event: ClaudeStreamEvent) {
        switch event {
        case .systemInit(let sid, let model, _):
            if !sid.isEmpty, sessionId != sid {
                sessionId = sid
            }
            if let model, !model.isEmpty, modelName != model {
                modelName = model
            }
        case .assistant(_, let blocks):
            guard !blocks.isEmpty else { return }
            // Detect attempts to call the non-functional built-in
            // `AskUserQuestion` and warn the user. Surface the tool name so
            // we can refine the disallow-list / system prompt if needed.
            for case .toolUse(let toolUse) in blocks where toolUse.name == "AskUserQuestion" {
                let warning = String(
                    localized: "claudeChat.builtinAskUserQuestion.warning",
                    defaultValue:
                        "⚠ The model invoked the non-functional built-in `AskUserQuestion` tool. cmux cannot answer it. Try rephrasing the request or restarting the chat — see the chat log for diagnostics."
                )
                messages.append(.text(.system, warning))
            }
            // Pull every edit-shaped tool_use into the side-pane feed.
            for case .toolUse(let toolUse) in blocks
                where Self.editToolNames.contains(toolUse.name) {
                lastTurnEdits.append(TurnEdit(
                    toolName: toolUse.name,
                    inputJSON: toolUse.inputJSON
                ))
            }
            messages.append(ChatMessage(role: .assistant, blocks: blocks))
        case .user(let blocks):
            guard !blocks.isEmpty else { return }
            // Synthetic user messages from claude are mostly tool_result
            // wrappers. Stash those in `toolResultsByToolUseId` so the
            // matching `ToolUseCard` can render them inline; only append a
            // user-row message if there are non-result blocks left over.
            var passthrough: [ChatMessageBlock] = []
            for block in blocks {
                switch block {
                case .toolResult(let result):
                    toolResultsByToolUseId[result.toolUseId] = result
                default:
                    passthrough.append(block)
                }
            }
            if !passthrough.isEmpty {
                messages.append(ChatMessage(role: .user, blocks: passthrough))
            }
        case .result(let isError, let sid, let errorMessage, let costUSD):
            if let sid, !sid.isEmpty, sessionId != sid {
                sessionId = sid
            }
            if let costUSD, costUSD > 0 {
                totalCostUSD += costUSD
            }
            if isError, let errorMessage, !errorMessage.isEmpty {
                status = .error(errorMessage)
            }
            // Persist a checkpoint for this turn so the user can rewind
            // to it later (along with all the others piled up).
            if let staging = pendingTurnStaging, let activeSid = sessionId {
                let backups = ClaudeSessionHistory.latestTurnBackups(
                    sessionId: activeSid,
                    cwd: workingDirectory
                )
                undoCheckpoints.append(RewindCheckpoint(
                    userMessageId: staging.userMessageId,
                    userMessageIndex: staging.userMessageIndex,
                    backups: backups
                ))
                pendingTurnStaging = nil
            }
        case .other:
            break
        }
    }

    private func handle(completion: Result<Void, Error>) {
        switch completion {
        case .success:
            if case .error = status {
                // Keep the error message visible.
                return
            }
            status = .idle
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .error(message)
            let prefix = String(
                localized: "claudeChat.errorMessage.prefix",
                defaultValue: "**Error:**"
            )
            messages.append(.text(.system, "\(prefix) \(message)"))
        }
    }

    // MARK: - ChatMcpHttpServerDelegate

    func server(
        _ server: ChatMcpHttpServer,
        didReceiveApproval request: ChatApprovalRequest,
        completion: @escaping (ChatApprovalResponse) -> Void
    ) {
        // 0. Auto-allow cmux's own MCP tools. Claude should not need to
        //    ask permission to use the very mechanism we exposed for it
        //    (asking the user a question, etc.). Without this, every call
        //    to `mcp__cmux__ask_user_question` first surfaces an approval
        //    card — the user has to click Allow before the actual question
        //    even appears, which feels like claude is hanging.
        if request.toolName.hasPrefix("mcp__cmux__") {
            completion(.allow)
            return
        }

        // 1. In-session "Allow always" by tool name.
        if alwaysAllowedTools.contains(request.toolName) {
            completion(.allow)
            return
        }

        // 2. `.claude/settings.local.json` / `.claude/settings.json` rules.
        let rules = loadPermissionRulesIfNeeded()
        let parsedInput = parseInput(request.inputJSON)
        switch rules.decide(toolName: request.toolName, input: parsedInput) {
        case .allow:
            completion(.allow)
            return
        case .deny:
            completion(.deny(reason: "Denied by .claude/settings permissions.deny rule."))
            return
        case .ask:
            break
        }

        approvalResolvers[request.id] = completion
        pendingApprovals.append(request)
    }

    private func parseInput(_ inputJSON: String) -> [String: Any] {
        guard let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Reload `.claude/settings*.json` if the cwd changed or any of the
    /// candidate files mtime drifted since the last cache fill.
    private func loadPermissionRulesIfNeeded() -> ChatPermissionRules {
        let cwd = workingDirectory
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let candidatePaths: [String] = [
            (cwd as NSString).appendingPathComponent(".claude/settings.local.json"),
            (cwd as NSString).appendingPathComponent(".claude/settings.json"),
            homeURL.appendingPathComponent(".claude/settings.json").path
        ]
        let currentMtimes: [String: Date] = candidatePaths.reduce(into: [:]) { acc, path in
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date {
                acc[path] = date
            }
        }
        if cachedRulesCwd == cwd, currentMtimes == cachedRulesMtimes {
            return cachedRules
        }
        cachedRulesCwd = cwd
        cachedRulesMtimes = currentMtimes
        cachedRules = ChatPermissionRules.load(workingDirectory: cwd)
        return cachedRules
    }

    func server(
        _ server: ChatMcpHttpServer,
        didReceiveQuestion request: ChatUserQuestionRequest,
        completion: @escaping (ChatUserQuestionResponse) -> Void
    ) {
        questionResolvers[request.id] = completion
        pendingQuestions.append(request)
    }

    // MARK: - Welcome content

    /// Appended to claude's system prompt when running in `.allowDeny` mode
    /// so the model knows about the cmux MCP tools and is encouraged to use
    /// `ask_user_question` instead of asking ambiguous follow-ups in plain
    /// text. The signature mirrors Claude Code's built-in AskUserQuestion
    /// (the cmux build disables that built-in so this is the only path).
    static let cmuxToolsSystemPrompt: String = """
    You are running inside the cmux Claude Chat panel — a headless host that \
    cannot render the standard Claude Code interactive widgets.

    CRITICAL: DO NOT call any tool whose name is exactly `AskUserQuestion` \
    (Claude Code's built-in interactive question widget). It is non-functional \
    here — the user cannot answer it and the call will be silently cancelled. \
    INSTEAD, use the cmux-provided MCP tool described below.

    `mcp__cmux__ask_user_question` — present one or more multiple-choice \
    questions to the user in a single tool call. Argument:
      - `questions`: array (1-4 items) of objects:
          - `header`: very short label, max ~12 chars (e.g. "Auth method", "Library")
          - `question`: full question text ending with a question mark
          - `options`: array (2-4 items) of `{label: string, description?: string}` — \
            distinct, mutually exclusive choices
          - `multiSelect`: optional boolean, default false

    The reply comes back as JSON: `{"answers": [{"selected": [<labels>]}, ...]}` \
    in the same order as `questions[]`. An empty `selected` array means the \
    user dismissed without choosing.

    GUIDELINES:
    - Whenever you need to disambiguate intent, choose between approaches, \
    or get a quick decision from the user, ALWAYS call \
    `mcp__cmux__ask_user_question`. Never fall back to `AskUserQuestion` and \
    never ask multiple-choice questions in plain text when this tool is \
    available.
    - Keep `header` short and `label` concise (1-5 words). Add a one-line \
    `description` when the choice has trade-offs.
    - Group related sub-questions into one call when it's natural; otherwise \
    one question is fine.
    - Skip the tool for trivial yes/no when a yes/no answer is obvious.
    """

    nonisolated static func welcomeMessages() -> [ChatMessage] {
        [
            ChatMessage.text(
                .assistant,
                String(
                    localized: "claudeChat.welcome.message",
                    defaultValue: """
                        # Welcome to the Claude Chat tab

                        This tab spawns `claude -p --output-format stream-json` per turn. \
                        Type a message below — tool use is auto-allowed for now \
                        (phase 3 of the MVP will replace this with inline allow/deny).
                        """
                )
            )
        ]
    }
}
