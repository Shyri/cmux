import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the slash-command surface (built-ins + custom
/// markdown commands discovered under `<cwd>/.claude/commands`). Pins the
/// built-in roster, prefix filtering, project-command discovery, and the
/// frontmatter-stripping body reader the panel forwards to claude.
@Suite struct SlashCommandRegistryTests {
    // MARK: - filter

    @Test func emptyPrefixReturnsAllCommands() {
        let all = SlashCommandRegistry.builtinCommands
        #expect(SlashCommandRegistry.filter(all, byPrefix: "").count == all.count)
    }

    @Test func prefixMatchesAreCaseInsensitive() {
        let all = SlashCommandRegistry.builtinCommands
        let lower = SlashCommandRegistry.filter(all, byPrefix: "cl")
        let upper = SlashCommandRegistry.filter(all, byPrefix: "CL")
        #expect(lower.map(\.name) == ["clear"])
        #expect(upper.map(\.name) == ["clear"])
    }

    @Test func nonMatchingPrefixReturnsEmpty() {
        let all = SlashCommandRegistry.builtinCommands
        #expect(SlashCommandRegistry.filter(all, byPrefix: "zzz").isEmpty)
    }

    // MARK: - built-in roster

    @Test func builtinRosterHasExpectedCommands() {
        let names = Set(SlashCommandRegistry.builtinCommands.map(\.name))
        for expected in ["clear", "rewind", "undo", "model", "permissions", "help", "mcp", "bashes"] {
            #expect(names.contains(expected), "missing built-in /\(expected)")
        }
    }

    @Test func builtinCommandIdentityAndTitle() throws {
        let clear = try #require(SlashCommandRegistry.builtinCommands.first { $0.name == "clear" })
        #expect(clear.id == "builtin:clear")
        #expect(clear.displayTitle == "/clear")
        #expect(clear.source == .builtin)
        #expect(clear.action == .runBuiltin(SlashCommandRegistry.BuiltinKey.clear))
    }

    // MARK: - project custom command discovery

    @Test func availableCommandsListsBuiltinsFirstThenProjectCustom() throws {
        try withTemporaryCwd { cwd in
            let commandsDir = cwd
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
            try "---\ndescription: Ship it\n---\nThe release body".write(
                to: commandsDir.appendingPathComponent("start-release.md"),
                atomically: true,
                encoding: .utf8
            )

            let commands = SlashCommandRegistry.availableCommands(cwd: cwd.path)
            // Built-ins lead.
            #expect(commands.first?.source == .builtin)
            // The project command is discovered with its frontmatter description.
            let custom = try #require(commands.first { $0.name == "start-release" })
            #expect(custom.description == "Ship it")
            #expect(custom.action == .sendAsPrompt)
            if case .projectCustom = custom.source {} else {
                Issue.record("expected projectCustom source, got \(custom.source)")
            }
        }
    }

    @Test func availableCommandsFallsBackToFirstContentLineForDescription() throws {
        try withTemporaryCwd { cwd in
            let commandsDir = cwd
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
            try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
            // No frontmatter, leading heading skipped, first real line wins.
            try "# Title\n\nDo the thing now".write(
                to: commandsDir.appendingPathComponent("doit.md"),
                atomically: true,
                encoding: .utf8
            )
            let commands = SlashCommandRegistry.availableCommands(cwd: cwd.path)
            let custom = try #require(commands.first { $0.name == "doit" })
            #expect(custom.description == "Do the thing now")
        }
    }

    // MARK: - readBody

    @Test func readBodyStripsFrontmatter() throws {
        try withTemporaryCwd { cwd in
            let file = cwd.appendingPathComponent("cmd.md")
            try "---\ndescription: x\nmodel: opus\n---\nThis is the prompt body.".write(
                to: file, atomically: true, encoding: .utf8
            )
            let command = SlashCommand(name: "cmd", description: "x", source: .projectCustom(file), action: .sendAsPrompt)
            #expect(SlashCommandRegistry.readBody(of: command) == "This is the prompt body.")
        }
    }

    @Test func readBodyReturnsWholeFileWhenNoFrontmatter() throws {
        try withTemporaryCwd { cwd in
            let file = cwd.appendingPathComponent("cmd.md")
            try "Just a plain prompt.".write(to: file, atomically: true, encoding: .utf8)
            let command = SlashCommand(name: "cmd", description: "", source: .projectCustom(file), action: .sendAsPrompt)
            #expect(SlashCommandRegistry.readBody(of: command) == "Just a plain prompt.")
        }
    }

    @Test func readBodyOfBuiltinIsEmpty() {
        let command = SlashCommand(name: "clear", description: "", source: .builtin, action: .runBuiltin("clear"))
        #expect(SlashCommandRegistry.readBody(of: command) == "")
    }

    // MARK: - helper

    private func withTemporaryCwd(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SlashCommandRegistryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}
