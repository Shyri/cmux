import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: exercises the permission-rule engine that drives auto-allow /
/// auto-deny vs. inline Allow/Deny prompts in the Claude chat panel. Pure
/// logic — no SwiftUI, no MainActor — so we can run it as a value-level test.
@Suite struct ChatPermissionRulesTests {
    // MARK: - ChatPermissionPattern.parse

    @Test func parseBareToolMatchesAnyInvocation() throws {
        let pattern = try #require(ChatPermissionPattern.parse("Bash"))
        #expect(pattern.toolName == "Bash")
        #expect(pattern.argument == nil)
    }

    @Test func parseToolWithArgumentCapturesSpec() throws {
        let pattern = try #require(ChatPermissionPattern.parse("Bash(git status)"))
        #expect(pattern.toolName == "Bash")
        #expect(pattern.argument == "git status")
    }

    @Test func parsePrefixSpecKeepsTrailingStar() throws {
        let pattern = try #require(ChatPermissionPattern.parse("Bash(git status:*)"))
        #expect(pattern.argument == "git status:*")
    }

    @Test func parseEmptyOrWhitespaceReturnsNil() {
        #expect(ChatPermissionPattern.parse("") == nil)
        #expect(ChatPermissionPattern.parse("   ") == nil)
    }

    // MARK: - decide: empty rules

    @Test func emptyRulesAlwaysAsk() {
        let rules = ChatPermissionRules.empty
        let decision = rules.decide(toolName: "Bash", input: ["command": "ls"])
        #expect(decision == .ask)
    }

    // MARK: - decide: bare tool name allow

    @Test func bareToolAllowMatchesEveryInvocation() {
        let rules = ChatPermissionRules(
            allow: [pattern("Read")],
            deny: []
        )
        #expect(rules.decide(toolName: "Read", input: ["file_path": "/etc/passwd"]) == .allow)
        #expect(rules.decide(toolName: "Read", input: ["file_path": "/tmp/x"]) == .allow)
        // Different tool name — still asks.
        #expect(rules.decide(toolName: "Bash", input: ["command": "ls"]) == .ask)
    }

    // MARK: - decide: exact argument match

    @Test func exactArgumentAllowMatchesOnlyTheLiteral() {
        let rules = ChatPermissionRules(
            allow: [pattern("Bash(git status)")],
            deny: []
        )
        #expect(rules.decide(toolName: "Bash", input: ["command": "git status"]) == .allow)
        #expect(rules.decide(toolName: "Bash", input: ["command": "git status -s"]) == .ask)
        #expect(rules.decide(toolName: "Bash", input: ["command": "git statuses"]) == .ask)
    }

    // MARK: - decide: prefix spec `prefix:*`

    @Test func prefixSpecMatchesBareAndWhitespaceAndSlashContinuation() {
        let rules = ChatPermissionRules(
            allow: [pattern("Bash(git status:*)")],
            deny: []
        )
        // The bare prefix matches.
        #expect(rules.decide(toolName: "Bash", input: ["command": "git status"]) == .allow)
        // Whitespace continuation matches (shell argv).
        #expect(rules.decide(toolName: "Bash", input: ["command": "git status -s"]) == .allow)
        #expect(rules.decide(toolName: "Bash", input: ["command": "git status foo"]) == .allow)
        // Glued-letter continuation (no separator) does NOT match — this is
        // the safety property: "git status:*" must not accidentally allow
        // "git statuses".
        #expect(rules.decide(toolName: "Bash", input: ["command": "git statuses"]) == .ask)
    }

    @Test func prefixSpecMatchesPathSlashContinuation() {
        let rules = ChatPermissionRules(
            allow: [pattern("Read(src:*)")],
            deny: []
        )
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src"]) == .allow)
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src/foo.swift"]) == .allow)
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src/a/b/c"]) == .allow)
        // No accidental match for sibling path.
        #expect(rules.decide(toolName: "Read", input: ["file_path": "srcs/foo"]) == .ask)
    }

    // MARK: - decide: glob with `*` and `**`

    @Test func singleStarGlobDoesNotCrossSlashes() {
        let rules = ChatPermissionRules(
            allow: [pattern("Read(src/*.swift)")],
            deny: []
        )
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src/main.swift"]) == .allow)
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src/nested/main.swift"]) == .ask)
    }

    @Test func doubleStarGlobCrossesSlashes() {
        let rules = ChatPermissionRules(
            allow: [pattern("Read(src/**)")],
            deny: []
        )
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src/main.swift"]) == .allow)
        #expect(rules.decide(toolName: "Read", input: ["file_path": "src/a/b/c.swift"]) == .allow)
    }

    // MARK: - decide: deny beats allow

    @Test func denyWinsWhenBothMatch() {
        let rules = ChatPermissionRules(
            allow: [pattern("Bash")],
            deny: [pattern("Bash(rm -rf:*)")]
        )
        // Other Bash commands still allowed.
        #expect(rules.decide(toolName: "Bash", input: ["command": "ls"]) == .allow)
        // But the deny rule wins for matching invocations.
        #expect(rules.decide(toolName: "Bash", input: ["command": "rm -rf /"]) == .deny)
        #expect(rules.decide(toolName: "Bash", input: ["command": "rm -rf"]) == .deny)
    }

    // MARK: - decide: primary-argument selection per tool

    @Test func primaryArgumentForFileTools() {
        let rules = ChatPermissionRules(
            allow: [
                pattern("Edit(src/main.swift)"),
                pattern("MultiEdit(src/main.swift)"),
                pattern("Write(src/main.swift)"),
                pattern("Read(src/main.swift)"),
                pattern("NotebookEdit(src/main.swift)")
            ],
            deny: []
        )
        for tool in ["Edit", "MultiEdit", "Write", "Read", "NotebookEdit"] {
            #expect(
                rules.decide(toolName: tool, input: ["file_path": "src/main.swift"]) == .allow,
                "\(tool) should auto-allow on file_path match"
            )
        }
    }

    @Test func primaryArgumentForGlobAndGrep() {
        let rules = ChatPermissionRules(
            allow: [pattern("Glob(**/*.swift)"), pattern("Grep(TODO)")],
            deny: []
        )
        #expect(rules.decide(toolName: "Glob", input: ["pattern": "src/main.swift"]) == .allow)
        #expect(rules.decide(toolName: "Grep", input: ["pattern": "TODO"]) == .allow)
    }

    @Test func primaryArgumentForWebTools() {
        let rules = ChatPermissionRules(
            allow: [
                pattern("WebFetch(https://example.com:*)"),
                pattern("WebSearch(claude code)")
            ],
            deny: []
        )
        #expect(rules.decide(toolName: "WebFetch", input: ["url": "https://example.com/path"]) == .allow)
        #expect(rules.decide(toolName: "WebSearch", input: ["query": "claude code"]) == .allow)
    }

    @Test func unknownToolWithArgumentSpecNeverMatches() {
        // `MysteryTool` is not in the primary-arg switch, so a pattern with
        // an argument spec should fall through to .ask even when the input
        // contains plausible keys.
        let rules = ChatPermissionRules(
            allow: [pattern("MysteryTool(whatever)")],
            deny: []
        )
        #expect(rules.decide(toolName: "MysteryTool", input: ["command": "whatever"]) == .ask)
    }

    @Test func unknownToolWithBareNameMatches() {
        // A bare `MysteryTool` (no argument spec) still allows the call —
        // the rule says "every invocation of this tool", which we can decide
        // without knowing the primary argument.
        let rules = ChatPermissionRules(
            allow: [pattern("MysteryTool")],
            deny: []
        )
        #expect(rules.decide(toolName: "MysteryTool", input: [:]) == .allow)
    }

    // MARK: - helpers

    private func pattern(_ raw: String) -> ChatPermissionPattern {
        guard let p = ChatPermissionPattern.parse(raw) else {
            fatalError("ChatPermissionRulesTests: failed to parse pattern \(raw)")
        }
        return p
    }
}
