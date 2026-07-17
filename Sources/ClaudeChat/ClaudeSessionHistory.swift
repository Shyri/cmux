import Foundation

/// Reads Claude Code's per-session JSONL transcript and the file-history
/// snapshots it stores under `~/.claude/file-history/<sessionId>/`. cmux
/// uses these to power the "undo last turn" button: claude already tracks
/// the file contents for us, we just need to find and copy them back.
enum ClaudeSessionHistory {
    /// File backups captured by Claude Code at the start of a turn — i.e.
    /// the state of each touched file before claude modified it.
    struct TurnFileBackups {
        let sessionId: String
        /// Map of absolute file path → URL of the backup blob inside
        /// `~/.claude/file-history/<sessionId>/`.
        let backups: [String: URL]
    }

    /// Find the latest non-empty `file-history-snapshot` event in the
    /// JSONL for `sessionId` and return the file→backup map. The "latest"
    /// snapshot represents the pre-state of the most recent turn that
    /// touched files.
    static func latestTurnBackups(
        sessionId: String,
        cwd: String
    ) -> TurnFileBackups? {
        guard let jsonlURL = transcriptURL(sessionId: sessionId, cwd: cwd),
              let data = try? Data(contentsOf: jsonlURL),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let historyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/file-history", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)

        var latest: [String: URL] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "file-history-snapshot",
                  let snapshot = obj["snapshot"] as? [String: Any],
                  let backups = snapshot["trackedFileBackups"] as? [String: [String: Any]],
                  !backups.isEmpty
            else { continue }

            // Each later snapshot supersedes earlier ones for the same path
            // (Claude Code rewrites the entry as new versions land).
            for (path, info) in backups {
                guard let backupName = info["backupFileName"] as? String else { continue }
                latest[path] = historyDir.appendingPathComponent(backupName)
            }
        }
        guard !latest.isEmpty else { return nil }
        return TurnFileBackups(sessionId: sessionId, backups: latest)
    }

    /// Restore the files in `backups` to disk, replacing whatever is at
    /// each path right now. Returns the paths that were restored
    /// successfully.
    @discardableResult
    static func restore(_ backups: TurnFileBackups) -> [String] {
        var restored: [String] = []
        for (path, backupURL) in backups.backups {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { continue }
            do {
                let data = try Data(contentsOf: backupURL)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                restored.append(path)
            } catch {
                #if DEBUG
                NSLog("ClaudeSessionHistory.restore failed path=\(path) err=\(error.localizedDescription)")
                #endif
            }
        }
        return restored
    }

    /// Read the per-session JSONL transcript written by the Claude Code
    /// CLI and return it as a list of `ChatMessage` ready to seed a
    /// `ClaudeChatPanel`'s `initialMessages`. Used when the Sessions
    /// panel asks us to resume a Claude Code session inside a chat
    /// panel — the panel shows the full conversation immediately and
    /// the runner picks up the same `--resume <sessionId>` from there.
    ///
    /// The JSONL written by Claude Code is *not* identical to the
    /// stream-json `claude -p` emits: each line carries metadata
    /// (parentUuid, timestamp, gitBranch…) and the `message.content`
    /// of a user line can be a String *or* an array of blocks. We parse
    /// it defensively — malformed lines are skipped, never abort the
    /// load. Returns `nil` if the file doesn't exist or can't be read.
    static func loadTranscript(
        sessionId: String,
        cwd: String,
        knownTranscriptURL: URL? = nil
    ) async -> [ChatMessage]? {
        await Task.detached(priority: .userInitiated) { () -> [ChatMessage]? in
            // Prefer the exact JSONL the caller already located on disk (the
            // Vault scan's `entry.fileURL`). Recomputing the path from `cwd`
            // is unreliable: Claude Code names the project-dir folder after the
            // session's *launch* cwd, but a session that cd'd into a worktree
            // reports later, different cwds — so the recomputed folder misses
            // the file and the panel would open blank. Fall back to the
            // recomputed path only when no known URL is usable.
            let jsonlURL: URL
            if let knownTranscriptURL,
               FileManager.default.fileExists(atPath: knownTranscriptURL.path) {
                jsonlURL = knownTranscriptURL
            } else if let computed = transcriptURL(sessionId: sessionId, cwd: cwd),
                      FileManager.default.fileExists(atPath: computed.path) {
                jsonlURL = computed
            } else if let scanned = locateTranscriptBySessionId(sessionId) {
                // Encoding-agnostic last resort. The session id is globally
                // unique, so scan every `~/.claude/projects/<dir>/` for
                // `<sessionId>.jsonl`. This rescues cold-start restore of
                // worktree chats: their recomputed cwd folder never matches
                // the launch-cwd folder Claude actually wrote under, so the
                // branch above misses and — without this — the panel opens
                // blank even though `--resume` still continues the session.
                // (The Vault panel sidesteps all of this by passing the
                // scan-located `knownTranscriptURL`.)
                jsonlURL = scanned
            } else {
                return nil
            }

            // Read only the tail of the transcript. Claude Code JSONLs
            // routinely reach tens of MB (large tool outputs, base64
            // images); slurping the whole file into a `Data` + `String`
            // here spiked memory badly on restore. `tailText` memory-maps
            // the file and materializes only the most recent lines.
            guard let text = tailText(of: jsonlURL, maxLines: maxRestoreTranscriptLines)
            else { return nil }

            let messages = decodeTranscript(text: text)
            return messages.isEmpty ? nil : messages
        }.value
    }

    /// Locate a session's JSONL by scanning every Claude Code project
    /// directory for `<sessionId>.jsonl`. Used as the encoding-agnostic
    /// fallback in `loadTranscript` when neither a caller-supplied URL nor
    /// the cwd-recomputed path resolves (the git-worktree cold-start case).
    /// Returns `nil` when no matching transcript exists on disk.
    static func locateTranscriptBySessionId(_ sessionId: String) -> URL? {
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        return locateTranscript(sessionId: sessionId, inProjectsRoot: projectsRoot)
    }

    /// Testable core of `locateTranscriptBySessionId`: search the immediate
    /// child directories of `projectsRoot` for a file named
    /// `<sessionId>.jsonl`. The session id is a globally-unique UUID, so the
    /// first match is authoritative regardless of how the parent folder's
    /// cwd was encoded.
    static func locateTranscript(sessionId: String, inProjectsRoot projectsRoot: URL) -> URL? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let target = "\(sessionId).jsonl"
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent(target)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Maximum number of transcript lines read from the tail of a session
    /// JSONL on restore. Mirrors the bounded mobile tailer
    /// (`AgentChatTranscriptTailer`'s `maxInitialLines`) so restoring a
    /// huge session materializes only the most recent turns instead of the
    /// entire file.
    static let maxRestoreTranscriptLines = 2000

    /// Return at most the last `maxLines` newline-delimited lines of the
    /// file at `url`, as a single String. The file is memory-mapped so its
    /// bytes stay file-backed (and evictable under pressure) while only the
    /// bounded tail is decoded into a heap String. Returns `nil` when the
    /// file can't be mapped, `""` when it's empty. A trailing line without
    /// a terminating newline is kept as-is (a partial JSON line simply
    /// fails to decode downstream, which `decodeTranscript` already skips).
    static func tailText(of url: URL, maxLines: Int) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        guard !data.isEmpty else { return "" }

        // Byte offset of every line start: 0, then one past each '\n'.
        var lineStarts: [Int] = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count where raw[index] == 0x0A {
                lineStarts.append(index + 1)
            }
        }
        // When the file ends with '\n' the final recorded start sits at EOF
        // and begins no real line — drop it so it isn't counted.
        if lineStarts.count > 1, lineStarts.last == data.count {
            lineStarts.removeLast()
        }
        let firstIndex = max(0, lineStarts.count - max(1, maxLines))
        let byteStart = lineStarts[firstIndex]
        return String(decoding: data[byteStart..<data.count], as: UTF8.self)
    }

    /// Parse the raw JSONL transcript text into renderable `ChatMessage`s,
    /// skipping metadata lines and `thinking` blocks. Split out from
    /// `loadTranscript` (which owns the file I/O) so the line-decoding
    /// contract — string vs. array user content, tool_use/tool_result
    /// mapping, thinking suppression — can be unit-tested with fixture
    /// text instead of a real `~/.claude/projects` file.
    static func decodeTranscript(text: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            if let message = decodeTranscriptLine(obj) {
                messages.append(message)
            }
        }
        return messages
    }

    /// Compute the path of the JSONL transcript for a session given the
    /// chat's cwd. Claude Code stores transcripts under
    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where the
    /// encoded cwd replaces both `/` and `.` with `-` (the leading slash
    /// becomes a leading `-`).
    static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let encoded = encodeCwd(cwd)
        guard !encoded.isEmpty else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Private

    /// Convert one decoded JSONL line into a `ChatMessage`. Returns nil
    /// for metadata lines (worktree-state, file-history-snapshot,
    /// attachment, last-prompt, system) and for `user`/`assistant`
    /// lines whose content yields no blocks the chat panel can render.
    private static func decodeTranscriptLine(_ obj: [String: Any]) -> ChatMessage? {
        let type = obj["type"] as? String ?? ""
        switch type {
        case "user":
            let message = obj["message"] as? [String: Any] ?? [:]
            let blocks = decodeUserMessageContent(message["content"])
            guard !blocks.isEmpty else { return nil }
            return ChatMessage(role: .user, blocks: blocks)
        case "assistant":
            let message = obj["message"] as? [String: Any] ?? [:]
            let contentArray = message["content"] as? [[String: Any]] ?? []
            let blocks = contentArray.compactMap { decodeTranscriptContentBlock($0) }
            guard !blocks.isEmpty else { return nil }
            return ChatMessage(role: .assistant, blocks: blocks)
        default:
            return nil
        }
    }

    /// `user.message.content` can be a plain string (typed prompt) or
    /// an array of blocks (tool_result lines after the assistant ran
    /// tools). Handle both.
    private static func decodeUserMessageContent(_ raw: Any?) -> [ChatMessageBlock] {
        if let str = raw as? String {
            // Reuse the Vault's shared user-line cleanup (SessionEntry):
            // hide harness-injected synthetic envelopes (task-notification,
            // system-reminder, local-command) and normalize slash-command
            // envelopes to the command the user actually ran. nil => render
            // nothing for this line.
            guard let display = SessionEntry.claudeDisplayTitle(from: str) else { return [] }
            return [.text(display)]
        }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { decodeTranscriptContentBlock($0) }
        }
        return []
    }

    /// Mirrors `ClaudeStreamEvent.decodeContentBlock` but lives here so
    /// the chat module can hydrate transcripts without depending on the
    /// live stream parser. `thinking` blocks are persisted by Claude
    /// Code but the chat panel doesn't render them, so they're skipped.
    private static func decodeTranscriptContentBlock(_ block: [String: Any]) -> ChatMessageBlock? {
        guard let type = block["type"] as? String else { return nil }
        switch type {
        case "text":
            guard let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .text(text)
        case "tool_use":
            let id = (block["id"] as? String) ?? ""
            let name = (block["name"] as? String) ?? "unknown"
            let inputAny = block["input"] ?? [:]
            return .toolUse(.init(
                id: id,
                name: name,
                inputJSON: encodeJSONValue(inputAny)
            ))
        case "tool_result":
            let toolUseId = (block["tool_use_id"] as? String) ?? ""
            let isError = (block["is_error"] as? Bool) ?? false
            return .toolResult(.init(
                toolUseId: toolUseId,
                content: stringifyTranscriptToolResultContent(block["content"]),
                isError: isError
            ))
        case "thinking":
            return nil
        default:
            return nil
        }
    }

    private static func stringifyTranscriptToolResultContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if let t = item["type"] as? String, t == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            .joined(separator: "\n")
        }
        return ""
    }

    private static func encodeJSONValue(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.sortedKeys, .prettyPrinted]
           ) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }

    private static func encodeCwd(_ path: String) -> String {
        // Mirror Claude Code's filename convention. Normalize away surrounding
        // slashes (so a trailing "/" doesn't leak a trailing "-"), re-add the
        // leading slash, then delegate to the SAME encoder the Vault scan uses
        // (`RestorableAgentSessionIndex.encodeClaudeProjectDir`), which replaces
        // both "/" and "." with "-". Sharing that one encoder keeps resume and
        // scan agreeing on the project dir; the previous local copy only
        // replaced "/", so any dotted cwd resolved to the wrong folder and
        // reopened with no history.
        let trimmed = path.trimmingCharacters(in: .init(charactersIn: "/"))
        return RestorableAgentSessionIndex.encodeClaudeProjectDir("/" + trimmed)
    }
}
