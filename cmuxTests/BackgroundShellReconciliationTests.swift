import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: the "Background shells" popover kept showing shells as
/// "Running" long after they had exited. cmux is a passive observer of the
/// `claude` CLI, so the only reliable "the shell finished" signal is the
/// `<task-notification>…<status>completed|failed|killed</status>` the harness
/// injects — which lands in the transcript as a `.text` block of a `role: .user`
/// message. On resume/reopen, `applyResumedTranscript` rebuilds the list from
/// the transcript but historically only replayed the `Bash` tool_use/tool_result
/// blocks (which leave every shell `.running`) and ignored those notifications.
///
/// These tests reconstruct that exact path and assert the terminal state is
/// recovered. Without the reconciliation fix they fail (the shell stays
/// `.running`).
@MainActor
@Suite struct BackgroundShellReconciliationTests {
    private func bashToolUse(id: String, command: String) -> ChatMessageBlock {
        let input = try! JSONSerialization.data(
            withJSONObject: ["command": command, "run_in_background": true]
        )
        return .toolUse(.init(
            id: id,
            name: "Bash",
            inputJSON: String(data: input, encoding: .utf8) ?? "{}"
        ))
    }

    private func taskNotification(taskId: String, toolUseId: String, status: String) -> ChatMessageBlock {
        .text(
            "<task-notification> <task-id>\(taskId)</task-id> "
            + "<tool-use-id>\(toolUseId)</tool-use-id> "
            + "<output-file>/tmp/tasks/\(taskId).output</output-file> "
            + "<status>\(status)</status> </task-notification>"
        )
    }

    private func resumedPanel(status: String, toolUseId: String, shellId: String) -> ClaudeChatPanel {
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, blocks: [
                bashToolUse(id: toolUseId, command: "sleep 100")
            ]),
            ChatMessage(role: .user, blocks: [
                .toolResult(.init(
                    toolUseId: toolUseId,
                    content: "Command running in background with ID: \(shellId)",
                    isError: false
                ))
            ]),
            ChatMessage(role: .user, blocks: [
                taskNotification(taskId: shellId, toolUseId: toolUseId, status: status)
            ])
        ]
        panel.applyResumedTranscript(sessionId: "sess1", messages: messages)
        return panel
    }

    @Test func resumeReconcilesCompletedShell() {
        let panel = resumedPanel(status: "completed", toolUseId: "toolu_bg1", shellId: "sh_done")
        #expect(panel.backgroundShells.count == 1)
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected .completed, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func resumeReconcilesFailedShell() {
        let panel = resumedPanel(status: "failed", toolUseId: "toolu_bg2", shellId: "sh_fail")
        guard case .completed = panel.backgroundShells.first?.status else {
            Issue.record("expected failed→completed, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }

    @Test func resumeLeavesShellWithoutNotificationRunning() {
        // A shell whose notification never arrived must stay live, not be
        // spuriously marked terminal.
        let panel = ClaudeChatPanel(workspaceId: UUID(), workingDirectory: "/tmp")
        let toolUseId = "toolu_bg3"
        let messages: [ChatMessage] = [
            ChatMessage(role: .assistant, blocks: [
                bashToolUse(id: toolUseId, command: "cd /x && flutter run")
            ]),
            ChatMessage(role: .user, blocks: [
                .toolResult(.init(
                    toolUseId: toolUseId,
                    content: "Command running in background with ID: sh_live",
                    isError: false
                ))
            ])
        ]
        panel.applyResumedTranscript(sessionId: "sess2", messages: messages)
        #expect(panel.backgroundShells.count == 1)
        guard case .running = panel.backgroundShells.first?.status else {
            Issue.record("expected still .running, got \(String(describing: panel.backgroundShells.first?.status))")
            return
        }
    }
}
