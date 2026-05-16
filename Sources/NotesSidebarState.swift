import SwiftUI
import AppKit

/// Marker protocol for views inside the notes sidebar that should retain
/// keyboard focus. The terminal's focus-recovery logic checks for this
/// protocol and skips `makeFirstResponder` when a notes responder is active.
protocol NotesSidebarResponder: AnyObject {}

extension Notification.Name {
    /// Posted by a Workspace when the user clicks the Bonsplit "toggle notes" button.
    /// The userInfo dictionary contains `Workspace.toggleNotesWorkspaceIdKey` mapping to the workspace UUID.
    static let cmuxWorkspaceRequestToggleNotesSidebar = Notification.Name("cmuxWorkspaceRequestToggleNotesSidebar")
}

@MainActor
final class NotesSidebarState: ObservableObject {
    /// Shared instance — after upstream moved the ContentView mount into
    /// AppDelegate, environmentObject wiring needs a stable singleton to
    /// hand to both the menu commands in `cmuxApp` and the rendered view
    /// inside the main window.
    static let shared = NotesSidebarState()

    /// Mirror of the *currently-selected* workspace's `notesSidebarVisible` flag for this window.
    /// Per-workspace persistence lives on `Workspace.notesSidebarVisible`; this value tracks the
    /// selected workspace so existing SwiftUI observers can drive sidebar layout unchanged.
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    static let defaultWidth: CGFloat = 250
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 500

    init(isVisible: Bool = false, persistedWidth: CGFloat = NotesSidebarState.defaultWidth) {
        self.isVisible = isVisible
        self.persistedWidth = Self.clampedWidth(persistedWidth)
    }

    func toggle() {
        isVisible.toggle()
    }

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}
