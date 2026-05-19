import SwiftUI

/// Inline `/bashes`-style panel for the Claude chat. Lists every Bash
/// invocation we have seen run with `run_in_background: true`, with
/// its current state (starting / running / completed / killed) and a
/// Kill button that asks claude to invoke `KillShell`. We intentionally
/// don't surface the shell's output — the user wants visibility and
/// control, not log streaming.
struct BackgroundShellsPopover: View {
    @ObservedObject var panel: ClaudeChatPanel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if panel.backgroundShells.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(panel.backgroundShells) { shell in
                            row(shell)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(14)
        .frame(width: 460)
    }

    private var header: some View {
        let running = panel.backgroundShells.filter { isLive($0.status) }.count
        return HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundColor(ChatPalette.cyan)
            Text(String(
                localized: "claudeChat.bashes.title",
                defaultValue: "Background shells"
            ))
            .font(.system(size: 13, weight: .semibold))
            if running > 0 {
                Text("(\(running))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.bashes.empty",
                defaultValue: "No background shells. They appear here when claude runs Bash with run_in_background: true."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func row(_ shell: ClaudeChatPanel.BackgroundShell) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot(shell.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(shell.commandPreview)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let shellId = shell.shellId, !shellId.isEmpty {
                        Text(shellId)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text(String(
                            localized: "claudeChat.bashes.noId",
                            defaultValue: "(no shell_id yet)"
                        ))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    statusBadge(shell.status)
                }
            }
            Spacer(minLength: 8)
            actionButtons(for: shell)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground(for: shell.status))
        )
    }

    @ViewBuilder
    private func actionButtons(for shell: ClaudeChatPanel.BackgroundShell) -> some View {
        if isLive(shell.status), let shellId = shell.shellId, !shellId.isEmpty {
            Button {
                panel.killBackgroundShell(shellId: shellId)
            } label: {
                Label(String(
                    localized: "claudeChat.bashes.kill",
                    defaultValue: "Kill"
                ), systemImage: "xmark.octagon")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.bashes.kill.tooltip",
                defaultValue: "Ask claude to run KillShell on this shell"
            ))
        } else {
            Button {
                panel.dismissBackgroundShell(toolUseId: shell.toolUseId)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.bashes.dismiss.tooltip",
                defaultValue: "Hide this row from the list"
            ))
        }
    }

    private func statusDot(_ status: ClaudeChatPanel.BackgroundShell.Status) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
            .padding(.top, 3)
    }

    private func statusBadge(_ status: ClaudeChatPanel.BackgroundShell.Status) -> some View {
        Text(statusText(status))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(statusColor(status).opacity(0.15)))
    }

    private func statusText(_ status: ClaudeChatPanel.BackgroundShell.Status) -> String {
        switch status {
        case .starting:
            return String(
                localized: "claudeChat.bashes.status.starting",
                defaultValue: "Starting…"
            )
        case .running:
            return String(
                localized: "claudeChat.bashes.status.running",
                defaultValue: "Running"
            )
        case .completed(let code):
            if let code, !code.isEmpty {
                return String(
                    format: String(
                        localized: "claudeChat.bashes.status.completedCode",
                        defaultValue: "Exited (%@)"
                    ),
                    code
                )
            }
            return String(
                localized: "claudeChat.bashes.status.completed",
                defaultValue: "Exited"
            )
        case .killed:
            return String(
                localized: "claudeChat.bashes.status.killed",
                defaultValue: "Killed"
            )
        case .unknown:
            return String(
                localized: "claudeChat.bashes.status.unknown",
                defaultValue: "Unknown"
            )
        }
    }

    private func statusColor(_ status: ClaudeChatPanel.BackgroundShell.Status) -> Color {
        switch status {
        case .starting: return ChatPalette.yellow
        case .running: return ChatPalette.cyan
        case .completed: return ChatPalette.green
        case .killed: return ChatPalette.red
        case .unknown: return .secondary
        }
    }

    private func rowBackground(for status: ClaudeChatPanel.BackgroundShell.Status) -> Color {
        statusColor(status).opacity(0.08)
    }

    private func isLive(_ status: ClaudeChatPanel.BackgroundShell.Status) -> Bool {
        switch status {
        case .starting, .running, .unknown: return true
        case .completed, .killed: return false
        }
    }
}
