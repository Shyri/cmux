import SwiftUI
import AppKit

// MARK: - Public API

struct DiffCodeTextView: NSViewRepresentable {
    let left: NSAttributedString
    let right: NSAttributedString
    let leftHunkOffsets: [Int]
    let rightHunkOffsets: [Int]
    let leftLineKinds: [SideBySideLineKind]
    let rightLineKinds: [SideBySideLineKind]
    let leftRowBackgrounds: [DiffRowBackground]
    let rightRowBackgrounds: [DiffRowBackground]
    let leftLineNumbers: [Int?]
    let rightLineNumbers: [Int?]
    let leftLineStarts: [Int]
    let rightLineStarts: [Int]
    let collapsedStubs: [DiffCollapsedStub]
    let inlineComments: [InlineCommentWidget]
    let onExpandBlock: (Int) -> Void
    @Binding var scrollHunkIndex: Int?

    func makeNSView(context: Context) -> DiffCodeContainer {
        let container = DiffCodeContainer()
        container.coordinator = context.coordinator
        container.configure()
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: DiffCodeContainer, context: Context) {
        container.apply(
            left: left,
            right: right,
            leftHunkOffsets: leftHunkOffsets,
            rightHunkOffsets: rightHunkOffsets,
            leftLineKinds: leftLineKinds,
            rightLineKinds: rightLineKinds,
            leftRowBackgrounds: leftRowBackgrounds,
            rightRowBackgrounds: rightRowBackgrounds,
            leftLineNumbers: leftLineNumbers,
            rightLineNumbers: rightLineNumbers,
            leftLineStarts: leftLineStarts,
            rightLineStarts: rightLineStarts,
            collapsedStubs: collapsedStubs,
            inlineComments: inlineComments,
            onExpandBlock: onExpandBlock
        )
        if let idx = scrollHunkIndex {
            container.scrollToHunk(at: idx)
            DispatchQueue.main.async { self.scrollHunkIndex = nil }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var container: DiffCodeContainer?
    }
}

// MARK: - Container NSView

final class DiffCodeContainer: NSView {
    weak var coordinator: DiffCodeTextView.Coordinator?

    private let leftScroll = SyncedScrollView()
    private let rightScroll = SyncedScrollView()
    /// Custom NSTextView that draws per-line background fills across the full
    /// view width, matching VS Code's diff block bands.
    private let leftText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let rightText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let splitter = DiffSplitterView()
    /// Single overview ruler on the far right of the whole diff (scrollbar +
    /// change minimap in one strip, matching VS Code).
    private let overviewRuler = DiffOverviewRuler()

    private var leftHunkOffsets: [Int] = []
    private var rightHunkOffsets: [Int] = []

    private let rulerWidth: CGFloat = 24

    func configure() {
        wantsLayer = true
        layer?.backgroundColor = DiffCodeContainer.editorBackground.cgColor

        for (scroll, text) in [(leftScroll, leftText), (rightScroll, rightText)] {
            configure(scrollView: scroll, textView: text)
            addSubview(scroll)
        }
        addSubview(splitter)
        addSubview(overviewRuler)

        // Forward scroll-wheel deltas bi-directionally so both sides move
        // together, each clamping to its own content width independently.
        leftScroll.partner = rightScroll
        rightScroll.partner = leftScroll

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(leftBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: leftScroll.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rightBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: rightScroll.contentView
        )

        overviewRuler.onClickFraction = { [weak self] fraction in
            // Scroll both sides: they are synced.
            self?.scrollToFraction(leftText: true, fraction: fraction)
            self?.scrollToFraction(leftText: false, fraction: fraction)
        }
        updateThumbs()
    }

    private func updateThumbs() {
        // Both scroll views are synced; use the left one as the source of truth.
        let metrics = thumbMetrics(for: leftScroll)
        overviewRuler.updateThumb(fraction: metrics.fraction, visibleFraction: metrics.visible)
    }

    private func thumbMetrics(for scrollView: NSScrollView) -> (fraction: CGFloat, visible: CGFloat) {
        guard let doc = scrollView.documentView else { return (0, 1) }
        let total = doc.frame.height
        let visible = scrollView.contentView.bounds.height
        if total <= visible { return (0, 1) }
        let frac = max(0, min(1, scrollView.contentView.bounds.origin.y / (total - visible)))
        return (frac, visible / total)
    }

    /// Fixed editor background to mirror VS Code's `#1E1E1E`.
    static let editorBackground: NSColor = NSColor(
        srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1
    )

    private static func makeCodeTextView() -> DiffTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        return DiffTextView(frame: .zero, textContainer: container)
    }

    private func configure(scrollView: NSScrollView, textView: NSTextView) {
        // Vertical scroller is hidden: the overview ruler on the right of each
        // side doubles as the scrollbar (shows a translucent viewport thumb),
        // matching VS Code's diff editor.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.editorBackground
        scrollView.contentView.postsBoundsChangedNotifications = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Self.editorBackground
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.allowsUndo = false
        textView.usesFindBar = true

        scrollView.documentView = textView

        // Native line number gutter: stays fixed when the content scrolls
        // horizontally, like VS Code.
        scrollView.hasVerticalRuler = true
        let ruler = DiffLineNumberRuler(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
    }

    // MARK: Content

    func apply(
        left: NSAttributedString,
        right: NSAttributedString,
        leftHunkOffsets: [Int],
        rightHunkOffsets: [Int],
        leftLineKinds: [SideBySideLineKind],
        rightLineKinds: [SideBySideLineKind],
        leftRowBackgrounds: [DiffRowBackground],
        rightRowBackgrounds: [DiffRowBackground],
        leftLineNumbers: [Int?],
        rightLineNumbers: [Int?],
        leftLineStarts: [Int],
        rightLineStarts: [Int],
        collapsedStubs: [DiffCollapsedStub],
        inlineComments: [InlineCommentWidget],
        onExpandBlock: @escaping (Int) -> Void
    ) {
        if leftText.textStorage?.isEqual(to: left) != true {
            leftText.textStorage?.setAttributedString(left)
        }
        if rightText.textStorage?.isEqual(to: right) != true {
            rightText.textStorage?.setAttributedString(right)
        }
        leftText.rowBackgrounds = leftRowBackgrounds.map { ($0.range, $0.color) }
        rightText.rowBackgrounds = rightRowBackgrounds.map { ($0.range, $0.color) }
        leftText.stubRanges = collapsedStubs.map { ($0.leftCharRange, $0.blockId) }
        rightText.stubRanges = collapsedStubs.map { ($0.rightCharRange, $0.blockId) }
        leftText.onStubClick = onExpandBlock
        rightText.onStubClick = onExpandBlock
        leftText.inlineWidgets = inlineComments.filter { $0.side == .left }
        rightText.inlineWidgets = inlineComments.filter { $0.side == .right }
        if let ruler = leftScroll.verticalRulerView as? DiffLineNumberRuler {
            ruler.update(lineNumbers: leftLineNumbers, lineStarts: leftLineStarts)
        }
        if let ruler = rightScroll.verticalRulerView as? DiffLineNumberRuler {
            ruler.update(lineNumbers: rightLineNumbers, lineStarts: rightLineStarts)
        }
        self.leftHunkOffsets = leftHunkOffsets
        self.rightHunkOffsets = rightHunkOffsets
        overviewRuler.update(
            leftKinds: leftLineKinds,
            rightKinds: rightLineKinds
        )
    }

    func scrollToHunk(at index: Int) {
        guard index >= 0, index < leftHunkOffsets.count, index < rightHunkOffsets.count else { return }
        let leftOffset = leftHunkOffsets[index]
        let rightOffset = rightHunkOffsets[index]
        ensureLayout(on: leftText)
        ensureLayout(on: rightText)
        scrollOffset(leftText, to: leftOffset)
        scrollOffset(rightText, to: rightOffset)
    }

    private func ensureLayout(on textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
    }

    private func scrollOffset(_ textView: NSTextView, to characterIndex: Int) {
        guard let lm = textView.layoutManager, textView.textContainer != nil else { return }
        let length = textView.string.utf16.count
        let clamped = max(0, min(characterIndex, length))
        // Compute the target line's rect in the text view's coordinates, then
        // position the scroll view so that line sits a bit below the top (so
        // users see some context before the first change).
        let glyphIndex = lm.glyphIndexForCharacter(at: clamped)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let insetY = textView.textContainerInset.height
        let targetY = max(0, lineRect.minY + insetY - 8)
        textView.scroll(NSPoint(x: 0, y: targetY))
    }

    private func scrollToFraction(leftText: Bool, fraction: CGFloat) {
        let scrollView = leftText ? leftScroll : rightScroll
        guard let doc = scrollView.documentView else { return }
        let totalHeight = doc.frame.height
        let viewHeight = scrollView.contentView.bounds.height
        let maxOffset = max(0, totalHeight - viewHeight)
        let targetY = max(0, min(maxOffset, fraction * totalHeight - viewHeight / 2))
        var origin = scrollView.contentView.bounds.origin
        origin.y = targetY
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Scroll sync

    @objc private func leftBoundsChanged(_ note: Notification) {
        updateThumbs()
        leftScroll.verticalRulerView?.needsDisplay = true
    }

    @objc private func rightBoundsChanged(_ note: Notification) {
        updateThumbs()
        rightScroll.verticalRulerView?.needsDisplay = true
    }

    override func layout() {
        let previousBounds = bounds
        super.layout()
        let splitterWidth: CGFloat = 2
        // Whole-panel layout: each side splits equally in the horizontal
        // space left after reserving rulerWidth on the far right.
        let usableWidth = max(1, bounds.width - rulerWidth)
        let halfWidth = max(1, (usableWidth - splitterWidth) / 2)
        leftScroll.frame = NSRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        splitter.frame = NSRect(x: halfWidth, y: 0, width: splitterWidth, height: bounds.height)
        let rightScrollWidth = max(1, usableWidth - halfWidth - splitterWidth)
        rightScroll.frame = NSRect(
            x: halfWidth + splitterWidth,
            y: 0,
            width: rightScrollWidth,
            height: bounds.height
        )
        overviewRuler.frame = NSRect(
            x: bounds.width - rulerWidth,
            y: 0,
            width: rulerWidth,
            height: bounds.height
        )
        if previousBounds.size != bounds.size {
            updateThumbs()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private final class DiffSplitterView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0x45/255, green: 0x45/255, blue: 0x45/255, alpha: 1).setFill()
        bounds.fill()
    }
}

// MARK: - SyncedScrollView

/// Forwards the scroll-wheel delta to a paired scroll view so both move
/// together. Unlike mirroring absolute positions, the paired view clamps to
/// its own content width independently — if one side's content is shorter,
/// it stops at its max while the partner continues scrolling through the
/// rest of its content.
final class SyncedScrollView: NSScrollView {
    weak var partner: SyncedScrollView?
    fileprivate var isSyncingFromPartner: Bool = false

    override func scrollWheel(with event: NSEvent) {
        // Let the native scroll view handle this event (including momentum,
        // rubber-band and proper clamping against `documentRect`). Then
        // re-dispatch the very same event to the partner so it performs
        // the exact same scroll through its own pipeline. A re-entry flag
        // prevents infinite recursion between the two partners.
        super.scrollWheel(with: event)
        guard !isSyncingFromPartner, let partner else { return }
        partner.isSyncingFromPartner = true
        partner.scrollWheel(with: event)
        partner.isSyncingFromPartner = false
    }
}

// MARK: - Overview Ruler

/// Vertical strip that mirrors the change distribution of one side, so users
/// can jump anywhere there's a marker and see at a glance where the diffs are.
final class DiffOverviewRuler: NSView {
    private var leftKinds: [SideBySideLineKind] = []
    private var rightKinds: [SideBySideLineKind] = []
    private var thumbFraction: CGFloat = 0
    private var thumbVisibleFraction: CGFloat = 1
    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?
    var onClickFraction: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    func update(leftKinds: [SideBySideLineKind], rightKinds: [SideBySideLineKind]) {
        self.leftKinds = leftKinds
        self.rightKinds = rightKinds
        needsDisplay = true
    }

    func updateThumb(fraction: CGFloat, visibleFraction: CGFloat) {
        if thumbFraction != fraction || thumbVisibleFraction != visibleFraction {
            thumbFraction = fraction
            thumbVisibleFraction = visibleFraction
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0x1E/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1).setFill()
        bounds.fill()

        let count = max(leftKinds.count, rightKinds.count)
        guard count > 0 else { return }
        let pixelsPerLine = bounds.height / CGFloat(count)
        let minBlockHeight: CGFloat = max(2, pixelsPerLine)
        let midX = bounds.width / 2

        // Left half: markers for the left side (deletions). Right half:
        // markers for the right side (additions). Hunk headers get a faint
        // full-width tint so they're still visible as "there's a change here".
        // Conflict markers get a strong magenta band on both halves so they're
        // unmissable in the overview.
        let conflictColor = NSColor(srgbRed: 220/255, green: 90/255, blue: 200/255, alpha: 0.95)
        drawMarkers(
            kinds: leftKinds,
            xRange: 1..<(midX - 0.5),
            pixelsPerLine: pixelsPerLine,
            minBlockHeight: minBlockHeight,
            addedColor: nil,
            deletedColor: NSColor(srgbRed: 255/255, green: 75/255, blue: 75/255, alpha: 0.9),
            hunkColor: nil,
            conflictColor: conflictColor
        )
        drawMarkers(
            kinds: rightKinds,
            xRange: (midX + 0.5)..<(bounds.width - 1),
            pixelsPerLine: pixelsPerLine,
            minBlockHeight: minBlockHeight,
            addedColor: NSColor(srgbRed: 155/255, green: 185/255, blue: 85/255, alpha: 0.9),
            deletedColor: nil,
            hunkColor: nil,
            conflictColor: conflictColor
        )
        // Viewport thumb, drawn last.
        if thumbVisibleFraction < 1 {
            let thumbHeight = max(24, bounds.height * thumbVisibleFraction)
            let availableRange = bounds.height - thumbHeight
            let y = availableRange * thumbFraction
            let thumbRect = NSRect(x: 0, y: y, width: bounds.width, height: thumbHeight)
            let alpha: CGFloat = isHovered ? 0.22 : 0.14
            NSColor(white: 1, alpha: alpha).setFill()
            thumbRect.fill()
        }
    }

    private func drawMarkers(
        kinds: [SideBySideLineKind],
        xRange: Range<CGFloat>,
        pixelsPerLine: CGFloat,
        minBlockHeight: CGFloat,
        addedColor: NSColor?,
        deletedColor: NSColor?,
        hunkColor: NSColor?,
        conflictColor: NSColor? = nil
    ) {
        guard !kinds.isEmpty else { return }
        let x = xRange.lowerBound
        let w = xRange.upperBound - xRange.lowerBound
        guard w > 0 else { return }
        var runStart = 0
        var runKind = kinds[0]
        for i in 1...kinds.count {
            let atEnd = i == kinds.count
            let current: SideBySideLineKind? = atEnd ? nil : kinds[i]
            if current != runKind {
                let color: NSColor?
                switch runKind {
                case .added: color = addedColor
                case .deleted: color = deletedColor
                case .hunk: color = hunkColor
                case .conflictOurs, .conflictBase, .conflictSeparator, .conflictTheirs:
                    color = conflictColor
                default: color = nil
                }
                if let color {
                    let y = CGFloat(runStart) * pixelsPerLine
                    let h = max(minBlockHeight, CGFloat(i - runStart) * pixelsPerLine)
                    let rect = NSRect(x: x, y: y, width: w, height: h)
                    color.setFill()
                    rect.fill()
                }
                runStart = i
                if let current { runKind = current }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, p.y / bounds.height))
        onClickFraction?(fraction)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, p.y / bounds.height))
        onClickFraction?(fraction)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

}

// MARK: - Line Number Ruler

/// Native-style line number gutter. Lives inside the `NSScrollView` so it
/// scrolls vertically with the content but stays fixed horizontally (so the
/// numbers remain on screen when the code is scrolled horizontally).
final class DiffLineNumberRuler: NSRulerView {
    private var lineNumbers: [Int?] = []
    /// UTF-16 character index at the start of each line. Parallel to
    /// `lineNumbers`. Used to map glyph char indices back to line indices.
    private var lineStarts: [Int] = []

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        self.clientView = scrollView?.documentView as? NSView
        self.ruleThickness = 52
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not implemented") }

    func update(lineNumbers: [Int?], lineStarts: [Int]) {
        self.lineNumbers = lineNumbers
        self.lineStarts = lineStarts
        if let maxNumber = lineNumbers.compactMap({ $0 }).max() {
            let digits = max(3, String(maxNumber).count)
            // Approx char width for Menlo 12pt ≈ 7.2 px. Add padding.
            self.ruleThickness = ceil(CGFloat(digits) * 7.2) + 16
        } else {
            self.ruleThickness = 40
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Fill background matching the editor so the gutter blends with
        // the code area.
        DiffCodeContainer.editorBackground.setFill()
        bounds.fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scroll = self.scrollView else { return }
        guard !lineNumbers.isEmpty, !lineStarts.isEmpty else { return }

        let insetY = textView.textContainerInset.height
        let clipBounds = scroll.contentView.bounds
        // Translate clipBounds into text view coordinates (they share the
        // same origin because the document view is the text view).
        let visibleRect = NSRect(
            origin: clipBounds.origin,
            size: clipBounds.size
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        guard glyphRange.length > 0 else { return }

        let firstCharIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        var lineIdx = lineIndexFor(charIndex: firstCharIndex)

        let numberFont = codeFont()
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ]

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, fragmentGlyphRange, _ in
            defer { lineIdx += 1 }
            guard lineIdx < self.lineNumbers.count,
                  let num = self.lineNumbers[lineIdx] else { return }
            let label = NSAttributedString(string: "\(num)", attributes: numberAttrs)
            let labelSize = label.size()
            let x = self.bounds.width - labelSize.width - 8
            // Convert text view y into ruler y.
            let yInClip = fragment.minY + insetY - clipBounds.origin.y
            let yCentered = yInClip + (fragment.height - labelSize.height) / 2
            label.draw(at: NSPoint(x: x, y: yCentered))
        }
    }

    /// Binary search for the greatest `lineStarts[i] <= charIndex`.
    private func lineIndexFor(charIndex: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        var answer = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= charIndex {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }
}

// MARK: - Diff Text View (full-width row backgrounds)

/// `NSTextView` subclass that paints per-line background bands spanning the
/// entire view width underneath the text, matching VS Code's diff block
/// bands. Intra-line (token-level) highlights keep using NSAttributedString
/// `.backgroundColor` attributes and are rendered above these bands by the
/// default text drawing pipeline.
final class DiffTextView: NSTextView {
    var rowBackgrounds: [(NSRange, NSColor)] = [] {
        didSet { needsDisplay = true }
    }
    /// Character ranges that are "collapse stubs" (clickable to expand the
    /// corresponding block of hidden unchanged lines). The Int is the block id.
    var stubRanges: [(NSRange, Int)] = []
    var onStubClick: ((Int) -> Void)?
    /// Inline MR discussion cards overlaid on placeholder rows in this side.
    var inlineWidgets: [InlineCommentWidget] = [] {
        didSet { rebuildInlineHosts() }
    }
    private var inlineHosts: [String: NSHostingView<InlineCommentCard>] = [:]

    private func rebuildInlineHosts() {
        let wanted = Set(inlineWidgets.map(\.id))
        // Remove hosts that no longer apply.
        for (id, host) in inlineHosts where !wanted.contains(id) {
            host.removeFromSuperview()
            inlineHosts.removeValue(forKey: id)
        }
        // Ensure a host exists for every widget.
        for widget in inlineWidgets {
            let cap: CGFloat? = widget.useInternalScroll ? widget.reservedHeight : nil
            let card = InlineCommentCard(discussion: widget.discussion, maxHeight: cap)
            if inlineHosts[widget.id] == nil {
                let host = NSHostingView(rootView: card)
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                inlineHosts[widget.id] = host
            } else if let host = inlineHosts[widget.id] {
                host.rootView = card
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        positionInlineHosts()
    }

    private func positionInlineHosts() {
        guard !inlineWidgets.isEmpty,
              let lm = layoutManager,
              let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let insetY = textContainerInset.height
        for widget in inlineWidgets {
            guard let host = inlineHosts[widget.id] else { continue }
            let textLength = textStorage?.length ?? 0
            let clamped = max(0, min(widget.anchorCharIndex, textLength))
            let glyph = lm.glyphIndexForCharacter(at: clamped)
            let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            host.frame = NSRect(
                x: 0,
                y: rect.minY + insetY,
                width: bounds.width,
                height: widget.reservedHeight
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Check if the click lands on a stub row and, if so, fire the
        // expansion callback instead of forwarding to the default selection.
        if let lm = layoutManager, let tc = textContainer {
            let localInset = NSPoint(
                x: textContainerInset.width,
                y: textContainerInset.height
            )
            var point = convert(event.locationInWindow, from: nil)
            point.x -= localInset.x
            point.y -= localInset.y
            if lm.numberOfGlyphs > 0 {
                let glyph = lm.glyphIndex(for: point, in: tc)
                let charIndex = lm.characterIndexForGlyph(at: glyph)
                for (range, blockId) in stubRanges where NSLocationInRange(charIndex, range) {
                    onStubClick?(blockId)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = self.layoutManager else { return }
        let insetY = self.textContainerInset.height
        for (charRange, color) in rowBackgrounds {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: charRange,
                actualCharacterRange: nil
            )
            if glyphRange.length == 0 { continue }
            color.setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
                let drawRect = NSRect(
                    x: 0,
                    y: fragment.minY + insetY,
                    width: self.bounds.width,
                    height: fragment.height
                )
                if drawRect.intersects(rect) {
                    drawRect.fill()
                }
            }
        }
    }
}
