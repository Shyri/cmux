import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the in-memory transcript retention bound that keeps
/// a long-running Claude Chat panel from growing its heap without limit.
/// `ClaudeChatPanel.trimmedTranscript` is the pure seam for that bound (the
/// panel itself spawns a `claude` subprocess and can't be unit-constructed),
/// so these tests exercise the eviction + the two reconciliations it must
/// perform: rebasing rewind checkpoints onto the shifted index space and
/// pruning `toolResultsByToolUseId` for evicted messages.
@Suite struct ClaudeTranscriptTrimTests {
    private func userMessage(_ n: Int) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text("msg \(n)")])
    }

    private func assistantWithTool(id: String) -> ChatMessage {
        ChatMessage(role: .assistant, blocks: [
            .toolUse(.init(id: id, name: "Bash", inputJSON: "{}"))
        ])
    }

    @Test func underCapIsNoOp() {
        let msgs = (0..<3).map { userMessage($0) }
        let result = ClaudeChatPanel.trimmedTranscript(
            messages: msgs, checkpoints: [], toolResults: [:], maxRetained: 10)
        #expect(result.messages == msgs)
        #expect(result.checkpoints.isEmpty)
        #expect(result.toolResults.isEmpty)
    }

    @Test func trimsOldestBeyondCapKeepingTail() {
        let msgs = (0..<10).map { userMessage($0) }
        let result = ClaudeChatPanel.trimmedTranscript(
            messages: msgs, checkpoints: [], toolResults: [:], maxRetained: 4)
        #expect(result.messages.count == 4)
        // The tail survives; the head (msg 0..5) is evicted.
        #expect(result.messages.first?.plainText == "msg 6")
        #expect(result.messages.last?.plainText == "msg 9")
    }

    @Test func rebasesSurvivingCheckpointsAndDropsEvicted() {
        let msgs = (0..<10).map { userMessage($0) }
        // One checkpoint anchored on an evicted message (index 2) and one
        // on a surviving message (index 7).
        let evicted = ClaudeChatPanel.RewindCheckpoint(
            userMessageId: msgs[2].id, userMessageIndex: 2, backups: nil)
        let survives = ClaudeChatPanel.RewindCheckpoint(
            userMessageId: msgs[7].id, userMessageIndex: 7, backups: nil)
        let result = ClaudeChatPanel.trimmedTranscript(
            messages: msgs, checkpoints: [evicted, survives],
            toolResults: [:], maxRetained: 4)
        // overflow == 6: index 7 rebases to 1, index 2 → -4 (dropped).
        #expect(result.checkpoints.count == 1)
        let survivor = try? #require(result.checkpoints.first)
        #expect(survivor?.userMessageId == msgs[7].id)
        #expect(survivor?.userMessageIndex == 1)
        // The rebased index must still point at the same user message so
        // `rewindTo` slices the transcript at the right spot.
        #expect(result.messages[survivor?.userMessageIndex ?? -1].id == msgs[7].id)
    }

    @Test func prunesToolResultsForEvictedMessagesOnly() {
        var msgs = (0..<8).map { userMessage($0) }
        msgs[1] = assistantWithTool(id: "old")   // evicted
        msgs[6] = assistantWithTool(id: "keep")   // retained
        let toolResults: [String: ChatMessageBlock.ToolResult] = [
            "old": .init(toolUseId: "old", content: "huge stale output", isError: false),
            "keep": .init(toolUseId: "keep", content: "recent output", isError: false),
        ]
        let result = ClaudeChatPanel.trimmedTranscript(
            messages: msgs, checkpoints: [], toolResults: toolResults, maxRetained: 4)
        // overflow == 4: indices 0..3 removed, so "old" is gone and "keep"
        // (index 6 → 2) stays, along with its result.
        #expect(result.toolResults["old"] == nil)
        #expect(result.toolResults["keep"] != nil)
        #expect(result.toolResults.count == 1)
    }
}
