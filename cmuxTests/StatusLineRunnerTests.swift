import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the status-line runner that replicates Claude Code's
/// `statusLine` setting for the headless `-p` chat (the CLI doesn't run it
/// for us). Pins config loading from `.claude/settings.json`, the stdin JSON
/// contract, output trimming, and failure handling.
@Suite struct StatusLineRunnerTests {
    // MARK: - loadConfig

    @Test func loadConfigReadsCommandFromProjectSettings() throws {
        try withTemporaryCwd { cwd in
            try writeSettings(#"{"statusLine":{"type":"command","command":"echo hi"}}"#, named: "settings.json", in: cwd)
            let config = try #require(StatusLineRunner.loadConfig(cwd: cwd.path))
            #expect(config.command == "echo hi")
            #expect(config.sourcePath.hasSuffix(".claude/settings.json"))
        }
    }

    @Test func loadConfigPrefersSettingsLocalOverShared() throws {
        try withTemporaryCwd { cwd in
            try writeSettings(#"{"statusLine":{"type":"command","command":"SHARED"}}"#, named: "settings.json", in: cwd)
            try writeSettings(#"{"statusLine":{"type":"command","command":"LOCAL"}}"#, named: "settings.local.json", in: cwd)
            let config = try #require(StatusLineRunner.loadConfig(cwd: cwd.path))
            #expect(config.command == "LOCAL")
        }
    }

    @Test func loadConfigDefaultsTypeToCommand() throws {
        try withTemporaryCwd { cwd in
            // Missing "type" defaults to "command".
            try writeSettings(#"{"statusLine":{"command":"no-type"}}"#, named: "settings.json", in: cwd)
            let config = try #require(StatusLineRunner.loadConfig(cwd: cwd.path))
            #expect(config.command == "no-type")
        }
    }

    // MARK: - run

    @Test func runReturnsTrimmedStdout() throws {
        try withTemporaryCwd { cwd in
            let out = StatusLineRunner.run(
                config: .init(command: "printf '  STATUS  \\n'", sourcePath: "x"),
                info: info(cwd: cwd.path),
                userPATH: nil
            )
            #expect(out == "STATUS")
        }
    }

    @Test func runFeedsSessionJSONOnStdin() throws {
        try withTemporaryCwd { cwd in
            // `cat` echoes whatever we piped on stdin — proving the JSON payload
            // contract Claude Code documents is actually delivered.
            let out = StatusLineRunner.run(
                config: .init(command: "cat", sourcePath: "x"),
                info: info(cwd: cwd.path, sessionId: "sess-9", modelId: "claude-opus-4-8"),
                userPATH: nil
            )
            let text = try #require(out)
            #expect(text.contains("\"hook_event_name\""))
            #expect(text.contains("\"session_id\""))
            #expect(text.contains("sess-9"))
            // JSONSerialization escapes `/` as `\/`, so match the slash-free
            // temp dir name rather than the full path.
            #expect(text.contains(cwd.lastPathComponent))
        }
    }

    @Test func runReturnsNilOnEmptyOutput() throws {
        try withTemporaryCwd { cwd in
            let out = StatusLineRunner.run(
                config: .init(command: "true", sourcePath: "x"),
                info: info(cwd: cwd.path),
                userPATH: nil
            )
            #expect(out == nil)
        }
    }

    @Test func runReturnsNilOnNonZeroExit() throws {
        try withTemporaryCwd { cwd in
            let out = StatusLineRunner.run(
                config: .init(command: "echo oops; exit 3", sourcePath: "x"),
                info: info(cwd: cwd.path),
                userPATH: nil
            )
            #expect(out == nil)
        }
    }

    // MARK: - helpers

    private func info(
        cwd: String,
        sessionId: String? = nil,
        modelId: String? = nil
    ) -> StatusLineRunner.SessionInfo {
        StatusLineRunner.SessionInfo(
            sessionId: sessionId,
            transcriptPath: nil,
            cwd: cwd,
            modelId: modelId,
            version: "1.2.3"
        )
    }

    private func writeSettings(_ json: String, named name: String, in cwd: URL) throws {
        let dir = cwd.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func withTemporaryCwd(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StatusLineRunnerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
