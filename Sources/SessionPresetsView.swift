import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionPresetsView: View {
    @ObservedObject private var store = SessionPresetStore.shared
    @State private var selection: UUID?
    @State private var renamingId: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260)
            detail
                .frame(minWidth: 320)
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear {
            store.loadIfNeeded()
            if selection == nil {
                selection = store.activePresetId ?? store.presets.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionPresetsDidChange)) { _ in
            if let selection, store.preset(for: selection) == nil {
                self.selection = store.presets.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.presets) { preset in
                    presetRow(preset)
                        .tag(preset.id)
                        .contextMenu { contextMenu(for: preset) }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Button {
                    AppDelegate.shared?.presentSaveCurrentSessionAsPresetPrompt()
                } label: {
                    Image(systemName: "plus")
                }
                .help(String(localized: "presets.action.saveFromCurrent.help", defaultValue: "Save current session as a new preset"))

                Button {
                    if let id = selection {
                        confirmAndDelete(id)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help(String(localized: "presets.action.delete.help", defaultValue: "Delete selected preset"))

                Button {
                    if let id = selection { _ = store.duplicate(id: id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(selection == nil)
                .help(String(localized: "presets.action.duplicate.help", defaultValue: "Duplicate selected preset"))

                Spacer()

                Menu {
                    Button(String(localized: "presets.action.import", defaultValue: "Import…")) {
                        importPreset()
                    }
                    Button(String(localized: "presets.action.export", defaultValue: "Export…")) {
                        if let id = selection { exportPreset(id) }
                    }
                    .disabled(selection == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: SessionPreset) -> some View {
        HStack(spacing: 6) {
            if renamingId == preset.id {
                TextField("", text: $renameDraft, onCommit: { commitRename(preset) })
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { renamingId = nil }
            } else {
                Text(preset.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if store.activePresetId == preset.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .help(String(localized: "presets.label.active", defaultValue: "Active preset"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            loadPreset(preset)
        }
    }

    @ViewBuilder
    private func contextMenu(for preset: SessionPreset) -> some View {
        Button(String(localized: "presets.action.load", defaultValue: "Load")) {
            loadPreset(preset)
        }
        Button(String(localized: "presets.action.updateFromCurrent", defaultValue: "Update from Current Session")) {
            updatePresetFromCurrent(preset)
        }
        Divider()
        Button(String(localized: "presets.action.rename", defaultValue: "Rename…")) {
            beginRename(preset)
        }
        Button(String(localized: "presets.action.duplicate", defaultValue: "Duplicate")) {
            _ = store.duplicate(id: preset.id)
        }
        Divider()
        Button(String(localized: "presets.action.export", defaultValue: "Export…")) {
            exportPreset(preset.id)
        }
        Divider()
        Button(String(localized: "presets.action.delete", defaultValue: "Delete"), role: .destructive) {
            confirmAndDelete(preset.id)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let id = selection, let preset = store.preset(for: id) {
                detailContent(preset)
            } else {
                VStack {
                    Spacer()
                    Text(String(localized: "presets.empty.title", defaultValue: "No preset selected"))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(String(localized: "presets.empty.subtitle", defaultValue: "Save the current session as a preset, or pick one from the list."))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    @ViewBuilder
    private func detailContent(_ preset: SessionPreset) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if renamingId == preset.id {
                    TextField("", text: $renameDraft, onCommit: { commitRename(preset) })
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onExitCommand { renamingId = nil }
                } else {
                    Text(preset.name)
                        .font(.title2.weight(.semibold))
                    Button {
                        beginRename(preset)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "presets.action.rename", defaultValue: "Rename…"))
                }
                Spacer()
                if store.activePresetId == preset.id {
                    Label(
                        String(localized: "presets.label.active", defaultValue: "Active preset"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundColor(.accentColor)
                    .font(.subheadline)
                }
            }

            statsBlock(preset)

            HStack(spacing: 8) {
                Button(String(localized: "presets.action.load", defaultValue: "Load")) {
                    loadPreset(preset)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(String(localized: "presets.action.updateFromCurrent", defaultValue: "Update from Current Session")) {
                    updatePresetFromCurrent(preset)
                }

                Button(String(localized: "presets.action.duplicate", defaultValue: "Duplicate")) {
                    _ = store.duplicate(id: preset.id)
                }

                Spacer()

                Button(String(localized: "presets.action.export", defaultValue: "Export…")) {
                    exportPreset(preset.id)
                }

                Button(String(localized: "presets.action.delete", defaultValue: "Delete")) {
                    confirmAndDelete(preset.id)
                }
                .tint(.red)
            }

            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func statsBlock(_ preset: SessionPreset) -> some View {
        let workspaceCount = preset.snapshot.windows.reduce(0) { $0 + $1.tabManager.workspaces.count }
        let panelCount = preset.snapshot.windows.reduce(0) { acc, win in
            acc + win.tabManager.workspaces.reduce(0) { $0 + $1.panels.count }
        }
        VStack(alignment: .leading, spacing: 6) {
            statRow(
                String(localized: "presets.detail.windows", defaultValue: "Windows"),
                value: "\(preset.snapshot.windows.count)"
            )
            statRow(
                String(localized: "presets.detail.workspaces", defaultValue: "Workspaces"),
                value: "\(workspaceCount)"
            )
            statRow(
                String(localized: "presets.detail.panels", defaultValue: "Panels"),
                value: "\(panelCount)"
            )
            statRow(
                String(localized: "presets.detail.created", defaultValue: "Created"),
                value: relativeDate(preset.createdAt)
            )
            statRow(
                String(localized: "presets.detail.updated", defaultValue: "Updated"),
                value: relativeDate(preset.updatedAt)
            )
        }
        .font(.callout)
        .foregroundColor(.secondary)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private func relativeDate(_ epoch: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Actions

    private func loadPreset(_ preset: SessionPreset) {
        AppDelegate.shared?.loadSessionPreset(preset)
    }

    private func updatePresetFromCurrent(_ preset: SessionPreset) {
        guard let snapshot = AppDelegate.shared?.currentSessionSnapshotForPreset() else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "presets.dialog.noSession.title",
                defaultValue: "Nothing to save"
            )
            alert.informativeText = String(
                localized: "presets.dialog.noSession.message",
                defaultValue: "There are no open windows to save as a preset."
            )
            alert.runModal()
            return
        }
        _ = store.update(id: preset.id, snapshot: snapshot)
    }

    private func beginRename(_ preset: SessionPreset) {
        renameDraft = preset.name
        renamingId = preset.id
    }

    private func commitRename(_ preset: SessionPreset) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != preset.name {
            _ = store.rename(id: preset.id, to: trimmed)
        }
        renamingId = nil
    }

    private func confirmAndDelete(_ id: UUID) {
        guard let preset = store.preset(for: id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "presets.dialog.delete.title.format",
                defaultValue: "Delete preset \u{201C}%@\u{201D}?"
            ),
            preset.name
        )
        alert.informativeText = String(
            localized: "presets.dialog.delete.message",
            defaultValue: "This cannot be undone. The current session is not affected."
        )
        alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.delete(id: id)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "presets.import.panelTitle",
            defaultValue: "Import Session Preset"
        )
        panel.prompt = String(localized: "presets.import.panelPrompt", defaultValue: "Import")
        if let presetType = UTType(filenameExtension: SessionPresetSchema.fileExtension) {
            panel.allowedContentTypes = [presetType, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let imported = store.importFromURL(url) {
            selection = imported.id
        } else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "presets.import.failed.title",
                defaultValue: "Import failed"
            )
            alert.informativeText = String(
                localized: "presets.import.failed.message",
                defaultValue: "The selected file is not a valid cmux preset."
            )
            alert.runModal()
        }
    }

    private func exportPreset(_ id: UUID) {
        guard let preset = store.preset(for: id) else { return }
        let panel = NSSavePanel()
        panel.title = String(
            localized: "presets.export.panelTitle",
            defaultValue: "Export Session Preset"
        )
        panel.nameFieldStringValue = sanitizedFilename(preset.name)
        if let presetType = UTType(filenameExtension: SessionPresetSchema.fileExtension) {
            panel.allowedContentTypes = [presetType]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.exportToURL(id: id, url) {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "presets.export.failed.title",
                defaultValue: "Export failed"
            )
            alert.informativeText = String(
                localized: "presets.export.failed.message",
                defaultValue: "Could not write the preset to the selected location."
            )
            alert.runModal()
        }
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\u{0000}")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "preset" : trimmed
    }
}
