import SwiftUI

/// Inline `/mcp`-style manager for the Claude chat panel. Lists every
/// MCP server visible to the running `claude` process — project-scoped
/// (`<cwd>/.mcp.json`), user-scoped (`~/.claude.json` →
/// `projects.<cwd>.mcpServers`) and the cmux builtin — colour-coded by
/// connection state pulled from the latest `system/init` event. Add /
/// edit / delete / reconnect actions are wired through
/// `McpServerCatalog` and `panel.reloadMcpRuntime()`.
struct McpManagerPopover: View {
    @ObservedObject var panel: ClaudeChatPanel
    @State private var editing: EditTarget?
    @State private var refreshNonce: Int = 0
    @Environment(\.dismiss) private var dismiss

    /// Identity used by the `.sheet(item:)` on the edit form. Carries a
    /// pre-filled config when editing an existing entry or a bare scope
    /// when adding a new one.
    struct EditTarget: Identifiable {
        var id: String { existing?.id ?? "new:\(scope.rawValue)" }
        let scope: McpServerConfig.Scope
        let existing: McpServerConfig?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(scope: .project, title: String(
                        localized: "claudeChat.mcp.scope.project.title",
                        defaultValue: "Project (.mcp.json)"
                    ), subtitle: String(
                        localized: "claudeChat.mcp.scope.project.subtitle",
                        defaultValue: "Committed to the repo and shared with teammates."
                    ))
                    section(scope: .userLocal, title: String(
                        localized: "claudeChat.mcp.scope.userLocal.title",
                        defaultValue: "User (~/.claude.json)"
                    ), subtitle: String(
                        localized: "claudeChat.mcp.scope.userLocal.subtitle",
                        defaultValue: "Private to you, scoped to this project."
                    ))
                    section(scope: .builtin, title: String(
                        localized: "claudeChat.mcp.scope.builtin.title",
                        defaultValue: "Built-in (cmux)"
                    ), subtitle: String(
                        localized: "claudeChat.mcp.scope.builtin.subtitle",
                        defaultValue: "Backs inline approval and ask-user-question. Not editable."
                    ))
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 400)
        }
        .padding(14)
        .frame(width: 460)
        .id(refreshNonce)
        .onAppear {
            panel.refreshMcpStatus()
        }
        .sheet(item: $editing) { target in
            McpServerEditor(
                panel: panel,
                existing: target.existing,
                scope: target.scope
            ) {
                editing = nil
                bumpRefresh()
                panel.reloadMcpRuntime()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.connected.to.line.below")
                .foregroundColor(ChatPalette.blue)
            Text(String(
                localized: "claudeChat.mcp.title",
                defaultValue: "MCP servers"
            ))
            .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                panel.refreshMcpStatus()
            } label: {
                Label(String(
                    localized: "claudeChat.mcp.refresh",
                    defaultValue: "Refresh"
                ), systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.mcp.refresh.tooltip",
                defaultValue: "Re-check connection status (claude mcp list). Does not affect the running session."
            ))
            Button {
                panel.reloadMcpRuntime()
            } label: {
                Label(String(
                    localized: "claudeChat.mcp.restart",
                    defaultValue: "Restart"
                ), systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.mcp.restart.tooltip",
                defaultValue: "Kill the claude process so every MCP reconnects with the current config. The next message respawns it."
            ))
        }
    }

    private func section(scope: McpServerConfig.Scope, title: String, subtitle: String) -> some View {
        let entries = entries(for: scope)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if scope != .builtin {
                    Button {
                        editing = EditTarget(scope: scope, existing: nil)
                    } label: {
                        Label(String(
                            localized: "claudeChat.mcp.add",
                            defaultValue: "Add"
                        ), systemImage: "plus")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            if entries.isEmpty {
                Text(String(
                    localized: "claudeChat.mcp.empty.section",
                    defaultValue: "No servers configured."
                ))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(entries) { server in
                        row(server)
                    }
                }
            }
        }
    }

    private func row(_ server: McpServerConfig) -> some View {
        let status = panel.mcpRuntimeStatus[server.name]
        let connection: McpConnectionStatus
        if let status {
            connection = McpConnectionStatus(rawStatus: status.status, errorMessage: status.error)
        } else {
            connection = .unknown
        }
        return HStack(spacing: 8) {
            statusDot(connection)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(transportSummary(server.transport))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusLabel(connection)
            Button {
                panel.reconnectMcpServer(name: server.name)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.mcp.reconnect.tooltip",
                defaultValue: "Re-check this server (claude mcp get). Updates the badge without restarting the session."
            ))
            if server.scope != .builtin {
                Button {
                    editing = EditTarget(scope: server.scope, existing: server)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(String(
                    localized: "claudeChat.mcp.edit.tooltip",
                    defaultValue: "Edit this server"
                ))
                Button {
                    deleteServer(server)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(String(
                    localized: "claudeChat.mcp.delete.tooltip",
                    defaultValue: "Delete this server from its config file"
                ))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground(for: connection))
        )
    }

    private func statusDot(_ status: McpConnectionStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
    }

    private func statusLabel(_ status: McpConnectionStatus) -> some View {
        let text = statusText(status)
        let tooltip = statusTooltip(status)
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(statusColor(status).opacity(0.15))
            )
            .help(tooltip ?? "")
    }

    private func statusText(_ status: McpConnectionStatus) -> String {
        switch status {
        case .connected:
            return String(
                localized: "claudeChat.mcp.status.connected",
                defaultValue: "Connected"
            )
        case .connecting:
            return String(
                localized: "claudeChat.mcp.status.connecting",
                defaultValue: "Connecting…"
            )
        case .failed:
            return String(
                localized: "claudeChat.mcp.status.failed",
                defaultValue: "Failed"
            )
        case .needsAuth:
            return String(
                localized: "claudeChat.mcp.status.needsAuth",
                defaultValue: "Needs auth"
            )
        case .unknown:
            return String(
                localized: "claudeChat.mcp.status.unknown",
                defaultValue: "Unknown"
            )
        }
    }

    private func statusTooltip(_ status: McpConnectionStatus) -> String? {
        if case .failed(let message) = status, let message, !message.isEmpty {
            return message
        }
        return nil
    }

    private func statusColor(_ status: McpConnectionStatus) -> Color {
        switch status {
        case .connected: return ChatPalette.green
        case .connecting: return ChatPalette.yellow
        case .failed: return ChatPalette.red
        case .needsAuth: return ChatPalette.orange
        case .unknown: return .secondary
        }
    }

    private func rowBackground(for status: McpConnectionStatus) -> Color {
        statusColor(status).opacity(0.08)
    }

    private func transportSummary(_ transport: McpServerConfig.Transport) -> String {
        switch transport {
        case .stdio(let command, let args, _):
            let argString = args.isEmpty ? "" : " " + args.joined(separator: " ")
            return "stdio · \(command)\(argString)"
        case .http(let url, _):
            return "http · \(url)"
        case .sse(let url, _):
            return "sse · \(url)"
        }
    }

    // MARK: - Data

    private func entries(for scope: McpServerConfig.Scope) -> [McpServerConfig] {
        // Read fresh each render so edits land immediately. `refreshNonce`
        // invalidates the surrounding view's identity after writes so the
        // disk read re-runs even when SwiftUI would otherwise reuse the
        // cached body.
        _ = refreshNonce
        let cwd = panel.workingDirectory
        switch scope {
        case .project:
            return McpServerCatalog.readProject(cwd: cwd)
        case .userLocal:
            return McpServerCatalog.readUserLocal(cwd: cwd)
        case .builtin:
            if let server = panel.builtinMcpServerConfig() {
                return [server]
            }
            return []
        }
    }

    private func deleteServer(_ server: McpServerConfig) {
        do {
            try McpServerCatalog.remove(name: server.name, scope: server.scope, cwd: panel.workingDirectory)
            bumpRefresh()
            panel.reloadMcpRuntime()
        } catch {
            #if DEBUG
            NSLog("McpManagerPopover.deleteServer failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func bumpRefresh() {
        refreshNonce &+= 1
    }
}

// MARK: - Editor sheet

/// Modal sheet that creates or edits one `McpServerConfig`. The scope
/// is fixed at presentation time (the caller picks where the entry
/// lives); the transport can be changed via picker.
struct McpServerEditor: View {
    let panel: ClaudeChatPanel
    let existing: McpServerConfig?
    let scope: McpServerConfig.Scope
    let onDone: () -> Void

    @State private var name: String = ""
    @State private var transportKind: TransportKind = .stdio
    @State private var command: String = ""
    @State private var argsLine: String = ""
    @State private var envLine: String = ""
    @State private var url: String = ""
    @State private var headersLine: String = ""
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    enum TransportKind: String, CaseIterable, Identifiable {
        case stdio
        case http
        case sse
        var id: String { rawValue }
        var label: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil
                 ? String(localized: "claudeChat.mcp.editor.titleNew",
                          defaultValue: "Add MCP server")
                 : String(localized: "claudeChat.mcp.editor.titleEdit",
                          defaultValue: "Edit MCP server"))
                .font(.system(size: 14, weight: .semibold))

            Form {
                LabeledContent(String(
                    localized: "claudeChat.mcp.editor.scope",
                    defaultValue: "Scope"
                )) {
                    Text(scopeLabel)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                TextField(String(
                    localized: "claudeChat.mcp.editor.name",
                    defaultValue: "Name"
                ), text: $name)
                .disabled(existing != nil)
                Picker(String(
                    localized: "claudeChat.mcp.editor.transport",
                    defaultValue: "Transport"
                ), selection: $transportKind) {
                    ForEach(TransportKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if transportKind == .stdio {
                    TextField(String(
                        localized: "claudeChat.mcp.editor.command",
                        defaultValue: "Command"
                    ), text: $command)
                    TextField(String(
                        localized: "claudeChat.mcp.editor.argsHint",
                        defaultValue: "Args (space-separated)"
                    ), text: $argsLine)
                    TextField(String(
                        localized: "claudeChat.mcp.editor.envHint",
                        defaultValue: "Env (KEY=VALUE per line)"
                    ), text: $envLine, axis: .vertical)
                    .lineLimit(2...5)
                } else {
                    TextField(String(
                        localized: "claudeChat.mcp.editor.url",
                        defaultValue: "URL"
                    ), text: $url)
                    TextField(String(
                        localized: "claudeChat.mcp.editor.headersHint",
                        defaultValue: "Headers (Name: Value per line)"
                    ), text: $headersLine, axis: .vertical)
                    .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(String(
                    localized: "claudeChat.mcp.editor.cancel",
                    defaultValue: "Cancel"
                )) {
                    onDone()
                }
                Button(String(
                    localized: "claudeChat.mcp.editor.save",
                    defaultValue: "Save"
                )) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefillFromExisting)
    }

    private var scopeLabel: String {
        switch scope {
        case .project: return String(
            localized: "claudeChat.mcp.scope.project.title",
            defaultValue: "Project (.mcp.json)"
        )
        case .userLocal: return String(
            localized: "claudeChat.mcp.scope.userLocal.title",
            defaultValue: "User (~/.claude.json)"
        )
        case .builtin: return String(
            localized: "claudeChat.mcp.scope.builtin.title",
            defaultValue: "Built-in (cmux)"
        )
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch transportKind {
        case .stdio:
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return !url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func prefillFromExisting() {
        guard let existing else { return }
        name = existing.name
        switch existing.transport {
        case .stdio(let cmd, let args, let env):
            transportKind = .stdio
            command = cmd
            argsLine = args.joined(separator: " ")
            envLine = env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        case .http(let url, let headers):
            transportKind = .http
            self.url = url
            headersLine = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        case .sse(let url, let headers):
            transportKind = .sse
            self.url = url
            headersLine = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport: McpServerConfig.Transport
        switch transportKind {
        case .stdio:
            let args = parseArgs(argsLine)
            let env = parseEnv(envLine)
            transport = .stdio(command: command.trimmingCharacters(in: .whitespaces), args: args, env: env)
        case .http:
            let headers = parseHeaders(headersLine)
            transport = .http(url: url.trimmingCharacters(in: .whitespaces), headers: headers)
        case .sse:
            let headers = parseHeaders(headersLine)
            transport = .sse(url: url.trimmingCharacters(in: .whitespaces), headers: headers)
        }
        let server = McpServerConfig(name: trimmedName, scope: scope, transport: transport)
        do {
            try McpServerCatalog.upsert(server, cwd: panel.workingDirectory)
            onDone()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func parseArgs(_ raw: String) -> [String] {
        raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    private func parseEnv(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private func parseHeaders(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                out[key] = value
            }
        }
        return out
    }
}
