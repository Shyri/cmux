import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case newAgentChat = "cmux.newAgentChat"
    case cloudVM = "cmux.cloudvm"
    case mobileConnect = "cmux.mobileconnect"
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
    /// Open the focused pane's working directory in Sourcetree (Atlassian
    /// git client). Mirrors the openInFinder/openInIDE pattern.
    case openInSourcetree = "cmux.openInSourcetree"
    /// Toggle the workspace's per-window notes sidebar (which also
    /// embeds the GitLab side panel). Same intent as the old bonsplit
    /// `showNotesButton` flag.
    case toggleNotes = "cmux.toggleNotes"
    /// Open a new Claude Chat panel in the focused pane. Same intent
    /// as the old bonsplit `showClaudeChatButton` flag, but goes
    /// through cmux's `TabManager.openClaudeChat()` so it picks up the
    /// same cwd inference + JSONL resume behaviour.
    case newClaudeChat = "cmux.newClaudeChat"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.newAgentChat", "cmux.agentChat", "newAgentChat", "new-agent-chat", "agentChat":
            self = .newAgentChat
        case "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm",
             "cmux.newCloudVM", "cmux.newCloudVm", "newCloudVM", "newCloudVm",
             "cmux.startCloudVM", "cmux.startCloudVm", "startCloudVM", "startCloudVm":
            self = .cloudVM
        case "cmux.mobileconnect", "cmux.mobileConnect", "mobileConnect", "mobileconnect",
             "cmux.connectPhone", "connectPhone":
            self = .mobileConnect
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
        case "cmux.openInSourcetree", "openInSourcetree", "cmux.openInSourceTree", "openInSourceTree",
             "cmux.sourcetree", "sourcetree":
            self = .openInSourcetree
        case "cmux.toggleNotes", "toggleNotes", "cmux.notes", "notes":
            self = .toggleNotes
        case "cmux.newClaudeChat", "newClaudeChat", "cmux.claudeChat", "claudeChat":
            self = .newClaudeChat
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
        case .newAgentChat:
            return "message"
        case .cloudVM:
            return "cloud"
        case .mobileConnect:
            return "iphone"
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
        case .openInSourcetree:
            return "arrow.triangle.branch"
        case .toggleNotes:
            return "note.text"
        case .newClaudeChat:
            return "bubble.left.and.bubble.right"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .newAgentChat, .cloudVM, .mobileConnect,
             .openInFinder, .openInIDE, .openInSourcetree, .toggleNotes,
             .newClaudeChat:
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
