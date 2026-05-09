import SwiftUI
import AppKit

struct NotesSidebarContentView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var notesStore = WorkspaceNotesStore.shared
    @Binding var editingNoteId: UUID?
    @State private var draggedNoteId: UUID?
    @State private var dropTargetNoteId: UUID?
    @AppStorage("notesSidebarSplitRatio") private var splitRatio: Double = 0.5
    @State private var isDraggingSplitter: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let notesHeight = max(80, totalHeight * CGFloat(splitRatio))
            let mrHeight = max(80, totalHeight - notesHeight)

            VStack(spacing: 0) {
                // Top: Notes
                notesSection
                    .frame(height: notesHeight)

                // Draggable divider
                splitDivider(totalHeight: totalHeight)

                // Bottom: GitLab (MRs + Pipelines)
                GitLabSidebarView(workspace: workspace)
                    .id(workspace.id)
                    .frame(height: mrHeight)
            }
            .background(Color.darculaSidebarBackground)
            .preferredColorScheme(.dark)
        }
    }

    private var notesSection: some View {
        VStack(spacing: 0) {
            notesSidebarHeader
            Divider()
            if workspace.notes.isEmpty {
                notesEmptyState
            } else {
                notesList
            }
        }
    }

    private func splitDivider(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(isDraggingSplitter ? Color.darculaAccent : Color.darculaBorder)
            .frame(height: isDraggingSplitter ? 2 : 1)
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
                        isDraggingSplitter = true
                        let newRatio = (CGFloat(splitRatio) * totalHeight + value.translation.height) / totalHeight
                        splitRatio = Double(min(0.85, max(0.15, newRatio)))
                    }
                    .onEnded { _ in
                        isDraggingSplitter = false
                    }
            )
    }

    private var notesSidebarHeader: some View {
        HStack(spacing: 8) {
            Text(String(localized: "notes.sidebar.title", defaultValue: "Notes"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            if workspace.notes.contains(where: { $0.isCompleted }) {
                Button {
                    deleteCompletedNotes()
                } label: {
                    Image(systemName: "checkmark.circle.badge.xmark")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "notes.sidebar.deleteCompleted", defaultValue: "Delete completed notes"))
            }
            Button {
                let note = WorkspaceNote()
                workspace.notes.append(note)
                editingNoteId = note.id
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func deleteCompletedNotes() {
        let removedIds = Set(workspace.notes.filter { $0.isCompleted }.map { $0.id })
        guard !removedIds.isEmpty else { return }
        if let editing = editingNoteId, removedIds.contains(editing) {
            editingNoteId = nil
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            workspace.notes.removeAll { removedIds.contains($0.id) }
        }
    }

    private var notesEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "note.text")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(String(localized: "notes.sidebar.empty", defaultValue: "No notes yet"))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workspace.notes) { note in
                    VStack(spacing: 0) {
                        // Insertion indicator above this card
                        if dropTargetNoteId == note.id && draggedNoteId != note.id {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                                .transition(.opacity)
                        }

                        NoteCardView(
                            note: note,
                            isEditing: editingNoteId == note.id,
                            onTap: {
                                editingNoteId = note.id
                            },
                            onCommit: { title in
                                if let idx = workspace.notes.firstIndex(where: { $0.id == note.id }) {
                                    workspace.notes[idx].title = title
                                }
                            },
                            onToggleCompleted: {
                                if let idx = workspace.notes.firstIndex(where: { $0.id == note.id }) {
                                    workspace.notes[idx].isCompleted.toggle()
                                }
                            },
                            onDelete: {
                                workspace.notes.removeAll { $0.id == note.id }
                                if editingNoteId == note.id {
                                    editingNoteId = nil
                                }
                            },
                            onDismiss: {
                                editingNoteId = nil
                            }
                        )
                        .opacity(draggedNoteId == note.id ? 0.4 : 1.0)
                        .conditionalNoteDrag(enabled: editingNoteId != note.id) {
                            draggedNoteId = note.id
                            return NSItemProvider(object: note.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: NoteReorderDropDelegate(
                            targetNoteId: note.id,
                            workspace: workspace,
                            draggedNoteId: $draggedNoteId,
                            dropTargetNoteId: $dropTargetNoteId
                        ))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            // Cleanup if dropped outside any note card
            draggedNoteId = nil
            dropTargetNoteId = nil
            return false
        }
    }
}

// MARK: - Reorder Drop Delegate

private struct NoteReorderDropDelegate: DropDelegate {
    let targetNoteId: UUID
    let workspace: Workspace
    @Binding var draggedNoteId: UUID?
    @Binding var dropTargetNoteId: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedId = draggedNoteId, draggedId != targetNoteId else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetNoteId = targetNoteId
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetNoteId == targetNoteId {
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetNoteId = nil
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Try state-tracked ID first, fall back to reading from the provider
        if let draggedId = draggedNoteId {
            let result = moveNote(draggedId: draggedId)
            cleanup()
            return result
        }

        // Fallback: read from NSItemProvider (async, but still apply)
        guard let provider = info.itemProviders(for: [.text]).first else {
            cleanup()
            return false
        }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let idString = reading as? String,
                  let draggedId = UUID(uuidString: idString) else { return }
            DispatchQueue.main.async {
                _ = self.moveNote(draggedId: draggedId)
                self.cleanup()
            }
        }
        return true
    }

    private func moveNote(draggedId: UUID) -> Bool {
        guard let fromIndex = workspace.notes.firstIndex(where: { $0.id == draggedId }),
              let toIndex = workspace.notes.firstIndex(where: { $0.id == targetNoteId }),
              fromIndex != toIndex else {
            return false
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            workspace.notes.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        return true
    }

    private func cleanup() {
        draggedNoteId = nil
        dropTargetNoteId = nil
    }
}

// MARK: - Note Card

private struct NoteCardView: View {
    let note: WorkspaceNote
    let isEditing: Bool
    let onTap: () -> Void
    let onCommit: (_ title: String) -> Void
    let onToggleCompleted: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleCompleted) {
                Image(systemName: note.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(note.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    NoteEditingView(
                        initialTitle: note.title,
                        onCommit: onCommit,
                        onDismiss: onDismiss
                    )
                } else {
                    displayView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.darculaCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
        )
        // While editing, do NOT install SwiftUI's tap/contentShape gestures —
        // they intercept mouseDown before the embedded NSTextView can take
        // focus, which breaks both text selection and the cursor's normal
        // input handling.
        .conditionalNoteTap(enabled: !isEditing, action: onTap)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(String(localized: "notes.card.delete", defaultValue: "Delete"), systemImage: "trash")
            }
        }
    }

    private var displayView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !note.title.isEmpty {
                Text(note.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(note.isCompleted, color: .secondary)
                    .foregroundStyle(note.isCompleted ? Color.secondary : Color.primary)
            } else {
                Text(String(localized: "notes.card.empty", defaultValue: "Empty note"))
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Note Editing (isolated state, no workspace mutation during typing)

private struct NoteEditingView: View {
    let onCommit: (_ title: String) -> Void
    let onDismiss: () -> Void

    @State private var editTitle: String

    init(
        initialTitle: String,
        onCommit: @escaping (_ title: String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._editTitle = State(initialValue: initialTitle)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            NativeTextFieldRepresentable(
                text: $editTitle,
                placeholder: String(localized: "notes.card.titlePlaceholder", defaultValue: "Title"),
                font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                focusOnAppear: true,
                multiline: true,
                onEscape: { commitAndDismiss() },
                onSubmit: { commitAndDismiss() }
            )

            Button(String(localized: "notes.card.done", defaultValue: "Done")) {
                commitAndDismiss()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    private func commitAndDismiss() {
        onCommit(editTitle)
        onDismiss()
    }
}

// MARK: - Native AppKit Text Field (single- or multi-line title)

private struct NativeTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var focusOnAppear: Bool = false
    var multiline: Bool = false
    var onEscape: () -> Void
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NoteTextField {
        let field = NoteTextField()
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.cell?.sendsActionOnEndEditing = false
        if multiline {
            field.cell?.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            // Make sure the field grows vertically with content under SwiftUI.
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        } else {
            field.lineBreakMode = .byTruncatingTail
        }
        if focusOnAppear {
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
                // Default behavior selects the whole string when becoming
                // first responder; collapse the selection to a caret at the
                // end of the text instead.
                if let editor = field.currentEditor() {
                    let end = (field.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            }
        }
        return field
    }

    func updateNSView(_ nsView: NoteTextField, context: Context) {
        if !context.coordinator.isEditing {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextFieldRepresentable
        var isEditing = false

        init(_ parent: NativeTextFieldRepresentable) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Shift+Enter inserts a real newline; plain Enter commits.
                if let event = NSApp.currentEvent,
                   event.modifierFlags.contains(.shift),
                   parent.multiline {
                    textView.insertNewlineIgnoringFieldEditor(self)
                    return true
                }
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// NSTextField subclass for notes title field. Conforms to NotesSidebarResponder
/// so the terminal's focus-recovery logic skips focus stealing.
final class NoteTextField: NSTextField, NotesSidebarResponder {}

// MARK: - Native AppKit Text View (multiline note body, Enter commits, Shift+Enter inserts newline)

private struct NativeTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var focusOnAppear: Bool = false
    var onEscape: () -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NoteScrollContainer {
        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        // Force dark appearance so default system colors resolve correctly
        // against the dark card. Without this, `.textColor` /
        // `.placeholderTextColor` can resolve to dark values when this
        // NSTextView is hosted in SwiftUI and become invisible.
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = font
        // Use rich-text mode so per-character attributes drive rendering;
        // we explicitly set `.foregroundColor: .white` on the storage and on
        // typingAttributes so glyphs always render white regardless of the
        // textColor property's resolution.
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.allowsImageEditing = false
        textView.importsGraphics = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textColor = .white
        textView.insertionPointColor = .white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        textView.typingAttributes = attrs
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: attrs)
        )
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.placeholderString = placeholder

        let container = NoteScrollContainer()
        container.appearance = NSAppearance(named: .darkAqua)
        container.documentView = textView
        container.hasVerticalScroller = false
        container.hasHorizontalScroller = false
        container.drawsBackground = false
        container.borderType = .noBorder
        container.textView = textView

        if focusOnAppear {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.selectedRange = NSRange(location: (textView.string as NSString).length, length: 0)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NoteScrollContainer, context: Context) {
        guard let textView = nsView.textView else { return }
        if !context.coordinator.isEditing, textView.string != text {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: text, attributes: attrs)
            )
            textView.typingAttributes = attrs
            textView.refreshPlaceholder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextViewRepresentable
        var isEditing = false

        init(_ parent: NativeTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            (textView as? NoteTextView)?.refreshPlaceholder()
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }
    }
}

/// Scroll view container so SwiftUI can size the text view; we keep scrollers off
/// because the card grows with content.
fileprivate final class NoteScrollContainer: NSScrollView {
    weak var textView: NoteTextView?

    override var intrinsicContentSize: NSSize {
        guard let tv = textView else { return super.intrinsicContentSize }
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!) ?? .zero
        let height = max(20, ceil(used.height))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}

/// NSTextView subclass for the notes body. Plain Enter commits the edit;
/// Shift+Enter inserts a newline. Escape cancels. Conforms to
/// NotesSidebarResponder so terminal focus-recovery doesn't steal focus.
fileprivate final class NoteTextView: NSTextView, NotesSidebarResponder {
    weak var coordinator: NativeTextViewRepresentable.Coordinator?
    var placeholderString: String = "" {
        didSet { refreshPlaceholder() }
    }
    private var placeholderLabel: NSTextField?

    override func keyDown(with event: NSEvent) {
        // Enter without Shift commits; Shift+Enter falls through to insert newline.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift) {
            coordinator?.parent.onSubmit()
            return
        }
        super.keyDown(with: event)
        invalidateIntrinsicContentSize()
        enclosingScrollView?.invalidateIntrinsicContentSize()
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.parent.onEscape()
    }

    override func didChangeText() {
        super.didChangeText()
        // Re-pin foreground color across the whole storage on every edit so
        // newly inserted glyphs render in white. NSTextView can otherwise
        // pick up a stale typing attribute set during input-method or
        // composition phases.
        if let storage = textStorage, storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.white, range: fullRange)
            if let f = font {
                storage.addAttribute(.font, value: f, range: fullRange)
            }
            storage.endEditing()
        }
        var attrs = typingAttributes
        attrs[.foregroundColor] = NSColor.white
        if let f = font {
            attrs[.font] = f
        }
        typingAttributes = attrs
        invalidateIntrinsicContentSize()
        enclosingScrollView?.invalidateIntrinsicContentSize()
        refreshPlaceholder()
    }

    func refreshPlaceholder() {
        if string.isEmpty, !placeholderString.isEmpty {
            if placeholderLabel == nil {
                let label = NSTextField(labelWithString: placeholderString)
                label.font = font
                label.textColor = .placeholderTextColor
                label.translatesAutoresizingMaskIntoConstraints = false
                label.isEditable = false
                label.isSelectable = false
                label.drawsBackground = false
                label.isBordered = false
                addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
                    label.topAnchor.constraint(equalTo: topAnchor, constant: 0)
                ])
                placeholderLabel = label
            } else {
                placeholderLabel?.stringValue = placeholderString
                placeholderLabel?.isHidden = false
            }
        } else {
            placeholderLabel?.isHidden = true
        }
    }
}

// MARK: - Conditional gesture modifiers

private extension View {
    /// Applies `.onDrag` only when `enabled` is true. While a note is being
    /// edited we must NOT attach `.onDrag`, otherwise SwiftUI's drag detector
    /// hijacks mouse-drag events and the embedded NSTextView can't be used to
    /// select text — instead the whole card starts a reorder drag.
    @ViewBuilder
    func conditionalNoteDrag(
        enabled: Bool,
        provider: @escaping () -> NSItemProvider
    ) -> some View {
        if enabled {
            self.onDrag(provider)
        } else {
            self
        }
    }

    /// Applies `.contentShape(Rectangle()) + .onTapGesture` only when
    /// `enabled` is true. Same rationale as `conditionalNoteDrag`: the
    /// SwiftUI tap gesture would otherwise swallow mouseDown events meant
    /// for the embedded NSTextView while editing.
    @ViewBuilder
    func conditionalNoteTap(
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if enabled {
            self
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        } else {
            self
        }
    }
}

// MARK: - Darcula (IntelliJ) palette for the workspace sidebar

extension Color {
    /// Main IntelliJ Darcula tool-window background.
    static let darculaSidebarBackground = Color(nsColor: NSColor(
        srgbRed: 0x2B/255, green: 0x2B/255, blue: 0x2B/255, alpha: 1
    ))
    /// IntelliJ Darcula panel/card surface — sits on top of the sidebar bg.
    static let darculaCardBackground = Color(nsColor: NSColor(
        srgbRed: 0x3C/255, green: 0x3F/255, blue: 0x41/255, alpha: 1
    ))
    /// Slightly lighter card surface used on hover.
    static let darculaCardHover = Color(nsColor: NSColor(
        srgbRed: 0x4C/255, green: 0x50/255, blue: 0x52/255, alpha: 1
    ))
    /// Subtle separator/border tone consistent with Darcula.
    static let darculaBorder = Color(nsColor: NSColor(
        srgbRed: 0x32/255, green: 0x32/255, blue: 0x32/255, alpha: 1
    ))
    /// IntelliJ blue accent (selection / focus ring tone).
    static let darculaAccent = Color(nsColor: NSColor(
        srgbRed: 0x4B/255, green: 0x6E/255, blue: 0xAF/255, alpha: 1
    ))
    /// Soft Darcula foreground (`#A9B7C6`) for secondary chrome.
    static let darculaForeground = Color(nsColor: NSColor(
        srgbRed: 0xA9/255, green: 0xB7/255, blue: 0xC6/255, alpha: 1
    ))
}
