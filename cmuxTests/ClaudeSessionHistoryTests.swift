import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers Claude Code transcript resolution + parsing, which
/// powers "resume this session in a chat panel". The cwd→path encoding is
/// the bug-prone part: `claude --resume <id>` reads
/// `~/.claude/projects/<encoded-cwd>/<id>.jsonl`, so a wrong encoding yields
/// "No conversation found".
@Suite struct ClaudeSessionHistoryTests {
    // MARK: - transcriptURL cwd encoding

    @Test func transcriptURLEncodesSimpleCwd() throws {
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "abc", cwd: "/tmp/proj"))
        #expect(url.path.hasSuffix(".claude/projects/-tmp-proj/abc.jsonl"))
    }

    @Test func transcriptURLEncodesNestedCwd() throws {
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "sid", cwd: "/Users/me/code/app"))
        #expect(url.path.hasSuffix(".claude/projects/-Users-me-code-app/sid.jsonl"))
    }

    @Test func transcriptURLStripsTrailingSlash() throws {
        let withSlash = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "s", cwd: "/tmp/proj/"))
        #expect(withSlash.path.hasSuffix(".claude/projects/-tmp-proj/s.jsonl"))
    }

    @Test func transcriptURLEncodesDottedCwd() throws {
        // Claude Code encodes BOTH "/" and "." as "-" in the project dir name.
        // A cwd containing a dot ("my.project", a worktree path, etc.) must
        // resolve to the same folder the Vault scan indexed
        // (RestorableAgentSessionIndex.encodeClaudeProjectDir), or "Resume in
        // New Tab" opens an empty chat because loadTranscript can't find the
        // JSONL. Regression for the encodeCwd-vs-scan divergence.
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "sid", cwd: "/Users/me/my.project"))
        #expect(url.path.hasSuffix(".claude/projects/-Users-me-my-project/sid.jsonl"))
    }

    @Test func transcriptURLEncodesDotfileCwd() throws {
        // Dotfiles collapse "/." into "--" just like the scan encoder does.
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "s", cwd: "/Users/me/.config/app"))
        #expect(url.path.hasSuffix(".claude/projects/-Users-me--config-app/s.jsonl"))
    }

    @Test func transcriptURLLivesUnderHomeClaudeProjects() throws {
        let url = try #require(ClaudeSessionHistory.transcriptURL(sessionId: "s", cwd: "/x"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(url.path.hasPrefix(home))
        #expect(url.path.contains("/.claude/projects/"))
    }

    // MARK: - loadTranscript path resolution

    @Test func loadTranscriptPrefersKnownURLOverRecomputedCwd() async throws {
        // When a session cd'd into a worktree, Claude fixes the on-disk
        // project-dir folder to the *launch* cwd, so it no longer matches the
        // cwd the Vault scan extracts from the JSONL (the last `cwd` in the
        // head wins). Recomputing the path from that cwd then misses the file
        // and the panel opens blank. The exact URL the scan already located
        // must win over the recomputed cwd. Regression for the worktree
        // "Resume in New Tab opens an empty chat" bug.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("6ec2b538.jsonl")
        try (#"{"type":"user","message":{"content":"restored history"}}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let messages = try #require(await ClaudeSessionHistory.loadTranscript(
            sessionId: "6ec2b538",
            cwd: "/nonexistent/worktree/cwd/mismatch",
            knownTranscriptURL: file
        ))
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "restored history")
    }

    // MARK: - decodeTranscript

    @Test func decodeTranscriptParsesUserStringAndAssistantBlocks() {
        let jsonl = """
        {"type":"user","message":{"content":"Hello claude"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Hi there"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"out","is_error":false}]}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 3)

        #expect(messages[0].role == .user)
        #expect(messages[0].plainText == "Hello claude")

        #expect(messages[1].role == .assistant)
        #expect(messages[1].blocks.first == .text("Hi there"))
        guard case let .toolUse(toolUse) = messages[1].blocks.last else {
            Issue.record("expected trailing toolUse block")
            return
        }
        #expect(toolUse.name == "Bash")

        #expect(messages[2].role == .user)
        guard case let .toolResult(result) = messages[2].blocks.first else {
            Issue.record("expected toolResult block")
            return
        }
        #expect(result.toolUseId == "t1")
        #expect(result.content == "out")
    }

    @Test func decodeTranscriptSkipsThinkingBlocks() {
        let jsonl = """
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret reasoning"},{"type":"text","text":"visible"}]}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].blocks == [.text("visible")])
    }

    @Test func decodeTranscriptSkipsMetadataAndMalformedLines() {
        let jsonl = """
        {"type":"file-history-snapshot","snapshot":{}}
        {"type":"system","subtype":"init"}
        not-json-at-all
        {"type":"summary"}
        {"type":"user","message":{"content":"real message"}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "real message")
    }

    @Test func decodeTranscriptHidesSyntheticEnvelopes() {
        // task-notification / system-reminder lines are harness-injected
        // synthetic "user" messages, not something the user typed. On restore
        // they must not render as user bubbles of raw XML.
        let jsonl = """
        {"type":"user","message":{"content":"<task-notification><task-id>x</task-id><summary>done</summary></task-notification>"}}
        {"type":"user","message":{"content":"<system-reminder>be brief</system-reminder>"}}
        {"type":"user","message":{"content":"real question"}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "real question")
    }

    @Test func decodeTranscriptNormalizesSlashCommandEnvelope() {
        // A slash-command envelope renders as the clean command the user ran,
        // not the raw <command-*> XML.
        let jsonl = #"{"type":"user","message":{"content":"<command-message>mr-review</command-message><command-name>/mr-review</command-name><command-args>39</command-args>"}}"#
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "/mr-review 39")
    }

    @Test func decodeTranscriptDropsEmptyUserContent() {
        let jsonl = """
        {"type":"user","message":{"content":"   "}}
        {"type":"user","message":{"content":"kept"}}
        """
        let messages = ClaudeSessionHistory.decodeTranscript(text: jsonl)
        #expect(messages.count == 1)
        #expect(messages[0].plainText == "kept")
    }

    @Test func decodeTranscriptEmptyTextReturnsEmpty() {
        #expect(ClaudeSessionHistory.decodeTranscript(text: "").isEmpty)
        #expect(ClaudeSessionHistory.decodeTranscript(text: "\n\n").isEmpty)
    }

    // MARK: - tailText bounded restore read

    /// Restoring a session must not slurp a multi-MB JSONL into memory:
    /// `tailText` materializes only the most recent `maxLines` lines.
    @Test func tailTextReturnsOnlyTheLastLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = (0..<5000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)

        let tail = try #require(ClaudeSessionHistory.tailText(of: url, maxLines: 2000))
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 2000)
        #expect(lines.first == "line 3000")
        #expect(lines.last == "line 4999")
    }

    @Test func tailTextShorterThanLimitReturnsEveryLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\nb\nc\n".write(to: url, atomically: true, encoding: .utf8)

        let tail = try #require(ClaudeSessionHistory.tailText(of: url, maxLines: 2000))
        #expect(tail == "a\nb\nc\n")
    }

    /// A final line without a terminating newline is kept intact.
    @Test func tailTextHandlesNoTrailingNewline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "first\nsecond".write(to: url, atomically: true, encoding: .utf8)

        let tail = try #require(ClaudeSessionHistory.tailText(of: url, maxLines: 1))
        #expect(tail == "second")
    }

    @Test func tailTextMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing.jsonl")
        #expect(ClaudeSessionHistory.tailText(of: url, maxLines: 10) == nil)
    }

    // MARK: - locateTranscript (encoding-agnostic session scan)

    /// Regression: on a cold-start restore, a worktree chat opened blank
    /// because the cwd-recomputed project folder didn't match the launch-cwd
    /// folder Claude actually wrote under. The by-session-id scan must find
    /// the transcript under *any* project folder name.
    @Test func locateTranscriptFindsSessionUnderMismatchedFolderName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A folder name that no cwd encoding the caller recomputes would
        // produce — stands in for the worktree mismatch.
        let projectDir = root.appendingPathComponent(
            "-some-worktree-encoded-oddly", isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let sessionId = UUID().uuidString
        let jsonl = projectDir.appendingPathComponent("\(sessionId).jsonl")
        try "{}\n".write(to: jsonl, atomically: true, encoding: .utf8)

        let found = ClaudeSessionHistory.locateTranscript(
            sessionId: sessionId, inProjectsRoot: root)
        #expect(found?.path == jsonl.path)
    }

    @Test func locateTranscriptReturnsNilWhenAbsent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        #expect(ClaudeSessionHistory.locateTranscript(
            sessionId: UUID().uuidString, inProjectsRoot: root) == nil)
    }

    @Test func locateTranscriptReturnsNilForMissingRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-nope", isDirectory: true)
        #expect(ClaudeSessionHistory.locateTranscript(
            sessionId: "abc", inProjectsRoot: root) == nil)
    }
}
