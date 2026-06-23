import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the dedupe rule that suppresses duplicate Allow/Deny
/// cards when claude re-fires the same tool_use under a fresh `tool_use_id`.
/// The same logic lived inline in `ClaudeChatPanel.server(_:didReceiveApproval:)`
/// before; it was extracted into `ChatApprovalDedupePolicy` so it can be
/// driven without booting the SwiftUI panel.
///
/// Bug class this guards (from the recent session):
/// "hay veces que pide por duplicado permisos, eso por qué es?"
@Suite struct ChatApprovalDedupePolicyTests {
    typealias Key = ChatApprovalDedupePolicy.PendingApprovalKey

    @Test func emptyQueueAlwaysReturnsNewPrimary() {
        let decision = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{"command":"ls"}"#,
            pendingApprovals: []
        )
        #expect(decision == .newPrimary)
    }

    @Test func differentToolNameProducesNewPrimaryEvenWithIdenticalInputJSON() {
        let pending = [Key(id: "first", toolName: "Bash", inputJSON: #"{"command":"ls"}"#)]
        let decision = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Read",
            incomingInputJSON: #"{"command":"ls"}"#,
            pendingApprovals: pending
        )
        #expect(decision == .newPrimary)
    }

    @Test func differentInputJSONProducesNewPrimaryEvenWithSameToolName() {
        let pending = [Key(id: "first", toolName: "Bash", inputJSON: #"{"command":"ls"}"#)]
        let decision = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{"command":"ls -la"}"#,
            pendingApprovals: pending
        )
        #expect(decision == .newPrimary)
    }

    @Test func sameToolAndInputAttachesAsAliasOfPrimary() {
        // Claude re-fires the same tool_use with a fresh id; the policy must
        // route the second request to the first card's resolver chain so the
        // user only sees one Allow/Deny prompt.
        let pending = [Key(id: "primary-id", toolName: "Bash", inputJSON: #"{"command":"ls"}"#)]
        let decision = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{"command":"ls"}"#,
            pendingApprovals: pending
        )
        #expect(decision == .followsExisting(primaryID: "primary-id"))
    }

    @Test func aliasReturnsTheFirstMatchingPrimary() {
        // Two pending cards happen to share the same (toolName, inputJSON);
        // the policy attaches to the *first* match (queue order), so the
        // panel keeps a single canonical alias chain even in pathological
        // states.
        let pending = [
            Key(id: "first", toolName: "Bash", inputJSON: #"{"command":"ls"}"#),
            Key(id: "second", toolName: "Bash", inputJSON: #"{"command":"ls"}"#)
        ]
        let decision = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{"command":"ls"}"#,
            pendingApprovals: pending
        )
        #expect(decision == .followsExisting(primaryID: "first"))
    }

    @Test func unrelatedPendingPromptsDoNotAffectDecision() {
        let pending = [
            Key(id: "a", toolName: "WebFetch", inputJSON: #"{"url":"https://example.com"}"#),
            Key(id: "b", toolName: "Bash", inputJSON: #"{"command":"ls"}"#),
            Key(id: "c", toolName: "Read", inputJSON: #"{"file_path":"/etc/passwd"}"#)
        ]

        // Match the middle entry.
        let middle = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{"command":"ls"}"#,
            pendingApprovals: pending
        )
        #expect(middle == .followsExisting(primaryID: "b"))

        // No match anywhere.
        let novel = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{"command":"echo hi"}"#,
            pendingApprovals: pending
        )
        #expect(novel == .newPrimary)
    }

    @Test func dedupeIsByteExactOnInputJSON() {
        // Two semantically-equivalent JSON inputs with whitespace differences
        // are NOT collapsed: dedupe is a byte-exact match because the panel
        // uses claude's verbatim payload as the key (any normalization is
        // upstream of this policy).
        let pending = [Key(id: "first", toolName: "Bash", inputJSON: #"{"command":"ls"}"#)]
        let decision = ChatApprovalDedupePolicy.decide(
            incomingToolName: "Bash",
            incomingInputJSON: #"{ "command" : "ls" }"#,
            pendingApprovals: pending
        )
        #expect(decision == .newPrimary)
    }

    @Test func pendingApprovalKeyIsEquatable() {
        let a = Key(id: "x", toolName: "Bash", inputJSON: "{}")
        let b = Key(id: "x", toolName: "Bash", inputJSON: "{}")
        let differentID = Key(id: "y", toolName: "Bash", inputJSON: "{}")
        #expect(a == b)
        #expect(a != differentID)
    }
}
