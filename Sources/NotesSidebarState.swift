import SwiftUI
import AppKit

/// Marker protocol for views inside the notes UI that should retain
/// keyboard focus. The terminal's focus-recovery logic checks for this
/// protocol and skips `makeFirstResponder` when a notes responder is active.
protocol NotesSidebarResponder: AnyObject {}

extension Notification.Name {
    /// Posted by a Workspace when the user clicks the Bonsplit "toggle notes" button.
    /// The userInfo dictionary contains `Workspace.toggleNotesWorkspaceIdKey` mapping to the workspace UUID.
    static let cmuxWorkspaceRequestToggleNotesSidebar = Notification.Name("cmuxWorkspaceRequestToggleNotesSidebar")
}
