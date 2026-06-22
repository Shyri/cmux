import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

private func rightSidebarDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
nonisolated enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case feed
    case dock
    case gitlab
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: return String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .gitlab: return String(localized: "rightSidebar.mode.gitlab", defaultValue: "GitLab")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "books.vertical"
        case .feed: return "dot.radiowaves.left.and.right"
        case .dock: return "dock.rectangle"
        case .gitlab: return "arrow.triangle.merge"
        case .customSidebar: return "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
        case .dock: return .switchRightSidebarToDock
        case .gitlab: return .switchRightSidebarToGitlab
        case .customSidebar: return nil
        }
    }
}

extension RightSidebarMode {
    static let paneModes: [RightSidebarMode] = [.files, .find, .sessions]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}

nonisolated enum RightSidebarContentMountPolicy {
    static func shouldMountContent(isRightSidebarVisible: Bool, hasMountedContent: Bool) -> Bool {
        isRightSidebarVisible || hasMountedContent
    }
}

nonisolated enum FileExplorerRootSyncPolicy {
    static func shouldSyncFileExplorerStore(isRightSidebarVisible: Bool, mode: RightSidebarMode) -> Bool {
        guard isRightSidebarVisible else { return false }
        switch mode {
        case .files, .find:
            return true
        case .sessions, .feed, .dock, .gitlab, .customSidebar:
            return false
        }
    }
}

nonisolated enum RightSidebarDirectoryContext {
    static func normalizedDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dockRootDirectory(workspaceDirectory: String?, fallbackDirectory: String?) -> String? {
        normalizedDirectory(workspaceDirectory) ?? normalizedDirectory(fallbackDirectory)
    }
}

extension RightSidebarMode {
    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        modeShortcut(for: event, allowingAction: { _ in true })
    }

    static func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        for mode in RightSidebarMode.allCases {
            guard let action = mode.shortcutAction,
                  allowingAction(action),
                  mode.isAvailable(),
                  KeyboardShortcutSettings.shortcut(for: action).matches(event: event) else {
                continue
            }
            return mode
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToGitlab).matches(event: event),
           RightSidebarMode.gitlab.isAvailable() {
            return .gitlab
        }
        return nil
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    let titlebarHeight: CGFloat
    let workspaceId: UUID?
    var workspace: Workspace? = nil
    var editingNoteId: Binding<UUID?>? = nil
    let onResumeSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onClose: () -> Void

    @AppStorage("rightSidebar.notes.collapsed")
    private var notesCollapsed: Bool = false
    @AppStorage("rightSidebar.notes.height")
    private var notesPanelHeight: Double = 180
    @State private var notesDragStartHeight: CGFloat?
    @State private var isDraggingNotesDivider: Bool = false

    private static let notesPanelMinHeight: CGFloat = 80
    private static let notesPanelMaxHeight: CGFloat = 500

    @State private var modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    @State private var focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @State private var closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @StateObject private var dockStore = DockControlsStore()
    @State private var hasMountedRightSidebarContent = false
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    private let closeShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintX
    private let closeShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarCloseHintY
    private let focusShortcutHintXOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintX
    private let focusShortcutHintYOffset = ShortcutHintDebugSettings.defaultRightSidebarFocusHintY
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @AppStorage(RightSidebarBetaFeatureSettings.feedEnabledKey)
    private var feedEnabled = RightSidebarBetaFeatureSettings.defaultFeedEnabled
    @AppStorage(RightSidebarBetaFeatureSettings.dockEnabledKey)
    private var dockEnabled = RightSidebarBetaFeatureSettings.defaultDockEnabled

    // Re-reading the observable store inside modeBar causes SwiftUI to
    // track the pending count so the badge updates live when hooks push
    // new items.
    private var feedPendingCount: Int {
        FeedCoordinator.shared.store?.pending.count ?? 0
    }

    private var availableModes: [RightSidebarMode] {
        RightSidebarMode.availableModes(feedEnabled: feedEnabled, dockEnabled: dockEnabled)
    }

    private var modeBarItems: [RightSidebarModeBarItem] {
        availableModes.map { RightSidebarModeBarItem(kind: .mode($0)) }
    }

    private var focusShortcutHintAnimationValue: Bool {
        alwaysShowShortcutHints || (showModifierHoldHints && focusShortcutHintMonitor.isModifierPressed)
    }

    private func startShortcutHintMonitorsIfNeeded() {
        guard showModifierHoldHints else {
            stopShortcutHintMonitors()
            return
        }
        modeShortcutHintMonitor.start()
        focusShortcutHintMonitor.start()
        closeShortcutHintMonitor.start()
    }

    private func stopShortcutHintMonitors() {
        modeShortcutHintMonitor.stop()
        focusShortcutHintMonitor.stop()
        closeShortcutHintMonitor.stop()
    }

    var body: some View {
        VStack(spacing: 0) {
            notesHeaderSection
            modeBar
                .rightSidebarChromeBottomBorder()
            contentForMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shortcutHintVisibilityAnimation(value: focusShortcutHintAnimationValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RightSidebarKeyboardFocusBridge()
            .frame(width: 1, height: 1)
        )
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                let hintWindow = showModifierHoldHints ? window : nil
                modeShortcutHintMonitor.setHostWindow(hintWindow)
                focusShortcutHintMonitor.setHostWindow(hintWindow)
                closeShortcutHintMonitor.setHostWindow(hintWindow)
            }
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("RightSidebar")
        .onAppear {
            startShortcutHintMonitorsIfNeeded()
            if fileExplorerState.isVisible { hasMountedRightSidebarContent = true }
            fileExplorerState.refreshModeAvailability()
            synchronizeDockLifecycle()
        }
        .onDisappear {
            stopShortcutHintMonitors()
            synchronizeDockLifecycle(isRightSidebarVisible: false)
        }
        .onChange(of: showModifierHoldHints) { _, _ in
            startShortcutHintMonitorsIfNeeded()
        }
        .onChange(of: fileExplorerState.mode) { _, mode in
            synchronizeDockLifecycle(mode: mode)
        }
        .onChange(of: fileExplorerState.isVisible) { _, visible in
            if visible { hasMountedRightSidebarContent = true }
            synchronizeDockLifecycle(isRightSidebarVisible: visible)
        }
        .onChange(of: dockRootDirectory) { _, newValue in
            synchronizeDockLifecycle(rootDirectory: newValue, workspaceId: workspaceId)
        }
        .onChange(of: workspaceId) { _, newValue in
            synchronizeDockLifecycle(rootDirectory: dockRootDirectory, workspaceId: newValue)
        }
        .onChange(of: feedEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
        .onChange(of: dockEnabled) { _, _ in refreshModeAvailabilityAndFocusIfNeeded() }
    }

    private var modeBar: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        return ZStack {
            WindowDragHandleView()

            HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
                ForEach(modeBarItems) { item in
                    let shortcut = item.shortcutAction.map { KeyboardShortcutSettings.shortcut(for: $0) } ?? .unbound
                    ModeBarButton(
                        item: item,
                        isSelected: item.isSelected(
                            mode: fileExplorerState.mode
                        ),
                        badgeCount: item.mode == .feed ? feedPendingCount : 0,
                        shortcutHint: shortcut,
                        showsShortcutHint: ShortcutHintTitlebarPolicy.shouldShow(
                            shortcut: shortcut,
                            alwaysShowShortcutHints: alwaysShowShortcutHints,
                            modifierPressed: modeShortcutHintMonitor.isModifierPressed,
                            modifierHoldHintsEnabled: showModifierHoldHints
                        )
                    ) {
                        let mode = item.mode
                        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                            mode: mode,
                            focusFirstItem: true,
                            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                        ) != true {
                            selectMode(mode)
                        }
                    }
                }
                Spacer(minLength: 0)
                if fileExplorerState.mode.canOpenAsPane {
                    openAsPaneButton(mode: fileExplorerState.mode)
                }
                closeButton
            }
        }
        .rightSidebarChromeBar(leadingPadding: 4, trailingPadding: 6, height: titlebarHeight)
        .overlay(alignment: .topLeading) {
            focusShortcutHintOverlay
        }
        .background(TitlebarDoubleClickMonitorView())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RightSidebarModeBar")
        .reportRightSidebarChromeGeometryForBonsplitUITest(
            isVisible: true,
            titlebarHeight: titlebarHeight
        )
    }

    private func openAsPaneButton(mode: RightSidebarMode) -> some View {
        Button {
            onOpenAsPane(mode)
        } label: {
            HeaderChromeIconStyle.symbol("rectangle.split.2x1")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderOpenAsPaneIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
            keyPrefix: "rightSidebarHeaderOpenAsPane",
            isVisible: true
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
                mode.label
            )
        )
        .accessibilityIdentifier("RightSidebar.openAsPaneButton")
        .titlebarInteractiveControl()
    }

    private var closeButton: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let showsShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: closeShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        return ZStack {
            Button(action: onClose) {
                HeaderChromeIconStyle.symbol("xmark")
            }
            .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarHeaderCloseIcon"))
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: "rightSidebarHeaderClose",
                isVisible: true
            )
            .safeHelp(
                KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                    String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
                )
            )
            .accessibilityLabel(String(localized: "rightSidebar.close.accessibilityLabel", defaultValue: "Close Right Sidebar"))
            .accessibilityIdentifier("RightSidebar.closeButton")
        }
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .overlay(alignment: .top) {
            if showsShortcutHint {
                ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(
                        x: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintXOffset)),
                        y: CGFloat(ShortcutHintDebugSettings.clamped(closeShortcutHintYOffset))
                    )
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarCloseShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .rightSidebarHeaderControlAlignment()
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .titlebarInteractiveControl()
    }

    @ViewBuilder
    private var focusShortcutHintOverlay: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let shortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        let showsFocusShortcutHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: focusShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        if showsFocusShortcutHint {
            ShortcutHintPill(
                shortcut: shortcut,
                fontSize: 9,
                emphasis: 1.05
            )
                .padding(.leading, 6)
                .padding(.top, 5)
                .offset(
                    x: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintXOffset)),
                    y: CGFloat(ShortcutHintDebugSettings.clamped(focusShortcutHintYOffset))
                )
                .shortcutHintTransition()
                .accessibilityIdentifier("rightSidebarFocusShortcutHint")
                .allowsHitTesting(false)
                .zIndex(10)
        }
    }

    @ViewBuilder
    private var contentForMode: some View {
        if RightSidebarContentMountPolicy.shouldMountContent(isRightSidebarVisible: fileExplorerState.isVisible, hasMountedContent: hasMountedRightSidebarContent) {
            switch fileExplorerState.mode {
            case .files:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .files
                )
            case .find:
                FileExplorerPanelView(
                    store: fileExplorerStore,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .find
                )
            case .sessions:
                SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                    .onAppear {
                        sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                    }
            case .feed:
                FeedPanelView()
            case .dock:
                DockPanelView(rootDirectory: dockRootDirectory, workspaceId: workspaceId, store: dockStore)
            case .gitlab:
                if let ws = workspace {
                    GitLabSidebarView(workspace: ws)
                        .id(ws.id)
                } else {
                    Color.clear
                }
            case .customSidebar:
                EmptyView()
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var notesHeaderSection: some View {
        if let ws = workspace, let editingBinding = editingNoteId {
            VStack(spacing: 0) {
                notesHeaderBar(workspace: ws, editingNoteId: editingBinding)
                if !notesCollapsed {
                    WorkspaceNotesPanelView(
                        workspace: ws,
                        editingNoteId: editingBinding,
                        darkBackground: false,
                        showsHeader: false
                    )
                    .frame(height: clampedNotesHeight)
                    notesResizeDivider
                }
            }
            .rightSidebarChromeBottomBorder()
        }
    }

    private var clampedNotesHeight: CGFloat {
        let raw = CGFloat(notesPanelHeight)
        return min(max(raw, Self.notesPanelMinHeight), Self.notesPanelMaxHeight)
    }

    private func notesHeaderBar(
        workspace: Workspace,
        editingNoteId: Binding<UUID?>
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                notesCollapsed.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(notesCollapsed ? 0 : 90))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(notesCollapsed
                ? String(localized: "rightSidebar.notes.expand", defaultValue: "Expand notes")
                : String(localized: "rightSidebar.notes.collapse", defaultValue: "Collapse notes"))

            Text(String(localized: "notes.sidebar.title", defaultValue: "Notes"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !workspace.notes.isEmpty {
                Text("\(workspace.notes.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if !notesCollapsed,
               workspace.notes.contains(where: { $0.isCompleted }) {
                Button {
                    deleteCompletedNotes(in: workspace, editingNoteId: editingNoteId)
                } label: {
                    Image(systemName: "checkmark.circle.badge.xmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "notes.sidebar.deleteCompleted", defaultValue: "Delete completed notes"))
            }

            Button {
                if notesCollapsed { notesCollapsed = false }
                let note = WorkspaceNote()
                workspace.notes.append(note)
                editingNoteId.wrappedValue = note.id
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "rightSidebar.notes.add", defaultValue: "Add note"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            notesCollapsed.toggle()
        }
    }

    private var notesResizeDivider: some View {
        Rectangle()
            .fill(isDraggingNotesDivider ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15))
            .frame(height: isDraggingNotesDivider ? 2 : 1)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in
                        if notesDragStartHeight == nil {
                            notesDragStartHeight = clampedNotesHeight
                        }
                        isDraggingNotesDivider = true
                        let start = notesDragStartHeight ?? clampedNotesHeight
                        let proposed = start + value.translation.height
                        notesPanelHeight = Double(
                            min(max(proposed, Self.notesPanelMinHeight), Self.notesPanelMaxHeight)
                        )
                    }
                    .onEnded { _ in
                        notesDragStartHeight = nil
                        isDraggingNotesDivider = false
                    }
            )
    }

    private func deleteCompletedNotes(
        in workspace: Workspace,
        editingNoteId: Binding<UUID?>
    ) {
        let removedIds = Set(workspace.notes.filter { $0.isCompleted }.map { $0.id })
        guard !removedIds.isEmpty else { return }
        if let editing = editingNoteId.wrappedValue, removedIds.contains(editing) {
            editingNoteId.wrappedValue = nil
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            workspace.notes.removeAll { removedIds.contains($0.id) }
        }
    }

    private var sessionIndexDirectory: String? {
        sessionIndexStore.currentDirectory
    }

    private var dockRootDirectory: String? {
        RightSidebarDirectoryContext.dockRootDirectory(
            workspaceDirectory: tabManager.selectedWorkspace?.currentDirectory,
            fallbackDirectory: sessionIndexStore.currentDirectory
        )
    }

    private func synchronizeDockLifecycle(
        isRightSidebarVisible: Bool? = nil,
        mode: RightSidebarMode? = nil,
        rootDirectory: String? = nil,
        workspaceId: UUID? = nil
    ) {
        dockStore.synchronizeSidebarLifecycle(
            isRightSidebarVisible: isRightSidebarVisible ?? fileExplorerState.isVisible,
            mode: mode ?? fileExplorerState.mode,
            rootDirectory: rootDirectory ?? dockRootDirectory,
            workspaceId: workspaceId ?? self.workspaceId
        )
    }

    private func selectMode(_ mode: RightSidebarMode) {
        fileExplorerState.mode = mode
        if fileExplorerState.mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }

    private func refreshModeAvailabilityAndFocusIfNeeded() {
        let previousMode = fileExplorerState.mode
        fileExplorerState.refreshModeAvailability()
        let mode = fileExplorerState.mode
        if previousMode == mode {
            synchronizeDockLifecycle(mode: mode)
        }
        guard previousMode != mode,
              fileExplorerState.isVisible,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: fileExplorerState.mode,
            focusFirstItem: false,
            preferredWindow: window
        )
    }
}

private struct RightSidebarKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RightSidebarKeyboardFocusView {
        let view = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateNSView(_ nsView: RightSidebarKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class RightSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
#if DEBUG
        dlog(
            "rs.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else {
#if DEBUG
            dlog("rs.focus.host.focus result=0 reason=noWindow")
#endif
            return false
        }
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "rs.focus.host.focus result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }
}

extension NSView {
    var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}
