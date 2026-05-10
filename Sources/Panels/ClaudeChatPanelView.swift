import AppKit
import Bonsplit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chat palette

/// Palette for the Claude Chat panel. The base background and foreground
/// follow the user's Ghostty terminal config (`backgroundColor`,
/// `foregroundColor`) so the chat blends with their terminals; card and
/// code surfaces are derived by lightening/darkening the base. Accent
/// colors are kept on a fixed Darcula-inspired hue set so semantics
/// (success/error/warning) read consistently across themes.
struct ChatPalette {
    /// The terminal background — used as the chat panel canvas in dark
    /// mode and as the seed for derived layer backgrounds.
    let terminalBg: NSColor
    /// The terminal foreground — used for primary chat text in dark mode.
    let terminalFg: NSColor

    static let `default` = ChatPalette(
        terminalBg: NSColor(srgbRed: 0x2B/255.0, green: 0x2B/255.0, blue: 0x2B/255.0, alpha: 1.0),
        terminalFg: NSColor(srgbRed: 0xBB/255.0, green: 0xBB/255.0, blue: 0xBB/255.0, alpha: 1.0)
    )

    // MARK: Static accents (Darcula-inspired, fixed regardless of theme)
    static let pink   = Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x68/255.0)  // #FF6B68
    static let red    = Color(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x68/255.0)
    static let orange = Color(red: 0xCC/255.0, green: 0x78/255.0, blue: 0x32/255.0)  // #CC7832
    static let yellow = Color(red: 0xD6/255.0, green: 0xBF/255.0, blue: 0x55/255.0)  // #D6BF55
    static let green  = Color(red: 0xA8/255.0, green: 0xC0/255.0, blue: 0x23/255.0)  // #A8C023
    static let cyan   = Color(red: 0x6C/255.0, green: 0xDA/255.0, blue: 0xDA/255.0)  // #6CDADA
    static let purple = Color(red: 0xAE/255.0, green: 0x8A/255.0, blue: 0xBE/255.0)  // #AE8ABE
    static let blue   = Color(red: 0x53/255.0, green: 0x94/255.0, blue: 0xEC/255.0)  // #5394EC

    // MARK: Layer helpers (dark = derived from terminalBg/Fg, light = neutral)

    func panelBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: terminalBg) : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }
    func headerBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }
    func cardBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: +0.07)) : Color(nsColor: NSColor(white: 0.94, alpha: 1.0))
    }
    func cardSubtleBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }
    func codeBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.06)) : Color(nsColor: NSColor(white: 0.93, alpha: 1.0))
    }
    func resultBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }
    func inputBg(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: -0.04)) : Color.white
    }
    func borderSubtle(_ isDark: Bool) -> Color {
        isDark ? Color(nsColor: shifted(terminalBg, by: +0.18)).opacity(0.7) : Color.secondary.opacity(0.18)
    }
    func fg(_ isDark: Bool) -> Color {
        // Slightly brighter than the terminal fg — chat messages are read
        // prose, not code, so a touch more contrast helps long-form
        // readability without diverging from the terminal palette.
        isDark ? Color(nsColor: shifted(terminalFg, by: 0.14)) : .primary
    }
    func accent(_ isDark: Bool) -> Color {
        isDark ? Self.purple : cmuxAccentColor()
    }

    /// Shift `color`'s perceived brightness by `delta` (negative = darker,
    /// positive = lighter). Operates in HSB so works for any base hue.
    private func shifted(_ color: NSColor, by delta: CGFloat) -> NSColor {
        let normalized = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        normalized.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newB = max(0, min(1, b + delta))
        return NSColor(hue: h, saturation: s, brightness: newB, alpha: a)
    }
}

// MARK: - Diff side pane

/// Right-hand pane showing every Edit/Write/MultiEdit/NotebookEdit
/// claude has emitted in the current (or just-finished) turn. Reuses
/// `EditDiffView` & friends so the visual is identical to the in-line
/// tool cards, just consolidated in one column.
private struct DiffPaneView: View {
    let edits: [ClaudeChatPanel.TurnEdit]
    let isDark: Bool
    let onClose: () -> Void

    @Environment(\.chatPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if edits.isEmpty {
                emptyState
            } else {
                scrollList
            }
        }
        .background(palette.headerBg(isDark))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.diffPane.title",
                defaultValue: "Last turn changes"
            ))
            .font(.system(size: 12, weight: .semibold))
            if !edits.isEmpty {
                Text("\(edits.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(palette.cardBg(isDark)))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(
                localized: "claudeChat.diffPane.close.tooltip",
                defaultValue: "Hide diff pane"
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.diffPane.empty",
                defaultValue: "No edits yet in this turn."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var scrollList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(edits) { edit in
                    DiffPaneEditCard(edit: edit, isDark: isDark)
                }
            }
            .padding(12)
        }
    }
}

private struct DiffPaneEditCard: View {
    let edit: ClaudeChatPanel.TurnEdit
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    private var parsed: [String: Any]? {
        guard let data = edit.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private var headerSummary: String {
        switch edit.toolName {
        case "Edit", "Write", "NotebookEdit":
            if let path = parsed?["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "MultiEdit":
            if let path = parsed?["file_path"] as? String,
               let edits = parsed?["edits"] as? [[String: Any]] {
                return "\((path as NSString).lastPathComponent) · \(edits.count) edits"
            }
        default:
            break
        }
        return edit.toolName
    }

    private var iconName: String {
        switch edit.toolName {
        case "Write": return "doc.badge.plus"
        case "NotebookEdit": return "book"
        default: return "pencil"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(edit.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(headerSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ToolInputDetailView(
                toolName: edit.toolName,
                input: parsed,
                rawJSON: edit.inputJSON,
                isDark: isDark
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
    }
}

// MARK: - Drop container (AppKit-backed)

/// Wraps SwiftUI content in an `NSView` that doubles as an
/// `NSDraggingDestination`. Clicks fall through to the embedded
/// `NSHostingView` naturally; drags are captured by the container because
/// it is the registered destination for the relevant pasteboard types.
struct ChatDropContainer<Content: View>: NSViewRepresentable {
    let onURLs: ([URL]) -> Void
    let onImageData: ([Data]) -> Void
    let onTargetedChange: (Bool) -> Void
    let onPointerDown: (() -> Void)?
    let content: Content

    init(
        onURLs: @escaping ([URL]) -> Void,
        onImageData: @escaping ([Data]) -> Void,
        onTargetedChange: @escaping (Bool) -> Void,
        onPointerDown: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.onURLs = onURLs
        self.onImageData = onImageData
        self.onTargetedChange = onTargetedChange
        self.onPointerDown = onPointerDown
        self.content = content()
    }

    func makeNSView(context: Context) -> ChatDropZoneNSView {
        let view = ChatDropZoneNSView()
        view.onURLs = onURLs
        view.onImageData = onImageData
        view.onTargetedChange = onTargetedChange
        view.onPointerDown = onPointerDown

        let host = NSHostingView(rootView: AnyView(content))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.hostingView = host
        return view
    }

    func updateNSView(_ nsView: ChatDropZoneNSView, context: Context) {
        nsView.hostingView?.rootView = AnyView(content)
        nsView.onURLs = onURLs
        nsView.onImageData = onImageData
        nsView.onTargetedChange = onTargetedChange
        nsView.onPointerDown = onPointerDown
    }
}

final class ChatDropZoneNSView: NSView {
    weak var hostingView: NSHostingView<AnyView>?
    var onURLs: (([URL]) -> Void)?
    var onImageData: (([Data]) -> Void)?
    var onTargetedChange: ((Bool) -> Void)?
    /// Kept for source compatibility with `ChatDropContainer`. We no longer
    /// install a global mouse-down monitor here because doing so was
    /// stealing focus mid-drag-select and breaking text selection inside
    /// the chat. The chat input's own `becomeFirstResponder` hook is enough
    /// to keep bonsplit's focused-pane bookkeeping in sync for the typing
    /// case (which was the only real leak).
    var onPointerDown: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerDraggedTypes()
        #if DEBUG
        dlog("ChatDropZone init frame=\(frameRect)")
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func registerDraggedTypes() {
        registerForDraggedTypes([
            .fileURL,
            .URL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerDraggedTypes()
        #if DEBUG
        dlog("ChatDropZone viewDidMoveToWindow window=\(window != nil ? "yes" : "no") frame=\(frame) bounds=\(bounds)")
        #endif
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        #if DEBUG
        dlog("ChatDropZone resize frame=\(frame)")
        #endif
    }

    // No hitTest override — the embedded NSHostingView naturally receives
    // pointer events as the topmost subview, and AppKit's dragging
    // destination scan still considers `self` because it is registered.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        dlog("ChatDropZone draggingEntered types=\(sender.draggingPasteboard.types ?? [])")
        #endif
        guard hasUsableContent(sender.draggingPasteboard) else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasUsableContent(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargetedChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var handledAny = false

        // Always clear the SwiftUI "targeted" state once we get to perform —
        // the overlay routing in FileDropOverlayView does not always send
        // us a matching draggingExited.
        onTargetedChange?(false)

        #if DEBUG
        dlog("ChatDropZone performDragOperation types=\(pb.types ?? [])")
        #endif

        // 1. File URLs (Finder, browser dock, descargas, etc.).
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            #if DEBUG
            dlog("ChatDropZone got \(urls.count) URL(s) — first=\(urls.first?.path ?? "?")")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.onURLs?(urls)
            }
            handledAny = true
        } else if let propertyList = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !propertyList.isEmpty {
            // Legacy: NSFilenamesPboardType emitted by older drag sources.
            let urls = propertyList.map { URL(fileURLWithPath: $0) }
            #if DEBUG
            dlog("ChatDropZone got \(urls.count) legacy filename(s)")
            #endif
            DispatchQueue.main.async { [weak self] in
                self?.onURLs?(urls)
            }
            handledAny = true
        }

        // 2. In-memory bitmap images (Preview, Photos, browser image drag).
        if !handledAny,
           let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            let datas: [Data] = images.compactMap { image in
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff)
                else { return nil }
                return rep.representation(using: .png, properties: [:])
            }
            if !datas.isEmpty {
                #if DEBUG
                dlog("ChatDropZone got \(datas.count) image(s) from NSImage providers")
                #endif
                DispatchQueue.main.async { [weak self] in
                    self?.onImageData?(datas)
                }
                handledAny = true
            }
        }

        #if DEBUG
        if !handledAny {
            dlog("ChatDropZone unable to extract URLs or images from pasteboard")
        }
        #endif
        return handledAny
    }

    private func hasUsableContent(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return false
    }
}

// MARK: - Attachment chip

/// Inline thumbnails shown on a `.user` message bubble for files that
/// were attached when the message was sent. Read-only — no remove button.
private struct SentAttachmentsRow: View {
    let urls: [URL]
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(urls, id: \.self) { url in
                SentAttachmentThumb(url: url, isDark: isDark)
            }
        }
    }
}

private struct SentAttachmentThumb: View {
    let url: URL
    let isDark: Bool

    @Environment(\.chatPalette) private var palette
    @State private var thumb: NSImage?

    private var isImage: Bool {
        ChatAttachment.isImageFile(at: url)
    }

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else if isImage {
                Color.clear
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "doc")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 80)
                }
                .padding(4)
            }
        }
        .frame(width: 96, height: 96)
        .background(palette.codeBg(isDark))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .help(url.lastPathComponent)
        .onAppear(perform: loadThumb)
    }

    private func loadThumb() {
        guard isImage, thumb == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                thumb = image
            }
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let isDark: Bool
    let onRemove: () -> Void

    @Environment(\.chatPalette) private var palette
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbView
                    .frame(width: 44, height: 44)
                    .background(palette.codeBg(isDark))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.isImage ? "image" : "file")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .onAppear(perform: loadThumbnail)
    }

    @ViewBuilder
    private var thumbView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipped()
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
                .frame(width: 44, height: 44)
        }
    }

    private func loadThumbnail() {
        guard attachment.isImage, thumbnail == nil else { return }
        let url = attachment.url
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                thumbnail = image
            }
        }
    }
}

// MARK: - Always-allowed popover

/// Popover that lists every tool the user has marked as "Allow always" in
/// the current workspace. Each row can be revoked individually. The
/// underlying source of truth is `<cwd>/.claude/settings.local.json`, so
/// changes here also propagate to any other tool that reads that file.
private struct AlwaysAllowedPopover: View {
    @ObservedObject var panel: ClaudeChatPanel
    @Environment(\.dismiss) private var dismiss

    private var sortedTools: [String] {
        Array(panel.alwaysAllowedTools).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(ChatPalette.green)
                Text(String(
                    localized: "claudeChat.alwaysAllowed.title",
                    defaultValue: "Always allowed tools"
                ))
                .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(String(
                localized: "claudeChat.alwaysAllowed.subtitle",
                defaultValue: "These tools auto-allow for any chat in this workspace. Persisted in .claude/settings.local.json."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            if sortedTools.isEmpty {
                emptyState
            } else {
                toolList
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(String(
                localized: "claudeChat.alwaysAllowed.empty",
                defaultValue: "Nothing here yet. Click \"Allow always\" on a tool prompt to add it."
            ))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var toolList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sortedTools, id: \.self) { tool in
                    HStack(spacing: 8) {
                        Text(tool)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            panel.revokeAlwaysAllowed(toolName: tool)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(
                            localized: "claudeChat.alwaysAllowed.revokeTooltip",
                            defaultValue: "Click to revoke — future uses of this tool will ask again."
                        ))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(ChatPalette.green.opacity(0.10))
                    )
                }
            }
        }
        .frame(maxHeight: 280)
    }
}

private struct ChatPaletteKey: EnvironmentKey {
    static let defaultValue = ChatPalette.default
}

extension EnvironmentValues {
    var chatPalette: ChatPalette {
        get { self[ChatPaletteKey.self] }
        set { self[ChatPaletteKey.self] = newValue }
    }
}

/// SwiftUI view that renders a `ClaudeChatPanel`. Fase 1 ships the layout
/// (message list, tool cards, input bar) wired to the panel's mock state;
/// fase 2 connects it to the live `ClaudeChatRunner` subprocess.
struct ClaudeChatPanelView: View {
    @ObservedObject var panel: ClaudeChatPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    /// Mirror of the same prop the terminal panel receives — driven by
    /// `TerminalNotificationStore` via WorkspaceContentView. We use this
    /// (rather than the panel's local pendingApprovals/pendingQuestions)
    /// so the blue ring follows the exact same lifecycle as in a Claude
    /// Code terminal session: appears when claude posts a notification,
    /// disappears when the user marks it read by interacting with the
    /// pane.
    let hasUnreadNotification: Bool
    let onRequestPanelFocus: () -> Void

    // (`draft` lives on `panel` — see `ClaudeChatPanel.draft`. Read/write
    // it as `panel.draft` and pass `Binding($panel.draft)` to the input
    // view. Lifting it onto the panel keeps the in-progress message
    // alive across workspace switches.)
    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    /// True when the bottom sentinel is currently visible in the scroll
    /// viewport. When false, the user has scrolled up to read history; we
    /// then suppress auto-scroll so streaming events do not jerk the view.
    @State private var isAtBottom: Bool = true
    /// Bumped every time the user submits, to force a scroll-to-bottom
    /// even if they were reading earlier history.
    @State private var forceScrollToBottomToken: Int = 0
    /// Bumped to demand keyboard focus on the chat input — used after a
    /// drop completes so the next keystroke goes here, not to whichever
    /// pane the bonsplit focus manager last remembered.
    @State private var inputFocusToken: Int = 0
    /// Controls whether the always-allowed-tools popover is visible.
    @State private var showingAlwaysAllowedPopover: Bool = false
    /// Whether the right-side diff pane is open. Persists for the
    /// lifetime of this view; restart the panel to reset.
    @State private var showingDiffPane: Bool = false
    /// Mirror of `panel.lastTurnEdits.count` from the previous render —
    /// used to detect 0→≥1 transitions and auto-open the side pane.
    @State private var lastTurnEditsCountSeen: Int = 0
    @State private var showingUndoConfirmation: Bool = false
    /// Non-nil when the dialog is being raised from an inline rewind
    /// button — the rewind targets that user message. nil means rewind
    /// the last turn (header button).
    @State private var pendingRewindUserMessageId: UUID? = nil
    /// Highlights the chat area while a drag is hovering.
    @State private var isDropTargeted: Bool = false
    /// Slash-command autocomplete state. The popup only appears while the
    /// draft starts with a single `/` followed by an alphanumeric run (no
    /// whitespace yet) — i.e. while the user is typing a command name.
    @State private var slashAllCommands: [SlashCommand] = []
    @State private var slashFilteredCommands: [SlashCommand] = []
    @State private var slashSelectedIndex: Int = 0
    @State private var showingSlashPopup: Bool = false
    /// Mirror of the global "show blue ring on panes that need attention"
    /// preference (same key the terminal panel uses).
    @AppStorage(NotificationPaneRingSettings.enabledKey)
    private var notificationPaneRingEnabled = NotificationPaneRingSettings.defaultEnabled
    @Environment(\.colorScheme) private var colorScheme

    private static let bottomSentinelId = "__claudechat_bottom__"

    /// Cap the chat content width when the panel is unusually wide
    /// (full-screen, large external displays). Prose at 1500pt wide is
    /// uncomfortable to read; matches the convention used by ChatGPT,
    /// Claude.ai, Slack thread panes, etc.
    private static let maxContentWidth: CGFloat = 760

    /// Drives the blue notification ring around the chat panel. We follow
    /// the same path as the terminal panel: the host (WorkspaceContentView)
    /// computes `hasUnreadNotification` from the global
    /// `TerminalNotificationStore` and passes it down. When the user
    /// directly interacts with the pane, cmux's `dismissNotificationOnDirectInteraction`
    /// flips it back to false — exactly as in a Claude Code terminal
    /// session.
    private var showsNotificationRing: Bool {
        notificationPaneRingEnabled && hasUnreadNotification
    }

    /// Palette derived from the panel's terminal-config-driven base colors.
    /// Recomputed on every render — cheap, just two NSColors.
    private var palette: ChatPalette {
        ChatPalette(
            terminalBg: panel.terminalBackgroundColor,
            terminalFg: panel.terminalForegroundColor
        )
    }

    var body: some View {
        ChatDropContainer(
            onURLs: { urls in
                for url in urls { _ = panel.attachFile(at: url) }
            },
            onImageData: { datas in
                for data in datas {
                    _ = panel.attachImageData(data, suggestedExtension: "png", baseName: "drop")
                }
            },
            onTargetedChange: { value in isDropTargeted = value },
            onPointerDown: {
                // Any click anywhere in the chat panel area: tell the host
                // that this pane should become bonsplit's focused pane, so
                // subsequent keystrokes route here instead of leaking to a
                // sibling terminal pane that bonsplit still remembers.
                onRequestPanelFocus()
            }
        ) {
            chatContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(palette.accent(colorScheme == .dark).opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: palette.accent(colorScheme == .dark).opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            // Pendant of the terminal panel's "unread notification" blue
            // ring: when claude needs the user (pending approval or open
            // ask_user_question) we draw the same ring around the chat
            // panel so the user spots it from anywhere on screen, just
            // like in their terminal claude sessions.
            if showsNotificationRing {
                RoundedRectangle(cornerRadius: PanelOverlayRingMetrics.cornerRadius)
                    .stroke(Color(nsColor: .systemBlue), lineWidth: PanelOverlayRingMetrics.lineWidth)
                    .shadow(color: Color(nsColor: .systemBlue).opacity(0.35), radius: 3)
                    .padding(PanelOverlayRingMetrics.inset)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
        // (`.environment(\.chatPalette, palette)` deliberately moved into
        // `chatContent` — see note there.)
        .onChange(of: panel.pendingAttachments.count) { newCount in
            // After a drop, AppKit leaves the dragging container as first
            // responder — and bonsplit's focus manager then routes the
            // next keystroke to whichever pane it last marked focused
            // (often a sibling terminal). Pull focus back to the chat
            // input so the user can keep typing.
            if newCount > 0 {
                inputFocusToken &+= 1
            }
        }
        .onChange(of: panel.lastTurnEdits.count) { newCount in
            // 0 → ≥1: claude just produced the first edit of this turn.
            // Auto-open the side pane so the user sees the diffs without
            // hunting for the toggle. We only auto-open on the rising
            // edge, so once the user closes it manually mid-turn we
            // don't keep re-opening it on every additional edit.
            if lastTurnEditsCountSeen == 0 && newCount > 0 && !showingDiffPane {
                showingDiffPane = true
            }
            lastTurnEditsCountSeen = newCount
        }
        .onChange(of: panel.inputFocusRequestToken) { _ in
            // Panel asked for keyboard focus (e.g. bonsplit selected this
            // pane). Mirror it onto our local token so the input view
            // claims first-responder.
            inputFocusToken &+= 1
        }
        .onChange(of: panel.status) { newStatus in
            // When a turn completes (.idle / .error after .sending) the
            // user is almost always about to type the next prompt — make
            // sure their keystrokes land in the input even if they had
            // clicked away mid-turn.
            if case .idle = newStatus {
                inputFocusToken &+= 1
            }
        }
        .onAppear {
            slashAllCommands = SlashCommandRegistry.availableCommands(cwd: panel.workingDirectory)
            updateSlashPopupForDraft(panel.draft)
        }
        .onChange(of: panel.workingDirectory) { newCwd in
            // The cwd governs which project-scope custom commands the
            // registry includes; refresh on rare changes.
            slashAllCommands = SlashCommandRegistry.availableCommands(cwd: newCwd)
            updateSlashPopupForDraft(panel.draft)
        }
        .onChange(of: panel.draft) { newValue in
            updateSlashPopupForDraft(newValue)
        }
    }

    /// The actual SwiftUI tree of the chat panel, embedded inside the
    /// AppKit dragging container. Kept as a separate computed property so
    /// the body's outer view is just the container.
    private var chatContent: some View {
        HStack(spacing: 0) {
            chatColumn
            if showingDiffPane {
                Divider()
                DiffPaneView(
                    edits: panel.lastTurnEdits,
                    isDark: colorScheme == .dark,
                    onClose: { showingDiffPane = false }
                )
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 480)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 0)
                    .stroke(ChatPalette.green, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    .background(ChatPalette.green.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingDiffPane)
        // The chat palette must be injected here, INSIDE the AppKit
        // hosting container — environments do not cross the
        // NSHostingView boundary, so an outer `.environment` would never
        // reach DiffPaneView/DiffBlock and they'd render with the static
        // default palette.
        .environment(\.chatPalette, palette)
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            workingDirectoryHeader
            Divider()
            messageList
            if case .error(let message) = panel.status {
                errorBanner(message)
            }
            Divider()
            if let line = panel.statusLineText, !line.isEmpty {
                statusLineRow(line)
            }
            if !panel.pendingAttachments.isEmpty {
                attachmentsRow
            }
            inputBar
        }
        .frame(maxWidth: .infinity)
    }

    /// One-line status row driven by the user's `statusLine.command`
    /// (read from `.claude/settings.json`). Sits between the chat
    /// transcript and the input — same vertical position Claude Code
    /// interactive uses for its status line. The output may contain
    /// ANSI/SGR escapes (colors, bold, etc.); we parse them into an
    /// AttributedString so the rendered chip matches what the script
    /// intended.
    private func statusLineRow(_ text: String) -> some View {
        let attributed = ANSIRenderer.attributedString(
            from: text,
            baseFont: .system(size: 11, design: .monospaced),
            defaultColor: .secondary
        )
        return HStack(spacing: 0) {
            Text(attributed)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(palette.headerBg(colorScheme == .dark))
    }

    // MARK: - Header

    private var workingDirectoryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            Text(panel.workingDirectory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if panel.totalCostUSD > 0 {
                Text(formatCost(panel.totalCostUSD))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.cardBg(colorScheme == .dark)))
                    .help(String(localized: "claudeChat.cost.tooltip", defaultValue: "Cumulative API cost in USD"))
            }
            if let sessionId = panel.sessionId {
                Text(String(sessionId.prefix(8)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .help(String(localized: "claudeChat.sessionId.tooltip", defaultValue: "Claude session id (resumed across turns)"))
            }
            undoButton
            diffPaneButton
            alwaysAllowedButton
            clearButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .confirmationDialog(
            pendingRewindUserMessageId == nil
                ? String(localized: "claudeChat.undo.confirm.title", defaultValue: "Undo last turn?")
                : String(localized: "claudeChat.rewind.confirm.title", defaultValue: "Rewind to this message?"),
            isPresented: $showingUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                pendingRewindUserMessageId == nil
                    ? String(localized: "claudeChat.undo.confirm.action", defaultValue: "Undo")
                    : String(localized: "claudeChat.rewind.confirm.action", defaultValue: "Rewind"),
                role: .destructive
            ) {
                let restored: Int?
                if let mid = pendingRewindUserMessageId {
                    restored = panel.rewindTo(userMessageId: mid)
                } else {
                    restored = panel.undoLastTurn()
                }
                pendingRewindUserMessageId = nil
                #if DEBUG
                NSLog("ClaudeChatPanel.rewind restored \(restored ?? 0) file(s)")
                #endif
            }
            Button(
                String(localized: "claudeChat.undo.confirm.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                pendingRewindUserMessageId = nil
            }
        } message: {
            Text(String(
                localized: "claudeChat.undo.confirm.message",
                defaultValue: "This restores files claude edited (using Claude Code's file history) and removes its responses after the chosen point. The next prompt will start a fresh session."
            ))
        }
    }

    private var undoButton: some View {
        let canUndo = !panel.undoCheckpoints.isEmpty
        return Button {
            showingUndoConfirmation = true
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
                .foregroundColor(canUndo ? .secondary : .secondary.opacity(0.35))
        }
        .buttonStyle(.borderless)
        .disabled(!canUndo)
        .help(String(
            localized: "claudeChat.undo.tooltip",
            defaultValue: "Undo the last turn — restores files claude edited and removes its replies"
        ))
    }

    private var diffPaneButton: some View {
        Button {
            showingDiffPane.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: showingDiffPane ? "sidebar.right" : "doc.on.doc")
                    .font(.system(size: 11))
                if !panel.lastTurnEdits.isEmpty {
                    Text("\(panel.lastTurnEdits.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundColor(panel.lastTurnEdits.isEmpty ? .secondary : ChatPalette.green)
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.diffPane.tooltip",
            defaultValue: "Show a side panel with the edits from the last turn"
        ))
    }

    private var alwaysAllowedButton: some View {
        Button {
            showingAlwaysAllowedPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11))
                if !panel.alwaysAllowedTools.isEmpty {
                    Text("\(panel.alwaysAllowedTools.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundColor(panel.alwaysAllowedTools.isEmpty ? .secondary : ChatPalette.green)
        }
        .buttonStyle(.borderless)
        .help(String(
            localized: "claudeChat.alwaysAllowed.button.tooltip",
            defaultValue: "Manage tools that are always allowed in this workspace"
        ))
        .popover(isPresented: $showingAlwaysAllowedPopover, arrowEdge: .bottom) {
            AlwaysAllowedPopover(panel: panel)
        }
    }

    private func formatCost(_ usd: Double) -> String {
        if usd < 0.01 {
            return String(format: "$%.4f", usd)
        }
        return String(format: "$%.3f", usd)
    }

    /// Pretty-print a token count in compact form (12.3k, 1.2M).
    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    /// Best-effort context-window size for the active model. Anthropic
    /// model ids that carry the `[1m]` suffix run with a 1M context;
    /// everything else assumes the standard 200k window.
    private func contextWindowTokens(forModel model: String?) -> Int {
        guard let model, !model.isEmpty else { return 200_000 }
        return model.contains("[1m]") ? 1_000_000 : 200_000
    }

    /// Chip showing "<used> / <context>" tokens, anchored next to the
    /// model chip. The total counts every token claude reported so far
    /// for this turn (input + output + cache create/read), which is
    /// what the user thinks of as "tokens consumed".
    private func tokenUsageChip(_ usage: ChatTokenUsage) -> some View {
        let used = usage.contextWindowTokens
        let max = contextWindowTokens(forModel: panel.modelName)
        let pct = Double(min(used, max)) / Double(max)
        let color: Color = pct >= 0.85 ? ChatPalette.red
            : pct >= 0.6 ? ChatPalette.orange
            : .secondary
        let label = "\(formatTokens(used)) / \(formatTokens(max))"
        return Text(label)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(palette.cardBg(colorScheme == .dark)))
            .help(String(
                format: String(
                    localized: "claudeChat.tokens.tooltip",
                    defaultValue: "Tokens used in this turn — input %d, output %d, cache create %d, cache read %d (context window %@)"
                ),
                usage.inputTokens,
                usage.outputTokens,
                usage.cacheCreationInputTokens,
                usage.cacheReadInputTokens,
                formatTokens(max)
            ))
    }

    private var permissionModePicker: some View {
        Picker("", selection: $panel.permissionMode) {
            ForEach(ChatPermissionMode.allCases) { mode in
                Label(mode.label, systemImage: mode.iconName).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .help(String(
            localized: "claudeChat.mode.picker.tooltip",
            defaultValue: "How tool calls are gated for the next turn. Plan = read-only, Normal = ask each tool, Auto-edits = edits auto + bash asks, Bypass = everything auto."
        ))
        .frame(maxWidth: 110)
    }

    private var clearButton: some View {
        Button {
            panel.clearTranscript()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "claudeChat.clear.tooltip", defaultValue: "Clear chat (start a new conversation)"))
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let rows = ChatRowBuilder.buildRows(from: panel.messages)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        rowView(row, isLast: idx == rows.count - 1)
                            .id(row.id)
                    }
                    ForEach(panel.pendingApprovals) { request in
                        ApprovalRequestCard(
                            request: request,
                            isDark: colorScheme == .dark,
                            onApprove: { panel.approve(toolUseId: request.id) },
                            onApproveAlways: {
                                panel.approveAlways(toolUseId: request.id, toolName: request.toolName)
                            },
                            onDeny: { panel.deny(toolUseId: request.id, reason: nil) }
                        )
                        .id("approval-\(request.id)")
                    }
                    ForEach(panel.pendingQuestions) { request in
                        UserQuestionCard(
                            request: request,
                            isDark: colorScheme == .dark,
                            onAnswer: { answersByIndex in
                                panel.answer(questionId: request.id, answers: answersByIndex)
                            }
                        )
                        .id("question-\(request.id)")
                    }
                    if case .sending = panel.status {
                        statusIndicator
                    }

                    // Sentinel pinned to the bottom of the content. Its
                    // appear/disappear callbacks tell us whether the user
                    // is currently looking at the latest content; we only
                    // auto-scroll while it's visible (logcat-style).
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomSentinelId)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        scrollToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Circle().fill(palette.accent(colorScheme == .dark).opacity(0.85)))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .help(String(
                        localized: "claudeChat.scrollToBottom.tooltip",
                        defaultValue: "Jump to latest"
                    ))
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .onChange(of: panel.messages.count) { _ in
                autoScrollIfStuck(proxy: proxy)
            }
            .onChange(of: panel.pendingApprovals.count) { _ in
                autoScrollIfStuck(proxy: proxy)
            }
            .onChange(of: panel.pendingQuestions.count) { _ in
                autoScrollIfStuck(proxy: proxy)
            }
            .onChange(of: forceScrollToBottomToken) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                // When the chat panel becomes visible (switching back from
                // another tab/workspace, or first mount) the ScrollView's
                // initial offset is the top of the LazyVStack. The user
                // expects to land on the latest exchange instead. A tiny
                // delay lets LazyVStack finish materialising rows before we
                // jump.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isAtBottom = true
                    proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow, isLast: Bool) -> some View {
        switch row {
        case .text(let payload):
            TextBlockRow(
                role: payload.role,
                text: payload.text,
                attachmentURLs: payload.attachmentURLs,
                messageId: payload.messageId,
                isDark: colorScheme == .dark,
                canRewindToHere: panel.undoCheckpoints.contains(where: {
                    $0.userMessageId == payload.messageId
                }),
                onRewindToHere: { messageId in
                    pendingRewindUserMessageId = messageId
                    showingUndoConfirmation = true
                },
                isCollapsedByDefault: payload.isCollapsedByDefault,
                slashCommandName: payload.slashCommandName
            )
        case .toolBatch(let batch):
            ToolBatchView(
                entries: batch.entries,
                pendingApprovals: panel.pendingApprovals,
                toolResults: panel.toolResultsByToolUseId,
                isCurrentBatch: isLast && panel.status == .sending,
                isDark: colorScheme == .dark,
                onApprove: panel.approve(toolUseId:),
                onDeny: { id in panel.deny(toolUseId: id, reason: nil) }
            )
        }
    }

    private func autoScrollIfStuck(proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        isAtBottom = true
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomSentinelId, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if !panel.pendingApprovals.isEmpty || !panel.pendingQuestions.isEmpty {
            // Claude itself is paused — the daemon is waiting on the
            // user's reply to the inline approval / question card. Show
            // that explicitly so it doesn't look like a frozen "thinking".
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundColor(ChatPalette.orange)
                Text(String(
                    localized: "claudeChat.status.waitingForUser",
                    defaultValue: "Waiting for your reply…"
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "claudeChat.status.thinking", defaultValue: "Thinking…"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attachments

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(panel.pendingAttachments) { attachment in
                    AttachmentChip(
                        attachment: attachment,
                        isDark: colorScheme == .dark,
                        onRemove: { panel.removePendingAttachment(id: attachment.id) }
                    )
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: 64)
        .background(headerBackground)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(ChatPalette.orange)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ChatPalette.orange.opacity(0.18))
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Slash-command suggestions sit ABOVE the input so the user can
            // see what they're picking while still typing. Inserting it as
            // a sibling (not an overlay) sidesteps the clip/zindex traps
            // that hide an overlay rendered "above" its parent's bounds.
            if showingSlashPopup, !slashFilteredCommands.isEmpty {
                SlashCommandPopup(
                    commands: slashFilteredCommands,
                    selectedIndex: slashSelectedIndex,
                    palette: palette,
                    isDark: colorScheme == .dark,
                    onPick: { idx in
                        slashSelectedIndex = idx
                        confirmSlashSelection()
                    }
                )
                .frame(maxWidth: 460, alignment: .leading)
                .transition(.opacity)
            }
            ChatInputTextView(
                text: $panel.draft,
                placeholder: String(
                    localized: "claudeChat.input.placeholder",
                    defaultValue: "Ask Claude…"
                ),
                isDark: colorScheme == .dark,
                textColor: panel.terminalForegroundColor,
                focusToken: inputFocusToken,
                onSubmit: submit,
                onCancel: handleEscape,
                onBecomeFirstResponder: { onRequestPanelFocus() },
                onArrowUp: { moveSlashSelection(by: -1) },
                onArrowDown: { moveSlashSelection(by: +1) },
                onTabKey: completeSlashCommandPrefixIfPossible
            )
            .frame(minHeight: 16, maxHeight: 48)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                permissionModePicker
                if let model = panel.modelName, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(palette.cardBg(colorScheme == .dark)))
                        .help(String(
                            localized: "claudeChat.model.tooltip",
                            defaultValue: "Active Claude model"
                        ))
                }
                if let usage = panel.lastUsage {
                    tokenUsageChip(usage)
                }
                Spacer(minLength: 4)
                actionButton
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .background(headerBackground)
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .sending = panel.status {
            Button(action: panel.cancel) {
                Image(systemName: "stop.fill")
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help(String(localized: "claudeChat.cancel.button", defaultValue: "Stop (Esc)"))
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(panel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(String(localized: "claudeChat.send.button", defaultValue: "Send (Enter)"))
        }
    }

    private func cancelIfSending() {
        if case .sending = panel.status {
            panel.cancel()
        }
    }

    /// Esc: close the slash-command popup if it's up; otherwise fall
    /// back to the original "stop the in-flight turn" behavior.
    private func handleEscape() {
        if showingSlashPopup {
            showingSlashPopup = false
            return
        }
        cancelIfSending()
    }

    private func submit() {
        // Slash-command popup intercepts Enter: if the user has filtered
        // down to one (or selected one) we run that instead of sending.
        if showingSlashPopup, !slashFilteredCommands.isEmpty {
            confirmSlashSelection()
            return
        }
        let trimmed = panel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .sending = panel.status { return }
        panel.send(trimmed)
        panel.draft = ""
        // Sending always means the user wants to follow the conversation
        // again — jump to the latest, even if they were reading history.
        forceScrollToBottomToken &+= 1
    }

    // MARK: - Slash command autocomplete

    /// Parse the draft and decide whether to show the popup. The popup
    /// shows iff the trimmed draft starts with `/` and the first token
    /// (everything until whitespace) is just word-characters — i.e. the
    /// user is still typing the command name. Once they type a space we
    /// hide it (the rest of the input is treated as command arguments,
    /// for `sendAsPrompt` commands).
    private func updateSlashPopupForDraft(_ text: String) {
        guard let prefix = slashCommandPrefix(in: text) else {
            if showingSlashPopup { showingSlashPopup = false }
            return
        }
        // Lazy-load guard: SwiftUI does not guarantee `onAppear` runs
        // before the first `onChange(of: panel.draft)`. If the user
        // types `/star` before the registry has populated, our filter
        // returns nothing and the popup never appears the first time.
        // The list always contains the 7 built-ins once loaded, so an
        // empty array reliably means "not loaded yet".
        if slashAllCommands.isEmpty {
            slashAllCommands = SlashCommandRegistry.availableCommands(cwd: panel.workingDirectory)
        }
        let filtered = SlashCommandRegistry.filter(slashAllCommands, byPrefix: prefix)
        slashFilteredCommands = filtered
        if filtered.isEmpty {
            showingSlashPopup = false
            return
        }
        if slashSelectedIndex >= filtered.count {
            slashSelectedIndex = 0
        }
        showingSlashPopup = true
    }

    /// Returns the `/`-less prefix the user has typed so far, or `nil`
    /// when the draft is not in "typing a slash command" state.
    private func slashCommandPrefix(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let after = text.dropFirst()
        // No whitespace allowed — once the user adds args we stop
        // suggesting names.
        if after.contains(where: { $0.isWhitespace }) { return nil }
        return String(after)
    }

    /// Move the highlighted row in the popup. Returns true (= key
    /// consumed) when the popup is visible, so the NSTextView default
    /// caret movement does not also fire.
    @discardableResult
    private func moveSlashSelection(by delta: Int) -> Bool {
        guard showingSlashPopup, !slashFilteredCommands.isEmpty else { return false }
        let count = slashFilteredCommands.count
        let next = ((slashSelectedIndex + delta) % count + count) % count
        slashSelectedIndex = next
        return true
    }

    /// Tab: complete the input to the longest unambiguous prefix among
    /// the filtered commands. Returns true to swallow Tab when the popup
    /// is up.
    @discardableResult
    private func completeSlashCommandPrefixIfPossible() -> Bool {
        guard showingSlashPopup, !slashFilteredCommands.isEmpty else { return false }
        if slashFilteredCommands.count == 1 {
            // One match — fully complete (without confirming) so the user
            // can still hit Enter or add args.
            panel.draft = "/" + slashFilteredCommands[0].name
            return true
        }
        // Multiple matches — extend the typed prefix to the longest
        // common name prefix, like a shell.
        let names = slashFilteredCommands.map { $0.name }
        let common = longestCommonPrefix(of: names)
        let typed = slashCommandPrefix(in: panel.draft) ?? ""
        if common.count > typed.count {
            panel.draft = "/" + common
        }
        return true
    }

    private func longestCommonPrefix(of strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.lowercased().hasPrefix(prefix.lowercased()), !prefix.isEmpty {
                prefix.removeLast()
            }
            if prefix.isEmpty { return "" }
        }
        return prefix
    }

    /// User picked the highlighted command (Enter / click).
    private func confirmSlashSelection() {
        guard slashSelectedIndex < slashFilteredCommands.count else { return }
        let cmd = slashFilteredCommands[slashSelectedIndex]
        showingSlashPopup = false
        switch cmd.action {
        case .runBuiltin(let key):
            runBuiltinSlashCommand(key)
            panel.draft = ""
        case .sendAsPrompt:
            // Headless `claude -p` does not process slash commands —
            // it would just see the literal "/start-task" as the user
            // prompt and ask claude to interpret it (which usually
            // produces nothing useful). Read the .md body ourselves,
            // forward it as the actual prompt, and tag the local
            // transcript message so the UI shows the original
            // `/<name>` in a collapsed tool-card-style row.
            let body = SlashCommandRegistry.readBody(of: cmd)
            if body.isEmpty {
                // Empty file or unreadable — fall back to sending the
                // literal command (claude may at least echo something).
                panel.send("/" + cmd.name)
            } else {
                panel.sendSlashCommand(name: cmd.name, expandedText: body)
            }
            panel.draft = ""
            forceScrollToBottomToken &+= 1
        }
    }

    /// Dispatch a built-in slash command by its registry key.
    private func runBuiltinSlashCommand(_ key: String) {
        switch key {
        case SlashCommandRegistry.BuiltinKey.clear:
            panel.clearTranscript()
        case SlashCommandRegistry.BuiltinKey.rewind,
             SlashCommandRegistry.BuiltinKey.undo:
            if panel.undoCheckpoints.isEmpty {
                panel.appendSystemNotice(String(
                    localized: "claudeChat.slash.rewind.empty",
                    defaultValue: "Nothing to rewind — no turns recorded yet."
                ))
                return
            }
            // Re-use the same dialog the header button raises.
            pendingRewindUserMessageId = nil
            showingUndoConfirmation = true
        case SlashCommandRegistry.BuiltinKey.cost:
            let value = panel.totalCostUSD
            let msg = String(
                format: String(
                    localized: "claudeChat.slash.cost.message",
                    defaultValue: "Cumulative API cost so far: %@"
                ),
                formatCost(value)
            )
            panel.appendSystemNotice(msg)
        case SlashCommandRegistry.BuiltinKey.model:
            let model = panel.modelName ?? String(
                localized: "claudeChat.slash.model.unknown",
                defaultValue: "(model not yet reported by claude)"
            )
            panel.appendSystemNotice(String(
                format: String(
                    localized: "claudeChat.slash.model.message",
                    defaultValue: "Active model: %@"
                ),
                model
            ))
        case SlashCommandRegistry.BuiltinKey.permissions:
            showingAlwaysAllowedPopover = true
        case SlashCommandRegistry.BuiltinKey.help:
            panel.appendSystemNotice(buildHelpMessage())
        default:
            break
        }
    }

    private func buildHelpMessage() -> String {
        var out = String(
            localized: "claudeChat.slash.help.header",
            defaultValue: "Available slash commands:"
        ) + "\n\n"
        for cmd in slashAllCommands {
            let scopeTag: String
            switch cmd.source {
            case .builtin: scopeTag = ""
            case .userCustom: scopeTag = " (user)"
            case .projectCustom: scopeTag = " (project)"
            }
            out += "- `/\(cmd.name)`\(scopeTag) — \(cmd.description)\n"
        }
        return out
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        palette.panelBg(colorScheme == .dark)
    }

    private var headerBackground: Color {
        palette.headerBg(colorScheme == .dark)
    }

    private var inputBackground: Color {
        palette.inputBg(colorScheme == .dark)
    }

    // MARK: - Focus flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        }
    }
}

private struct ToolUseCard: View {
    let toolUse: ChatMessageBlock.ToolUse
    let pending: ChatApprovalRequest?
    let result: ChatMessageBlock.ToolResult?
    let isDark: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    @Environment(\.chatPalette) private var palette
    @State private var expanded = false

    private var parsedInput: [String: Any]? {
        guard let data = toolUse.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private var summary: String {
        // Compact one-liner shown when the card is collapsed.
        switch toolUse.name {
        case "Edit", "Write", "NotebookEdit":
            if let path = parsedInput?["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "MultiEdit":
            if let path = parsedInput?["file_path"] as? String,
               let edits = parsedInput?["edits"] as? [[String: Any]] {
                return "\((path as NSString).lastPathComponent) · \(edits.count) edits"
            }
        case "Bash":
            if let cmd = parsedInput?["command"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ↵ ")
            }
        case "Read":
            if let path = parsedInput?["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        case "Glob", "Grep":
            if let pattern = parsedInput?["pattern"] as? String {
                return pattern
            }
        case "WebFetch":
            if let url = parsedInput?["url"] as? String {
                return url
            }
        case "WebSearch":
            if let q = parsedInput?["query"] as? String {
                return q
            }
        case "Skill":
            if let name = parsedInput?["skill"] as? String {
                if let args = parsedInput?["args"] as? String, !args.isEmpty {
                    return "\(name) · \(args)"
                }
                return name
            }
        case "Task":
            if let desc = parsedInput?["description"] as? String, !desc.isEmpty {
                return desc
            }
            if let agent = parsedInput?["subagent_type"] as? String {
                return agent
            }
        case "TodoWrite":
            if let todos = parsedInput?["todos"] as? [[String: Any]] {
                return "\(todos.count) todos"
            }
        default:
            break
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                header
            }
            .buttonStyle(.plain)
            if expanded {
                detail
                if let result {
                    Divider().opacity(0.4).padding(.vertical, 2)
                    ToolResultCard(result: result, isDark: isDark, embedded: true)
                }
            }
            if pending != nil {
                HStack(spacing: 6) {
                    Button(String(localized: "claudeChat.tool.deny", defaultValue: "Deny"), action: onDeny)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(String(localized: "claudeChat.tool.allow", defaultValue: "Allow"), action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    pending != nil ? ChatPalette.orange.opacity(0.6) : palette.borderSubtle(isDark),
                    lineWidth: 1
                )
        )
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 12)
            Text(toolUse.name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let result {
                Image(systemName: result.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(result.isError ? ChatPalette.red : ChatPalette.green.opacity(0.85))
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch toolUse.name {
        case "Edit", "MultiEdit", "NotebookEdit":
            return "pencil"
        case "Write":
            return "doc.badge.plus"
        case "Read":
            return "doc.text"
        case "Bash":
            return "terminal"
        case "Glob", "Grep":
            return "magnifyingglass"
        case "WebFetch", "WebSearch":
            return "globe"
        case "Skill":
            return "sparkles"
        case "Task":
            return "person.2"
        case "TodoWrite":
            return "checklist"
        default:
            return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var detail: some View {
        ToolInputDetailView(
            toolName: toolUse.name,
            input: parsedInput,
            rawJSON: toolUse.inputJSON,
            isDark: isDark
        )
    }
}

/// Shared tool-input renderer used by both `ToolUseCard` (post-execution
/// summary) and `ApprovalRequestCard` (pre-execution permission prompt).
/// Picks the right specialised view per tool name and falls back to a
/// pretty-printed JSON dump.
private struct ToolInputDetailView: View {
    let toolName: String
    let input: [String: Any]?
    let rawJSON: String
    let isDark: Bool

    @ViewBuilder
    var body: some View {
        switch toolName {
        case "Edit":
            EditDiffView(input: input, isDark: isDark)
        case "MultiEdit":
            MultiEditDiffView(input: input, isDark: isDark)
        case "Write":
            WriteDiffView(input: input, isDark: isDark)
        case "Bash":
            BashCommandView(input: input, isDark: isDark)
        case "Skill":
            SkillInvocationView(input: input, isDark: isDark)
        case "Task":
            TaskInvocationView(input: input, isDark: isDark)
        case "TodoWrite":
            TodoWriteView(input: input, isDark: isDark)
        default:
            Text(rawJSON)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SkillInvocationView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "claudeChat.tool.skill.label", defaultValue: "Skill"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                if let name = input?["skill"] as? String {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            if let args = input?["args"] as? String, !args.isEmpty {
                Text(args)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.codeBg(isDark))
                    )
            }
        }
    }
}

private struct TaskInvocationView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let agent = input?["subagent_type"] as? String {
                    Text(agent)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(palette.accent(isDark).opacity(0.75)))
                }
                if let desc = input?["description"] as? String, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let prompt = input?["prompt"] as? String, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.codeBg(isDark))
                    )
            }
        }
    }
}

private struct TodoWriteView: View {
    let input: [String: Any]?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(for: todo))
                        .font(.system(size: 11))
                        .foregroundColor(color(for: todo))
                        .padding(.top, 1)
                    Text(activeForm(of: todo))
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .strikethrough(status(of: todo) == "completed")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var todos: [[String: Any]] {
        (input?["todos"] as? [[String: Any]]) ?? []
    }

    private func status(of todo: [String: Any]) -> String {
        (todo["status"] as? String) ?? "pending"
    }

    private func activeForm(of todo: [String: Any]) -> String {
        if let active = todo["activeForm"] as? String, !active.isEmpty { return active }
        return (todo["content"] as? String) ?? ""
    }

    private func icon(for todo: [String: Any]) -> String {
        switch status(of: todo) {
        case "completed": return "checkmark.square.fill"
        case "in_progress": return "circle.dotted"
        default: return "square"
        }
    }

    private func color(for todo: [String: Any]) -> Color {
        switch status(of: todo) {
        case "completed": return ChatPalette.green
        case "in_progress": return ChatPalette.cyan
        default: return .secondary
        }
    }
}

// MARK: - Diff previews

private struct EditDiffView: View {
    let input: [String: Any]?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = input?["file_path"] as? String {
                filePathRow(path)
            }
            DiffBlock(
                old: input?["old_string"] as? String ?? "",
                new: input?["new_string"] as? String ?? "",
                isDark: isDark
            )
        }
    }
}

private struct MultiEditDiffView: View {
    let input: [String: Any]?
    let isDark: Bool

    /// Cap edits rendered to avoid hundreds of DiffBlocks blowing up
    /// SwiftUI layout. Anything beyond is summarised.
    private static let maxEditsRendered = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = input?["file_path"] as? String {
                filePathRow(path)
            }
            let allEdits = (input?["edits"] as? [[String: Any]]) ?? []
            let renderedEdits = Array(allEdits.prefix(Self.maxEditsRendered))
            ForEach(Array(renderedEdits.enumerated()), id: \.offset) { idx, edit in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit \(idx + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    DiffBlock(
                        old: edit["old_string"] as? String ?? "",
                        new: edit["new_string"] as? String ?? "",
                        isDark: isDark
                    )
                }
            }
            if allEdits.count > Self.maxEditsRendered {
                Text("… [\(allEdits.count - Self.maxEditsRendered) more edits hidden]")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct WriteDiffView: View {
    let input: [String: Any]?
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = input?["file_path"] as? String {
                filePathRow(path)
            }
            DiffBlock(old: "", new: input?["content"] as? String ?? "", isDark: isDark)
        }
    }
}

private struct BashCommandView: View {
    let input: [String: Any]?
    let isDark: Bool

    @Environment(\.chatPalette) private var palette

    /// Bash commands are usually short, but a paste-in heredoc could be
    /// massive. Cap before handing to Text to keep layout cheap.
    private static let maxCommandChars = 8_000

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let desc = input?["description"] as? String, !desc.isEmpty {
                Text(String(desc.prefix(500)))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let cmd = input?["command"] as? String {
                let displayed: String = {
                    if cmd.count <= Self.maxCommandChars { return cmd }
                    return String(cmd.prefix(Self.maxCommandChars))
                        + "\n\n… [\(cmd.count - Self.maxCommandChars) more chars truncated]"
                }()
                Text(displayed)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(palette.fg(isDark))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.codeBg(isDark))
                    )
            }
        }
    }
}

@ViewBuilder
private func filePathRow(_ path: String) -> some View {
    HStack(spacing: 4) {
        Image(systemName: "doc")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        Text(path)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// Renders an old/new pair as a unified-diff-style preview. Lines from
/// `old` are shown red with a leading `-`; lines from `new` are green with
/// `+`. We don't compute a proper LCS diff — the model already gives us
/// pre-aligned old/new strings, and rendering them as two contiguous blocks
/// is enough for visual review.
private struct DiffBlock: View {
    let old: String
    let new: String
    let isDark: Bool

    @Environment(\.chatPalette) private var palette
    @State private var expandedGaps: Set<UUID> = []

    /// Max characters per individual line — keeps Text layout fast for
    /// files with very long lines (e.g. minified JSON).
    private static let maxLineCharWidth = 4_000
    /// Surrounding context lines kept around each change.
    private static let contextLines = 3

    private var diffLines: [UnifiedDiffLine] {
        UnifiedDiff.compute(old: old, new: new, context: Self.contextLines)
    }

    private var addColor: Color { ChatPalette.green }
    private var removeColor: Color { ChatPalette.red }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines) { line in
                row(for: line)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.codeBg(isDark))
        )
    }

    @ViewBuilder
    private func row(for line: UnifiedDiffLine) -> some View {
        switch line {
        case .context(_, let text, let oldNo, let newNo):
            diffLine(
                marker: " ",
                markerColor: .secondary,
                text: text,
                oldNo: oldNo,
                newNo: newNo,
                rowBackground: .clear
            )
        case .removed(_, let text, let oldNo):
            diffLine(
                marker: "-",
                markerColor: removeColor,
                text: text,
                oldNo: oldNo,
                newNo: nil,
                rowBackground: removeColor.opacity(0.16)
            )
        case .added(_, let text, let newNo):
            diffLine(
                marker: "+",
                markerColor: addColor,
                text: text,
                oldNo: nil,
                newNo: newNo,
                rowBackground: addColor.opacity(0.16)
            )
        case .gap(let id, let hiddenLines):
            if expandedGaps.contains(id) {
                ForEach(hiddenLines) { hidden in
                    diffLine(
                        marker: " ",
                        markerColor: .secondary,
                        text: hidden.text,
                        oldNo: hidden.oldLineNo,
                        newNo: hidden.newLineNo,
                        rowBackground: .clear
                    )
                }
            } else {
                gapRow(id: id, count: hiddenLines.count)
            }
        }
    }

    private func diffLine(
        marker: String,
        markerColor: Color,
        text: String,
        oldNo: Int?,
        newNo: Int?,
        rowBackground: Color
    ) -> some View {
        let truncated = String(text.prefix(Self.maxLineCharWidth))
        return HStack(alignment: .top, spacing: 6) {
            Text(oldNo.map { String($0) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
            Text(newNo.map { String($0) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
            Text(marker)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(markerColor)
                .frame(width: 10, alignment: .leading)
            Text(truncated.isEmpty ? " " : truncated)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(rowBackground)
    }

    private func gapRow(id: UUID, count: Int) -> some View {
        Button {
            expandedGaps.insert(id)
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .center)
                Text(String(
                    localized: "claudeChat.diff.unmodifiedLines",
                    defaultValue: "\(count) unmodified lines"
                ))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardSubtleBg(isDark))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(
            localized: "claudeChat.diff.unmodifiedLines.tooltip",
            defaultValue: "Click to reveal unchanged surrounding lines"
        ))
    }
}

private struct ApprovalRequestCard: View {
    let request: ChatApprovalRequest
    let isDark: Bool
    let onApprove: () -> Void
    let onApproveAlways: () -> Void
    let onDeny: () -> Void

    @Environment(\.chatPalette) private var palette
    @State private var expanded = true

    /// Re-parse the inputJSON we received from the MCP server. The server
    /// pretty-prints it for display; here we want the structured form so we
    /// can route to the right detail view (Edit diff, Bash command, etc.).
    private var parsedInput: [String: Any]? {
        guard let data = request.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ChatPalette.orange)
                Text(String(localized: "claudeChat.approval.title", defaultValue: "Allow tool?"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(request.toolName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            if expanded, !request.inputJSON.isEmpty {
                ToolInputDetailView(
                    toolName: request.toolName,
                    input: parsedInput,
                    rawJSON: request.inputJSON,
                    isDark: isDark
                )
            }
            HStack(spacing: 8) {
                Button(String(localized: "claudeChat.tool.deny", defaultValue: "Deny"), action: onDeny)
                    .buttonStyle(.bordered)
                Button(action: onApproveAlways) {
                    Text(String(
                        localized: "claudeChat.tool.allowAlways",
                        defaultValue: "Allow always"
                    ))
                }
                .buttonStyle(.bordered)
                .help(String(
                    localized: "claudeChat.tool.allowAlways.tooltip",
                    defaultValue: "Allow this and any future call to the same tool in this chat without asking again."
                ))
                Button(String(localized: "claudeChat.tool.allow", defaultValue: "Allow"), action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChatPalette.orange.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct UserQuestionCard: View {
    let request: ChatUserQuestionRequest
    let isDark: Bool
    let onAnswer: ([[String]]) -> Void

    @Environment(\.chatPalette) private var palette
    /// One Set per sub-question, indexed by sub-question position.
    @State private var selectedByIndex: [Set<String>] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, sub in
                subQuestionView(index: index, sub: sub)
            }
            HStack {
                Spacer()
                Button(String(localized: "claudeChat.question.submit", defaultValue: "Submit")) {
                    submitAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allAnswered)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ChatPalette.cyan.opacity(0.5), lineWidth: 1)
        )
        .onAppear {
            if selectedByIndex.count != request.questions.count {
                selectedByIndex = Array(repeating: Set<String>(), count: request.questions.count)
            }
        }
    }

    @ViewBuilder
    private func subQuestionView(index: Int, sub: ChatUserQuestionRequest.SubQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(ChatPalette.cyan)
                if let header = sub.header, !header.isEmpty {
                    Text(header)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ChatPalette.cyan.opacity(0.6)))
                }
                Text(sub.question)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sub.options) { option in
                    optionButton(index: index, sub: sub, option: option)
                }
            }
        }
    }

    @ViewBuilder
    private func optionButton(
        index: Int,
        sub: ChatUserQuestionRequest.SubQuestion,
        option: ChatUserQuestionRequest.Option
    ) -> some View {
        let isSelected = selectedByIndex.indices.contains(index)
            && selectedByIndex[index].contains(option.label)
        Button {
            toggle(index: index, sub: sub, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: optionIcon(sub: sub, isSelected: isSelected))
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                        ? ChatPalette.cyan.opacity(0.18)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(index: Int, sub: ChatUserQuestionRequest.SubQuestion, label: String) {
        guard selectedByIndex.indices.contains(index) else { return }
        if sub.multiSelect {
            if selectedByIndex[index].contains(label) {
                selectedByIndex[index].remove(label)
            } else {
                selectedByIndex[index].insert(label)
            }
        } else {
            selectedByIndex[index] = [label]
        }
    }

    private func optionIcon(sub: ChatUserQuestionRequest.SubQuestion, isSelected: Bool) -> String {
        if sub.multiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        } else {
            return isSelected ? "largecircle.fill.circle" : "circle"
        }
    }

    private var allAnswered: Bool {
        selectedByIndex.count == request.questions.count
            && !selectedByIndex.contains(where: { $0.isEmpty })
    }

    private func submitAll() {
        let answers: [[String]] = selectedByIndex.map { Array($0) }
        onAnswer(answers)
    }
}

private struct ToolResultCard: View {
    let result: ChatMessageBlock.ToolResult
    let isDark: Bool
    /// When true, the card is rendered inline inside another card
    /// (e.g. the matching `ToolUseCard`) and skips its own background.
    var embedded: Bool = false

    @Environment(\.chatPalette) private var palette
    @State private var expanded = false

    /// Hard caps applied before handing strings to SwiftUI's Text layout.
    /// A single Text view with multiple MB of content blocks the main
    /// thread for seconds — the cause of the May 8 hang we just shipped
    /// a fix for.
    private static let firstLineCharLimit = 500
    private static let expandedCharLimit = 80_000

    private var trimmed: String {
        result.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var firstLine: String {
        // Take only the first 4KB to find the first newline; if the whole
        // content is one giant line we still cap it.
        let head = trimmed.prefix(4_000)
        let candidate: String
        if let line = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            candidate = String(line)
        } else {
            candidate = String(head)
        }
        return String(candidate.prefix(Self.firstLineCharLimit))
    }

    private var hasMore: Bool {
        trimmed.contains("\n") || trimmed.count > firstLine.count
    }

    private var lineCount: Int {
        if trimmed.isEmpty { return 0 }
        // Counting `\n` is O(n) and good enough; avoid `components(separatedBy:)`
        // which materialises the whole array.
        var count = 1
        for ch in trimmed where ch == "\n" { count += 1 }
        return count
    }

    private var expandedDisplay: String {
        if trimmed.count <= Self.expandedCharLimit { return trimmed }
        let truncated = String(trimmed.prefix(Self.expandedCharLimit))
        let suffix = "\n\n… [\(trimmed.count - Self.expandedCharLimit) more chars truncated]"
        return truncated + suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: result.isError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundColor(result.isError ? ChatPalette.red : ChatPalette.green)
                    .font(.system(size: 11))
                Text(expanded || !hasMore ? firstLine : firstLine.isEmpty ? "(empty)" : firstLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if hasMore {
                    Button(action: { expanded.toggle() }) {
                        HStack(spacing: 2) {
                            if !expanded {
                                Text("+\(lineCount - 1)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if expanded, hasMore {
                Text(expandedDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .padding(embedded ? 0 : 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(embedded
                    ? Color.clear
                    : palette.resultBg(isDark))
        )
    }
}

// MARK: - Theme

/// Chat-specific markdown theme. Mirrors `cmuxMarkdownTheme` from
/// `MarkdownPanelView` but with smaller margins and theme-aware colours.
/// `palette` carries the user's terminal background/foreground so inline
/// code highlight stays legible across themes.
private func cmuxChatMarkdownTheme(isDark: Bool, palette: ChatPalette) -> Theme {
    Theme()
        .text {
            ForegroundColor(palette.fg(isDark))
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            // IntelliJ-Darcula-style: inline code uses the same blue as
            // identifiers/keywords in the editor. Avoid the prior purple
            // because it clashed with the rest of the palette. A brighter
            // shade than `ChatPalette.blue` to read clearly against the
            // terminal-bg-derived inline-code background.
            ForegroundColor(isDark ? Color(red: 0x6F/255.0, green: 0xB1/255.0, blue: 0xFF/255.0) : Color(red: 0.18, green: 0.42, blue: 0.78))
            BackgroundColor(palette.codeBg(isDark))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(12)
                    }
                    .padding(10)
            }
            .background(palette.codeBg(isDark))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 6, bottom: 6)
        }
        .link {
            ForegroundColor(isDark ? ChatPalette.cyan : Color.accentColor)
        }
        .strong {
            FontWeight(.semibold)
        }
        .paragraph { configuration in
            configuration.label.markdownMargin(top: 2, bottom: 4)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: 2, bottom: 2)
        }
}

// MARK: - Chat input

/// Multi-line text input with chat semantics:
/// - Enter (Return alone) submits the message.
/// - Shift+Enter inserts a newline.
/// - Escape calls `onCancel` (used to stop an in-flight turn).
/// - Auto-grows up to its frame height with internal scrolling.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isDark: Bool
    let textColor: NSColor
    /// Bumped externally to demand keyboard focus (e.g. after the user
    /// drops an attachment, so the next keystroke goes to the input even
    /// if the panel was sharing a window with another focused pane).
    var focusToken: Int = 0
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Fired when the underlying NSTextView takes first-responder, so the
    /// host can update bonsplit's "focused pane" bookkeeping. Without this,
    /// clicking into the chat input does not unstick a stale focus that
    /// still points at a sibling terminal pane, and keystrokes leak there.
    var onBecomeFirstResponder: (() -> Void)? = nil
    /// Popup-driven key intercepts (slash-command dropdown). Each returns
    /// `true` to swallow the key, `false` to fall through to NSTextView.
    var onArrowUp: (() -> Bool)? = nil
    var onArrowDown: (() -> Bool)? = nil
    var onTabKey: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        let chatTextView = ChatInputNSTextView()
        chatTextView.frame = textView.frame
        chatTextView.autoresizingMask = textView.autoresizingMask
        chatTextView.textContainerInset = NSSize(width: 0, height: 4)
        chatTextView.isRichText = false
        chatTextView.allowsUndo = true
        chatTextView.usesFontPanel = false
        chatTextView.isAutomaticDataDetectionEnabled = false
        chatTextView.isAutomaticLinkDetectionEnabled = false
        chatTextView.isAutomaticTextReplacementEnabled = false
        chatTextView.isAutomaticSpellingCorrectionEnabled = false
        chatTextView.smartInsertDeleteEnabled = false
        chatTextView.font = NSFont.systemFont(ofSize: 13)
        chatTextView.textColor = isDark ? textColor : NSColor.labelColor
        chatTextView.insertionPointColor = isDark ? textColor : NSColor.labelColor
        chatTextView.delegate = context.coordinator
        chatTextView.onSubmit = onSubmit
        chatTextView.onCancel = onCancel
        chatTextView.onBecomeFirstResponder = onBecomeFirstResponder
        chatTextView.onArrowUp = onArrowUp
        chatTextView.onArrowDown = onArrowDown
        chatTextView.onTabKey = onTabKey
        chatTextView.string = text
        chatTextView.placeholderString = placeholder

        scrollView.documentView = chatTextView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let chatTextView = nsView.documentView as? ChatInputNSTextView else { return }
        if chatTextView.string != text {
            chatTextView.string = text
            chatTextView.placeholderString = placeholder
        }
        chatTextView.placeholderString = placeholder
        chatTextView.textColor = isDark ? textColor : NSColor.labelColor
        chatTextView.insertionPointColor = isDark ? textColor : NSColor.labelColor
        chatTextView.onSubmit = onSubmit
        chatTextView.onCancel = onCancel
        chatTextView.onBecomeFirstResponder = onBecomeFirstResponder
        chatTextView.onArrowUp = onArrowUp
        chatTextView.onArrowDown = onArrowDown
        chatTextView.onTabKey = onTabKey
        // Honor an external focus request — bump the token via @State and
        // we steal first-responder on the next render.
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                chatTextView.window?.makeFirstResponder(chatTextView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        var lastFocusToken: Int = 0

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

final class ChatInputNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fires when this view takes first-responder. cmux uses it to mark
    /// the surrounding pane as the focused pane in bonsplit, preventing
    /// keystrokes from leaking to a sibling terminal that bonsplit still
    /// remembers as focused.
    var onBecomeFirstResponder: (() -> Void)?
    /// Optional intercepts for popup-driven UI (e.g. slash-command
    /// dropdown). Each handler returns `true` to swallow the key, `false`
    /// to fall through to the normal NSTextView behavior.
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onTabKey: (() -> Bool)?
    var placeholderString: String = "" {
        didSet {
            needsDisplay = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // Escape: cancel.
        if event.keyCode == 53 {  // 53 = escape
            onCancel?()
            return
        }
        // Up/Down arrows: when a popup is up these navigate the popup
        // selection; otherwise the NSTextView default (caret movement)
        // applies. Use keyCode rather than chars so non-US layouts behave.
        if event.keyCode == 126, let onArrowUp, onArrowUp() { return }    // up
        if event.keyCode == 125, let onArrowDown, onArrowDown() { return } // down
        // Tab: prefer-completion when a popup is up; otherwise default
        // keyView/insert-tab behavior.
        if event.keyCode == 48, let onTabKey, onTabKey() { return }
        // Return: submit (unless Shift+Return, which inserts a newline).
        let isReturn = event.charactersIgnoringModifiers == "\r" || event.keyCode == 36
        if isReturn {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}

// MARK: - Chat row model

/// One renderable row in the chat transcript. Adjacent assistant
/// `tool_use` blocks are grouped into a `ToolBatch` so we can collapse
/// long bursts of tool calls into a single header.
enum ChatRow {
    case text(TextPayload)
    case toolBatch(ToolBatch)

    var id: String {
        switch self {
        case .text(let payload): return payload.id
        case .toolBatch(let batch): return batch.id
        }
    }

    struct TextPayload {
        let id: String
        let role: ChatMessageRole
        let text: String
        let attachmentURLs: [URL]
        /// Original `ChatMessage.id` — used by the inline rewind button
        /// to look up the matching checkpoint on the panel.
        let messageId: UUID
        /// Render the bubble collapsed (with a disclosure to expand).
        /// True for slash-command expansions and any other stream-
        /// injected user messages.
        var isCollapsedByDefault: Bool = false
        /// When this row was produced by invoking a slash command, the
        /// `/`-less name of that command — surfaced in the collapsed
        /// header so the user can tell which command produced it.
        var slashCommandName: String? = nil
    }

    struct ToolBatch {
        let id: String
        let entries: [Entry]

        struct Entry: Identifiable {
            var id: String { toolUse.id }
            let messageId: UUID
            let toolUse: ChatMessageBlock.ToolUse
        }
    }
}

enum ChatRowBuilder {
    static func buildRows(from messages: [ChatMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var batchEntries: [ChatRow.ToolBatch.Entry] = []
        var batchAnchorId: String?

        func flushBatch() {
            guard !batchEntries.isEmpty else { return }
            let id = batchAnchorId ?? UUID().uuidString
            rows.append(.toolBatch(.init(id: id, entries: batchEntries)))
            batchEntries.removeAll()
            batchAnchorId = nil
        }

        for message in messages {
            // For user messages with attachments but no text bubble we
            // still need a row so thumbnails render.
            if message.role == .user, message.blocks.isEmpty, !message.attachmentURLs.isEmpty {
                flushBatch()
                rows.append(.text(.init(
                    id: "\(message.id.uuidString)-attachOnly",
                    role: message.role,
                    text: "",
                    attachmentURLs: message.attachmentURLs,
                    messageId: message.id,
                    isCollapsedByDefault: message.isCollapsedByDefault,
                    slashCommandName: message.slashCommandName
                )))
                continue
            }
            var emittedAttachmentsForMessage = false
            for (idx, block) in message.blocks.enumerated() {
                switch block {
                case .text(let value):
                    flushBatch()
                    let attachments = (message.role == .user && !emittedAttachmentsForMessage)
                        ? message.attachmentURLs
                        : []
                    emittedAttachmentsForMessage = true
                    rows.append(.text(.init(
                        id: "\(message.id.uuidString)-\(idx)",
                        role: message.role,
                        text: value,
                        attachmentURLs: attachments,
                        messageId: message.id,
                        isCollapsedByDefault: message.isCollapsedByDefault,
                        slashCommandName: message.slashCommandName
                    )))
                case .toolUse(let toolUse):
                    if batchAnchorId == nil {
                        batchAnchorId = "batch-\(toolUse.id)"
                    }
                    batchEntries.append(.init(messageId: message.id, toolUse: toolUse))
                case .toolResult:
                    // Filtered into `toolResultsByToolUseId` at the panel
                    // level; if one slips through here we just ignore it.
                    break
                }
            }
        }
        flushBatch()
        return rows
    }
}

// MARK: - Text block row

private struct TextBlockRow: View {
    let role: ChatMessageRole
    let text: String
    var attachmentURLs: [URL] = []
    var messageId: UUID? = nil
    let isDark: Bool
    var canRewindToHere: Bool = false
    var onRewindToHere: ((UUID) -> Void)? = nil
    /// True for stream-injected user messages (e.g. claude's expansion
    /// of a slash command). Renders with a disclosure header so the
    /// transcript stays compact.
    var isCollapsedByDefault: Bool = false
    /// When this row is a slash-command expansion, the original `/`-less
    /// command name. Used as the header label so the user sees
    /// `/start-task` instead of a generic "Slash command prompt".
    var slashCommandName: String? = nil

    @Environment(\.chatPalette) private var palette
    @State private var isHovered: Bool = false
    @State private var isExpanded: Bool = false

    var body: some View {
        Group {
            switch role {
            case .user:
                if isCollapsedByDefault {
                    // Stream-injected user message (slash-command
                    // expansion). Render full-width as a tool-card-style
                    // collapsible block so it visually matches claude's
                    // own tool cards instead of pretending to be a chat
                    // bubble.
                    streamUserPromptCard
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        if canRewindToHere, isHovered, let id = messageId {
                            Button {
                                onRewindToHere?(id)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 6)
                            }
                            .buttonStyle(.plain)
                            .help(String(
                                localized: "claudeChat.rewindToHere.tooltip",
                                defaultValue: "Rewind the conversation and the files claude edited back to just after this message"
                            ))
                            .transition(.opacity)
                        }
                        VStack(alignment: .trailing, spacing: 6) {
                            if !attachmentURLs.isEmpty {
                                SentAttachmentsRow(urls: attachmentURLs, isDark: isDark)
                            }
                            if !text.isEmpty {
                                Text(text)
                                    .font(.system(size: 13))
                                    .foregroundColor(palette.fg(isDark))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(palette.accent(isDark).opacity(isDark ? 0.30 : 0.18))
                                    )
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .onHover { hovering in
                        isHovered = hovering
                    }
                }
            case .assistant, .system:
                Markdown(text)
                    .markdownTheme(cmuxChatMarkdownTheme(isDark: isDark, palette: palette))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Tool-card-style block for stream-injected user prompts (a slash
    /// command's expansion lands here). Visual chrome matches claude's
    /// own ToolUseCard so the user spots it as "the same kind of thing":
    /// header row with an icon + label + truncated summary + chevron,
    /// rounded card with a subtle border, body that appears below the
    /// header when expanded.
    private var streamUserPromptCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Text(headerLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    if !collapsedSummary.isEmpty {
                        Text(collapsedSummary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.fg(isDark))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.codeBg(isDark))
                    )
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.cardBg(isDark))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Header label shown on the collapsed card: the slash command
    /// name when known, otherwise a generic "Slash command prompt".
    private var headerLabel: String {
        if let name = slashCommandName, !name.isEmpty {
            return "/\(name)"
        }
        return String(
            localized: "claudeChat.slashPrompt.label",
            defaultValue: "Slash command prompt"
        )
    }

    /// One-line summary for the collapsed header: the first non-empty
    /// line, capped at 80 chars; or "(N lines)" when the first line is
    /// empty (rare).
    private var collapsedSummary: String {
        let lineCount = text.components(separatedBy: "\n").count
        let first = text
            .components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if first.isEmpty {
            return String(format: String(
                localized: "claudeChat.collapsed.linesOnly",
                defaultValue: "(%d lines)"
            ), lineCount)
        }
        let cap = 80
        let truncated = first.count > cap ? String(first.prefix(cap)) + "…" : first
        if lineCount > 1 {
            return "\(truncated)  ·  \(lineCount) lines"
        }
        return truncated
    }
}

// MARK: - Tool batch view

/// Renders a contiguous run of tool_use cards. When the batch is small
/// (≤ inlineThreshold) all cards are shown. When large, older cards
/// collapse behind a "N tools used" header; if the batch is the current
/// (turn still streaming) the most recent tool stays visible below the
/// header so the user can see what's running.
private struct ToolBatchView: View {
    let entries: [ChatRow.ToolBatch.Entry]
    let pendingApprovals: [ChatApprovalRequest]
    let toolResults: [String: ChatMessageBlock.ToolResult]
    let isCurrentBatch: Bool
    let isDark: Bool
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    @Environment(\.chatPalette) private var palette
    @State private var expanded: Bool = false

    /// Tool batches with 2+ entries always render with a collapsible
    /// header (a single tool stays inline as a regular card). Any
    /// stream of consecutive `tool_use` blocks ends up under one
    /// "N tools used" header so the transcript stays compact even on
    /// short bursts.
    private static let inlineThreshold = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entries.count <= Self.inlineThreshold {
                ForEach(entries) { entry in
                    cardFor(entry)
                }
            } else if isCurrentBatch {
                let collapsedCount = entries.count - 1
                if collapsedCount > 0 {
                    collapsedHeader(count: collapsedCount, finished: false)
                    if expanded {
                        ForEach(entries.dropLast()) { entry in
                            cardFor(entry)
                        }
                    }
                }
                if let last = entries.last {
                    cardFor(last)
                }
            } else {
                collapsedHeader(count: entries.count, finished: true)
                if expanded {
                    ForEach(entries) { entry in
                        cardFor(entry)
                    }
                }
            }
        }
    }

    private func cardFor(_ entry: ChatRow.ToolBatch.Entry) -> some View {
        ToolUseCard(
            toolUse: entry.toolUse,
            pending: pendingApprovals.first(where: { $0.id == entry.toolUse.id }),
            result: toolResults[entry.toolUse.id],
            isDark: isDark,
            onApprove: { onApprove(entry.toolUse.id) },
            onDeny: { onDeny(entry.toolUse.id) }
        )
    }

    private func collapsedHeader(count: Int, finished: Bool) -> some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(headerLabel(count: count, finished: finished))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if !expanded {
                    Text(toolNameSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.cardSubtleBg(isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(palette.borderSubtle(isDark), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headerLabel(count: Int, finished: Bool) -> String {
        if finished {
            return String(
                localized: "claudeChat.toolBatch.finished",
                defaultValue: "\(count) tools used"
            )
        }
        return String(
            localized: "claudeChat.toolBatch.previous",
            defaultValue: "\(count) earlier tools"
        )
    }

    private var toolNameSummary: String {
        // Show up to 4 distinct tool names so the user can glance at what
        // ran without expanding.
        var seen: [String] = []
        for entry in entries {
            if !seen.contains(entry.toolUse.name) {
                seen.append(entry.toolUse.name)
                if seen.count >= 4 { break }
            }
        }
        return seen.joined(separator: ", ")
    }
}

// MARK: - Slash command popup

/// Floating list of slash commands shown above the chat input while the
/// user types a `/`-prefixed name. Visual style matches the rest of the
/// chat: panel-derived card background, thin border, two-line rows with
/// the command name in mono and a description below.
private struct SlashCommandPopup: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    let palette: ChatPalette
    let isDark: Bool
    let onPick: (Int) -> Void

    /// Cap so a project with dozens of custom commands does not push the
    /// chat history off-screen — the user can scroll inside the popup.
    private static let maxListHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    // Plain VStack (not Lazy): we cap the list at a few
                    // dozen commands so the lazy upside is negligible,
                    // and LazyVStack inside an NSHostingView (the
                    // ChatDropContainer wrapping the panel) recycles
                    // rows aggressively when the data shrinks — which
                    // produced ghost rows after filtering. Render
                    // every row up-front instead.
                    VStack(spacing: 0) {
                        ForEach(commands) { cmd in
                            let idx = commands.firstIndex(where: { $0.id == cmd.id }) ?? 0
                            SlashCommandRow(
                                command: cmd,
                                isSelected: idx == selectedIndex,
                                palette: palette,
                                isDark: isDark
                            )
                            .id(cmd.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(idx) }
                            if idx < commands.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
                .frame(maxHeight: Self.maxListHeight)
                .onChange(of: selectedIndex) { newValue in
                    // Keep the highlighted row visible while the user
                    // arrows through a long list. We scroll to the
                    // command's stable id rather than the index so the
                    // anchor stays valid across filter transitions.
                    guard newValue >= 0, newValue < commands.count else { return }
                    let target = commands[newValue].id
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            HStack(spacing: 10) {
                hint(symbol: "↑↓", label: String(
                    localized: "claudeChat.slash.hint.move",
                    defaultValue: "navigate"
                ))
                hint(symbol: "↩", label: String(
                    localized: "claudeChat.slash.hint.run",
                    defaultValue: "run"
                ))
                hint(symbol: "⇥", label: String(
                    localized: "claudeChat.slash.hint.complete",
                    defaultValue: "complete"
                ))
                hint(symbol: "esc", label: String(
                    localized: "claudeChat.slash.hint.dismiss",
                    defaultValue: "dismiss"
                ))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.cardSubtleBg(isDark))
        }
        .background(palette.cardBg(isDark))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.borderSubtle(isDark), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: Color.black.opacity(isDark ? 0.5 : 0.18), radius: 12, y: 4)
    }

    private func hint(symbol: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(symbol).font(.system(size: 10, design: .monospaced))
            Text(label)
        }
    }
}

private struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool
    let palette: ChatPalette
    let isDark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.displayTitle)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(palette.fg(isDark))
                    sourceTag
                }
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isSelected ? palette.accent(isDark).opacity(isDark ? 0.22 : 0.14) : Color.clear
        )
    }

    @ViewBuilder
    private var sourceTag: some View {
        switch command.source {
        case .builtin:
            EmptyView()
        case .userCustom:
            Text(String(localized: "claudeChat.slash.source.user", defaultValue: "user"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        case .projectCustom:
            Text(String(localized: "claudeChat.slash.source.project", defaultValue: "project"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
        }
    }
}

// MARK: - ANSI / SGR renderer

/// Minimal ANSI escape-sequence parser that turns the output of a
/// status-line script into a SwiftUI `AttributedString`. Honours the
/// 30-bit-color SGR subset most shell scripts use:
///   - reset (0)
///   - bold (1), dim (2), italic (3), underline (4), strikethrough (9)
///   - 16 base foreground/background colors (30-37, 40-47)
///   - 16 bright foreground/background colors (90-97, 100-107)
///   - 256-color (38;5;N / 48;5;N), 24-bit color (38;2;R;G;B / 48;2;…)
///   - default fg/bg (39, 49)
/// CSI sequences other than `m` (cursor moves, etc.) and OSC blocks
/// are silently dropped.
enum ANSIRenderer {
    static func attributedString(
        from text: String,
        baseFont: Font,
        defaultColor: Color
    ) -> AttributedString {
        var result = AttributedString()
        var fg: Color? = nil
        var bg: Color? = nil
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var dim = false

        var buffer = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var part = AttributedString(buffer)
            var attrs = AttributeContainer()
            // Foreground: explicit > dim default > base default.
            let resolvedFg = fg ?? (dim ? defaultColor.opacity(0.6) : defaultColor)
            attrs.foregroundColor = resolvedFg
            if let bg { attrs.backgroundColor = bg }
            var f = baseFont
            if bold { f = f.bold() }
            if italic { f = f.italic() }
            attrs.font = f
            if underline { attrs.underlineStyle = .single }
            if strikethrough { attrs.strikethroughStyle = .single }
            part.setAttributes(attrs)
            result.append(part)
            buffer = ""
        }

        // NOTE: there used to be a `resetAll` closure captured by reference
        // and forwarded into `applySGR` as `reset: () -> Void`. That tripped
        // Swift's exclusivity checker — `applySGR` already holds inout
        // access to `fg`, `bg`, `bold`, … and the closure tried to mutate
        // the same variables through its capture list. Same memory,
        // overlapping accesses → `Fatal access conflict detected`. The
        // reset (SGR param 0) is now handled inline inside `applySGR`.

        while i < scalars.count {
            let v = scalars[i].value
            if v == 0x1B {  // ESC
                let next = i + 1 < scalars.count ? scalars[i + 1].value : 0
                if next == 0x5B {  // CSI: ESC [ <params> <final>
                    flush()
                    i += 2
                    var params = ""
                    var finalByte: UInt32 = 0
                    while i < scalars.count {
                        let cv = scalars[i].value
                        i += 1
                        if cv >= 0x30 && cv <= 0x3F {
                            params.unicodeScalars.append(scalars[i - 1])
                            continue
                        }
                        if cv >= 0x40 && cv <= 0x7E {
                            finalByte = cv
                            break
                        }
                        // intermediates 0x20-0x2F or stray bytes — ignore.
                    }
                    if finalByte == 0x6D {  // 'm' = SGR
                        applySGR(
                            params: parseParams(params),
                            fg: &fg, bg: &bg,
                            bold: &bold, italic: &italic,
                            underline: &underline,
                            strikethrough: &strikethrough,
                            dim: &dim
                        )
                    }
                    continue
                }
                if next == 0x5D {  // OSC: ESC ] ... (BEL | ESC \)
                    flush()
                    i += 2
                    while i < scalars.count {
                        let cv = scalars[i].value
                        if cv == 0x07 { i += 1; break }
                        if cv == 0x1B,
                           i + 1 < scalars.count,
                           scalars[i + 1].value == 0x5C {
                            i += 2
                            break
                        }
                        i += 1
                    }
                    continue
                }
                // Two-byte ESC <final>
                i += 2
                continue
            }
            buffer.unicodeScalars.append(scalars[i])
            i += 1
        }
        flush()
        return result
    }

    private static func parseParams(_ s: String) -> [Int] {
        if s.isEmpty { return [0] }  // bare `ESC[m` is reset
        return s.split(separator: ";", omittingEmptySubsequences: false).map { piece in
            Int(piece) ?? 0
        }
    }

    private static func applySGR(
        params: [Int],
        fg: inout Color?,
        bg: inout Color?,
        bold: inout Bool,
        italic: inout Bool,
        underline: inout Bool,
        strikethrough: inout Bool,
        dim: inout Bool
    ) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                // Reset every attribute. Inlined intentionally — passing
                // this as a closure that captured the same vars by
                // reference triggered Swift's exclusive-access checker
                // because the inout parameters already hold exclusive
                // access to the same memory.
                fg = nil
                bg = nil
                bold = false
                italic = false
                underline = false
                strikethrough = false
                dim = false
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 9: strikethrough = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 29: strikethrough = false
            case 30...37: fg = ansiBaseColor(p - 30, bright: false)
            case 39: fg = nil
            case 40...47: bg = ansiBaseColor(p - 40, bright: false)
            case 49: bg = nil
            case 90...97: fg = ansiBaseColor(p - 90, bright: true)
            case 100...107: bg = ansiBaseColor(p - 100, bright: true)
            case 38, 48:
                // Extended color: 38;5;N (256-color) or 38;2;R;G;B.
                let isFg = p == 38
                guard i + 1 < params.count else { i += 1; continue }
                let mode = params[i + 1]
                if mode == 5, i + 2 < params.count {
                    let n = params[i + 2]
                    let c = xterm256(n)
                    if isFg { fg = c } else { bg = c }
                    i += 3
                    continue
                }
                if mode == 2, i + 4 < params.count {
                    let r = max(0, min(255, params[i + 2]))
                    let g = max(0, min(255, params[i + 3]))
                    let b = max(0, min(255, params[i + 4]))
                    let c = Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
                    if isFg { fg = c } else { bg = c }
                    i += 5
                    continue
                }
                i += 2
                continue
            default:
                break
            }
            i += 1
        }
    }

    /// Standard 16-color ANSI palette (matches macOS Terminal defaults
    /// closely). Index 0-7; `bright` selects the 8-15 bank.
    private static func ansiBaseColor(_ idx: Int, bright: Bool) -> Color {
        let basic: [(Double, Double, Double)] = [
            (0.00, 0.00, 0.00),  // black
            (0.80, 0.00, 0.00),  // red
            (0.31, 0.61, 0.02),  // green
            (0.77, 0.63, 0.00),  // yellow
            (0.20, 0.40, 0.64),  // blue
            (0.46, 0.31, 0.48),  // magenta
            (0.02, 0.60, 0.60),  // cyan
            (0.83, 0.84, 0.81),  // white
        ]
        let brightTable: [(Double, Double, Double)] = [
            (0.33, 0.34, 0.32),  // bright black
            (0.94, 0.16, 0.16),  // bright red
            (0.54, 0.89, 0.20),  // bright green
            (0.99, 0.91, 0.31),  // bright yellow
            (0.45, 0.62, 0.81),  // bright blue
            (0.68, 0.50, 0.66),  // bright magenta
            (0.20, 0.89, 0.89),  // bright cyan
            (0.93, 0.93, 0.93),  // bright white
        ]
        let table = bright ? brightTable : basic
        let i = max(0, min(7, idx))
        let (r, g, b) = table[i]
        return Color(red: r, green: g, blue: b)
    }

    /// Resolve an xterm-256 index. 0-15 reuse the 16-color palette;
    /// 16-231 form a 6×6×6 cube; 232-255 are a grayscale ramp.
    private static func xterm256(_ n: Int) -> Color {
        if n < 16 {
            return ansiBaseColor(n & 7, bright: n >= 8)
        }
        if n >= 232 {
            let level = Double(n - 232) * 10.0 / 255.0 + 8.0 / 255.0
            return Color(red: level, green: level, blue: level)
        }
        let idx = n - 16
        let r = idx / 36
        let g = (idx / 6) % 6
        let b = idx % 6
        let toLinear = { (v: Int) -> Double in
            // xterm cube: 0 → 0, then 95, 135, 175, 215, 255.
            v == 0 ? 0 : Double(95 + (v - 1) * 40) / 255.0
        }
        return Color(red: toLinear(r), green: toLinear(g), blue: toLinear(b))
    }
}
