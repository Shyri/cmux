import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: canaries for the seams where the fork's Claude Chat panel
/// plugs into upstream types. These are the exact spots an upstream merge
/// breaks — a renamed/removed enum case, a dropped persistence field, a
/// changed raw value. They're cheap and deterministic, and they fail loudly
/// the moment a sync regresses fork integration, which is why the
/// `/sync-upstream` gate runs them.
@Suite struct ChatmuxUpstreamSeamTests {
    // MARK: - PanelType.claudeChat (persistence wire identifier)

    @Test func panelTypeClaudeChatRawValueIsStable() {
        // This string is persisted on disk in session snapshots. If a merge
        // changes it, every saved Claude Chat panel fails to restore.
        #expect(PanelType.claudeChat.rawValue == "claudeChat")
    }

    @Test func panelTypeClaudeChatDecodesFromRawValue() {
        #expect(PanelType(rawValue: "claudeChat") == .claudeChat)
    }

    @Test func panelTypeClaudeChatCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(PanelType.claudeChat)
        // Single-value enum encodes to the bare string.
        #expect(String(data: data, encoding: .utf8) == "\"claudeChat\"")
        let decoded = try JSONDecoder().decode(PanelType.self, from: data)
        #expect(decoded == .claudeChat)
    }

    // MARK: - SurfaceKind.claudeChat (fork extension on the upstream type)

    @Test func surfaceKindClaudeChatRawValueIsStable() {
        #expect(SurfaceKind.claudeChat.rawValue == "claudeChat")
    }

    @Test func surfaceKindClaudeChatIsDistinctFromUpstreamKinds() {
        let others: [SurfaceKind] = [
            .terminal, .browser, .markdown, .filePreview, .rightSidebarTool,
            .customSidebar, .agentSession, .project, .extensionBrowser,
        ]
        #expect(others.contains(.claudeChat) == false)
        #expect(Set(others.map(\.rawValue)).contains("claudeChat") == false)
    }

    // MARK: - SessionClaudeChatPanelSnapshot round-trip

    @Test func claudeChatSnapshotRoundTripsThroughCodable() throws {
        let snapshot = SessionClaudeChatPanelSnapshot(
            sessionId: "sess-abc",
            workingDirectory: "/tmp/proj",
            transcriptPath: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionClaudeChatPanelSnapshot.self, from: data)
        #expect(decoded.sessionId == "sess-abc")
        #expect(decoded.workingDirectory == "/tmp/proj")
        #expect(decoded.transcriptPath == nil)
    }

    // MARK: - SessionPanelSnapshot persistence canary

    @Test func sessionPanelSnapshotDecodesClaudeChatFieldFromDisk() throws {
        // Mirrors what session restore reads off disk for a saved chat pane.
        // If a merge drops the `claudeChat` Codable field, this leaves the
        // field nil and the test fails — exactly the breakage class the last
        // sync hit in SessionPanelSnapshot.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "type": "claudeChat",
          "isPinned": false,
          "isManuallyUnread": false,
          "listeningPorts": [],
          "claudeChat": {
            "sessionId": "restore-me",
            "workingDirectory": "/work/dir",
            "transcriptPath": null
          }
        }
        """
        let data = Data(json.utf8)
        let snap = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        #expect(snap.type == .claudeChat)
        #expect(snap.claudeChat?.sessionId == "restore-me")
        #expect(snap.claudeChat?.workingDirectory == "/work/dir")
    }

    @Test func sessionPanelSnapshotClaudeChatSurvivesEncodeDecodeCycle() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "type": "claudeChat",
          "isPinned": true,
          "isManuallyUnread": false,
          "listeningPorts": [3000],
          "claudeChat": { "sessionId": "rt", "workingDirectory": "/d" }
        }
        """
        let first = try JSONDecoder().decode(SessionPanelSnapshot.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder().encode(first)
        let second = try JSONDecoder().decode(SessionPanelSnapshot.self, from: reencoded)
        #expect(second.type == .claudeChat)
        #expect(second.claudeChat?.sessionId == "rt")
        #expect(second.claudeChat?.workingDirectory == "/d")
        #expect(second.isPinned == true)
    }
}
