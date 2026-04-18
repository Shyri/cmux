import SwiftUI
import AppKit

/// Marker protocol for views inside the notes sidebar that should retain
/// keyboard focus. The terminal's focus-recovery logic checks for this
/// protocol and skips `makeFirstResponder` when a notes responder is active.
protocol NotesSidebarResponder: AnyObject {}

@MainActor
final class NotesSidebarState: ObservableObject {
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
