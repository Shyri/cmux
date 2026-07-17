import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: dragging a directory from Finder into a chat inserts its
/// absolute path into the draft (no temp-copy), so a dropped path must not
/// collide with whatever the user already typed. Covers the pure spacing
/// rule; the directory-vs-file routing itself lives on the panel (which
/// spawns a subprocess and can't be unit-constructed).
@Suite struct ClaudeChatDroppedDirectoryTests {
    @Test func emptyDraftBecomesThePath() {
        #expect(ClaudeChatPanel.draft("", appendingPath: "/Users/x/proj") == "/Users/x/proj")
    }

    @Test func nonEmptyDraftGetsASingleSpaceSeparator() {
        #expect(ClaudeChatPanel.draft("look at", appendingPath: "/tmp/dir") == "look at /tmp/dir")
    }

    @Test func existingTrailingWhitespaceIsNotDoubled() {
        #expect(ClaudeChatPanel.draft("look at ", appendingPath: "/tmp/dir") == "look at /tmp/dir")
        #expect(ClaudeChatPanel.draft("line\n", appendingPath: "/tmp/dir") == "line\n/tmp/dir")
    }

    @Test func emptyPathLeavesDraftUnchanged() {
        #expect(ClaudeChatPanel.draft("keep me", appendingPath: "") == "keep me")
    }
}
