import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the streaming-text accumulator that turns the raw
/// `claude -p` NDJSON into the incremental text the chat bubble appends.
/// Its job is to emit each new chunk exactly once — the dedup between the
/// streamed `content_block_delta`s and the final whole `assistant` message
/// is the subtle part (get it wrong and the answer renders twice).
@Suite struct ClaudeStreamJSONAccumulatorTests {
    @Test func contentBlockDeltaEmitsItsText() {
        var acc = ClaudeStreamJSONAccumulator()
        let out = acc.consumeLine(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#)
        #expect(out == ["Hello"])
    }

    @Test func messageStartEmitsNothing() {
        var acc = ClaudeStreamJSONAccumulator()
        let out = acc.consumeLine(#"{"type":"message_start","message":{"role":"assistant","id":"m1"}}"#)
        #expect(out.isEmpty)
    }

    @Test func emptyOrInvalidLinesEmitNothing() {
        var acc = ClaudeStreamJSONAccumulator()
        #expect(acc.consumeLine("").isEmpty)
        #expect(acc.consumeLine("   ").isEmpty)
        #expect(acc.consumeLine("not json").isEmpty)
        #expect(acc.consumeLine("[1,2]").isEmpty)
    }

    @Test func finalAssistantMessageEmitsOnlyTheUnstreamedSuffix() {
        var acc = ClaudeStreamJSONAccumulator()
        _ = acc.consumeLine(#"{"type":"message_start","message":{"role":"assistant","id":"m1"}}"#)
        #expect(acc.consumeLine(#"{"type":"content_block_delta","delta":{"text":"Hello"}}"#) == ["Hello"])
        // The whole assistant message arrives carrying "Hello world"; only
        // " world" is new, so only that is emitted (no re-render of "Hello").
        let out = acc.consumeLine(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello world"}]}}"#)
        #expect(out == [" world"])
    }

    @Test func finalAssistantMessageIdenticalToStreamEmitsNothing() {
        var acc = ClaudeStreamJSONAccumulator()
        _ = acc.consumeLine(#"{"type":"message_start","message":{"role":"assistant","id":"m1"}}"#)
        _ = acc.consumeLine(#"{"type":"content_block_delta","delta":{"text":"Hello world"}}"#)
        // Everything was already streamed — the final message must add nothing.
        let out = acc.consumeLine(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello world"}]}}"#)
        #expect(out.isEmpty)
    }

    @Test func assistantMessageWithoutPriorDeltasEmitsFullText() {
        var acc = ClaudeStreamJSONAccumulator()
        // No streaming deltas happened first (non-partial mode): emit it whole.
        let out = acc.consumeLine(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Fresh answer"}]}}"#)
        #expect(out == ["Fresh answer"])
    }

    @Test func resultStringEmittedOnlyWhenNoAssistantTextYet() {
        var acc = ClaudeStreamJSONAccumulator()
        // A turn that produced no assistant text falls back to the result string.
        let out = acc.consumeLine(#"{"type":"result","result":"final-only answer"}"#)
        #expect(out == ["final-only answer"])
    }

    @Test func resultStringSuppressedAfterAssistantTextEmitted() {
        var acc = ClaudeStreamJSONAccumulator()
        _ = acc.consumeLine(#"{"type":"content_block_delta","delta":{"text":"streamed"}}"#)
        // Assistant text already shown — the result string would duplicate it.
        let out = acc.consumeLine(#"{"type":"result","result":"streamed"}"#)
        #expect(out.isEmpty)
    }

    // MARK: - completesAssistantTurn

    @Test func completesAssistantTurnRecognizesTerminalTypes() {
        #expect(ClaudeStreamJSONAccumulator.completesAssistantTurn(#"{"type":"result"}"#))
        #expect(ClaudeStreamJSONAccumulator.completesAssistantTurn(#"{"type":"message_stop"}"#))
        #expect(ClaudeStreamJSONAccumulator.completesAssistantTurn(#"{"type":"done"}"#))
    }

    @Test func completesAssistantTurnFalseForNonTerminal() {
        #expect(ClaudeStreamJSONAccumulator.completesAssistantTurn(#"{"type":"assistant"}"#) == false)
        #expect(ClaudeStreamJSONAccumulator.completesAssistantTurn(#"{"type":"content_block_delta"}"#) == false)
        #expect(ClaudeStreamJSONAccumulator.completesAssistantTurn("garbage") == false)
    }
}
