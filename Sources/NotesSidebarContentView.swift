import SwiftUI
import AppKit

struct NotesSidebarContentView: View {
    @ObservedObject var workspace: Workspace
    @Binding var editingNoteId: UUID?
    @State private var draggedNoteId: UUID?
    @State private var dropTargetNoteId: UUID?
    @State private var splitRatio: CGFloat = 0.5
    @State private var isDraggingSplitter: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let notesHeight = max(80, totalHeight * splitRatio)
            let mrHeight = max(80, totalHeight - notesHeight)

            VStack(spacing: 0) {
                // Top: Notes
                notesSection
                    .frame(height: notesHeight)

                // Draggable divider
                splitDivider(totalHeight: totalHeight)

                // Bottom: Merge Requests
                MergeRequestsListView(workspace: workspace)
                    .id(workspace.id)
                    .frame(height: mrHeight)
            }
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
            .fill(isDraggingSplitter ? Color.accentColor : Color(nsColor: .separatorColor))
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
                        let newRatio = (splitRatio * totalHeight + value.translation.height) / totalHeight
                        splitRatio = min(0.85, max(0.15, newRatio))
                    }
                    .onEnded { _ in
                        isDraggingSplitter = false
                    }
            )
    }

    private var notesSidebarHeader: some View {
        HStack {
            Text(String(localized: "notes.sidebar.title", defaultValue: "Notes"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let note = WorkspaceNote()
                workspace.notes.insert(note, at: 0)
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
                            onCommit: { title, content in
                                if let idx = workspace.notes.firstIndex(where: { $0.id == note.id }) {
                                    workspace.notes[idx].title = title
                                    workspace.notes[idx].content = content
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
                        .onDrag {
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
    let onCommit: (_ title: String, _ content: String) -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                NoteEditingView(
                    initialTitle: note.title,
                    initialContent: note.content,
                    onCommit: onCommit,
                    onDismiss: onDismiss
                )
            } else {
                displayView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.background.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing { onTap() }
        }
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
            }
            if !note.content.isEmpty {
                Text(note.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if note.title.isEmpty {
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
    let initialTitle: String
    let initialContent: String
    let onCommit: (_ title: String, _ content: String) -> Void
    let onDismiss: () -> Void

    @State private var editTitle: String = ""
    @State private var editContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NativeTextFieldRepresentable(
                text: $editTitle,
                placeholder: String(localized: "notes.card.titlePlaceholder", defaultValue: "Title"),
                font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                onEscape: { commitAndDismiss() }
            )
            .frame(height: 20)

            NativeTextViewRepresentable(
                text: $editContent,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                focusOnAppear: true,
                onEscape: { commitAndDismiss() }
            )
            .frame(minHeight: 60, maxHeight: 300)

            HStack {
                Spacer()
                Button(String(localized: "notes.card.done", defaultValue: "Done")) {
                    commitAndDismiss()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .onAppear {
            editTitle = initialTitle
            editContent = initialContent
        }
    }

    private func commitAndDismiss() {
        onCommit(editTitle, editContent)
        onDismiss()
    }
}

// MARK: - Native AppKit Text Field (single-line title)

private struct NativeTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NoteTextField {
        let field = NoteTextField()
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.sendsActionOnEndEditing = false
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
            return false
        }
    }
}

// MARK: - Native AppKit Text View (multi-line content)

private struct NativeTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var focusOnAppear: Bool = false
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NoteTextView()

        textView.isRichText = false
        textView.font = font
        textView.textColor = .secondaryLabelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView

        if focusOnAppear {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            }
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if !context.coordinator.isEditing && textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextViewRepresentable
        var isEditing = false
        weak var textView: NSTextView?

        init(_ parent: NativeTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}

/// NSTextField subclass for notes title field. Conforms to NotesSidebarResponder
/// so the terminal's focus-recovery logic skips focus stealing.
final class NoteTextField: NSTextField, NotesSidebarResponder {}

/// NSTextView subclass that claims first responder and prevents the terminal
/// from stealing keyboard events via performKeyEquivalent.
/// Conforms to NotesSidebarResponder so the terminal's focus-recovery logic
/// can detect it and skip focus stealing.
final class NoteTextView: NSTextView, NotesSidebarResponder {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Let Cmd shortcuts pass through to the menu/app
        if flags.contains(.command) {
            return super.performKeyEquivalent(with: event)
        }
        // Consume all other key equivalents so the terminal doesn't grab them
        return true
    }
}
