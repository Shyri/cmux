import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case cloudVM = "cmux.cloudvm"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"
    /// Reveal the focused pane's working directory in Finder. Replaces
    /// the bonsplit-side "open in Finder" button removed when the
    /// vendor submodule was fast-forwarded to manaflow/main; surfacing
    /// it through the cmux.json action system keeps the feature
    /// available without diverging the bonsplit fork.
    case openInFinder = "cmux.openInFinder"
    /// Open the focused pane's working directory in IntelliJ IDEA or
    /// Android Studio depending on whether a Gradle build script is
    /// present (mirrors the legacy fork's auto-detection behaviour).
    case openInIDE = "cmux.openInIDE"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm",
             "cmux.newCloudVM", "cmux.newCloudVm", "newCloudVM", "newCloudVm",
             "cmux.startCloudVM", "cmux.startCloudVm", "startCloudVM", "startCloudVm":
            self = .cloudVM
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        case "cmux.openInFinder", "openInFinder", "cmux.revealInFinder", "revealInFinder":
            self = .openInFinder
        case "cmux.openInIDE", "openInIDE", "cmux.openInIde", "openInIde",
             "cmux.openInIntelliJ", "openInIntelliJ", "cmux.openInIntellij", "openInIntellij",
             "cmux.openInAndroidStudio", "openInAndroidStudio":
            self = .openInIDE
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .cloudVM:
            return "cloud"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        case .openInFinder:
            return "folder"
        case .openInIDE:
            // Generic IDE-ish icon — Workspace.openIDE picks the actual
            // app (IntelliJ vs Android Studio) at click time based on
            // the resolved cwd's Gradle markers.
            return "hammer"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM, .openInFinder, .openInIDE:
            return nil
        case .newTerminal:
            return .newTerminal
        case .newBrowser:
            return .newBrowser
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        }
    }
}
