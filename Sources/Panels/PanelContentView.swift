import SwiftUI
import Foundation
import Bonsplit
import AppKit

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View, Equatable {
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void

    /// Parent re-render fence. The wrapped panel view conforms to
    /// `ObservableObject` and drives its own body invalidations via
    /// `@ObservedObject` inside the concrete panel view (so this `==`
    /// does NOT need to compare panel-internal state — when the
    /// wrapped state changes, the inner view re-renders independently
    /// of this Equatable check). The point here is to skip the body
    /// when the parent `WorkspaceContentView` re-evaluates for reasons
    /// that don't affect *this* panel — e.g. another panel publishing
    /// notifications, sibling unread state changing, or an unrelated
    /// `notificationStore` mutation.
    static func == (lhs: PanelContentView, rhs: PanelContentView) -> Bool {
        return ObjectIdentifier(lhs.panel) == ObjectIdentifier(rhs.panel)
            && lhs.workspaceId == rhs.workspaceId
            && lhs.paneId == rhs.paneId
            && lhs.isFocused == rhs.isFocused
            && lhs.isSelectedInPane == rhs.isSelectedInPane
            && lhs.isVisibleInUI == rhs.isVisibleInUI
            && lhs.portalPriority == rhs.portalPriority
            && lhs.isSplit == rhs.isSplit
            && lhs.hasUnreadNotification == rhs.hasUnreadNotification
            && PanelContentView.appearancesEqual(lhs.appearance, rhs.appearance)
    }

    private static func appearancesEqual(_ a: PanelAppearance, _ b: PanelAppearance) -> Bool {
        return colorsEqual(a.backgroundColor, b.backgroundColor)
            && colorsEqual(a.foregroundColor, b.foregroundColor)
            && colorsEqual(a.unfocusedOverlayNSColor, b.unfocusedOverlayNSColor)
            && a.unfocusedOverlayOpacity == b.unfocusedOverlayOpacity
            && a.usesClearContentBackground == b.usesClearContentBackground
            && a.dividerColor == b.dividerColor
    }

    private static func colorsEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        let lhs = a.usingColorSpace(.sRGB) ?? a
        let rhs = b.usingColorSpace(.sRGB) ?? b
        return lhs.redComponent == rhs.redComponent
            && lhs.greenComponent == rhs.greenComponent
            && lhs.blueComponent == rhs.blueComponent
            && lhs.alphaComponent == rhs.alphaComponent
    }

    var body: some View {
        renderedPanel
            .overlay {
                paneDropTargetOverlay
            }
    }

    @ViewBuilder
    private var renderedPanel: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                TerminalPanelView(
                    panel: terminalPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
                    terminalAgentContext: terminalAgentContext,
                    onFocus: onFocus,
                    onResumeAgentHibernation: onResumeAgentHibernation,
                    onAutoResumeAgentHibernation: onAutoResumeAgentHibernation,
                    onTriggerFlash: onTriggerFlash
                )
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserPanelView(
                    panel: browserPanel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .markdown:
            if let markdownPanel = panel as? MarkdownPanel {
                MarkdownPanelView(
                    panel: markdownPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .filePreview:
            if let filePreviewPanel = panel as? FilePreviewPanel {
                FilePreviewPanelView(
                    panel: filePreviewPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .rightSidebarTool:
            if let rightSidebarToolPanel = panel as? RightSidebarToolPanel {
                RightSidebarToolPanelView(
                    panel: rightSidebarToolPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    appearance: appearance,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        case .claudeChat:
            if let claudeChatPanel = panel as? ClaudeChatPanel {
                ClaudeChatPanelView(
                    panel: claudeChatPanel,
                    isFocused: isFocused,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    hasUnreadNotification: hasUnreadNotification,
                    onRequestPanelFocus: onRequestPanelFocus
                )
            }
        }
    }

    @ViewBuilder
    private var paneDropTargetOverlay: some View {
        if shouldInstallPaneDropTarget {
            PaneDropTargetRepresentable(dropContext: PaneDropContext(
                workspaceId: workspaceId,
                panelId: panel.id,
                paneId: paneId
            ))
        }
    }

    private var shouldInstallPaneDropTarget: Bool {
        guard isVisibleInUI else { return false }
        switch panel.panelType {
        case .markdown, .filePreview, .rightSidebarTool:
            return true
        case .terminal, .browser, .claudeChat:
            return false
        }
    }
}

struct PanelFilePathHeader<TrailingContent: View>: View {
    let iconSystemName: String
    let filePath: String
    let foregroundColor: NSColor
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailingContent()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.clear)
    }
}

struct PanelHeaderIconButton: View {
    let systemName: String
    let label: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelHeaderIconGlyph(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PanelHeaderIconGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .frame(width: 20, height: 20, alignment: .center)
            .contentShape(Rectangle())
    }
}
