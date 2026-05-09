import AppKit
import SwiftUI

@MainActor
final class WorkspaceNotesManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WorkspaceNotesManagerWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "notes.manager.window.title",
            defaultValue: "Manage Notes"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.workspaceNotesManager")
        window.center()
        window.minSize = NSSize(width: 640, height: 380)
        window.contentView = NSHostingView(rootView: WorkspaceNotesManagerView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        WorkspaceNotesStore.shared.loadIfNeeded()
        if let window {
            if !window.isVisible { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
