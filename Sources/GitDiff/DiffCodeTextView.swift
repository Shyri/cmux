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
    let connectorSegments: [DiffConnectorSegment]
    let leftRowToRightRow: [Int]
    let rightRowToLeftRow: [Int]
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
            connectorSegments: connectorSegments,
            leftRowToRightRow: leftRowToRightRow,
            rightRowToLeftRow: rightRowToLeftRow,
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

    private let leftScroll = DiffCodeScrollView()
    private let rightScroll = DiffCodeScrollView()
    /// Custom NSTextView that draws per-line background fills across the full
    /// view width, matching VS Code's diff block bands.
    private let leftText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let rightText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let connector: DiffConnectorView = DiffConnectorView()
    /// Single overview ruler on the far right of the whole diff (scrollbar +
    /// change minimap in one strip, matching VS Code).
    private let overviewRuler = DiffOverviewRuler()

    private var leftHunkOffsets: [Int] = []
    private var rightHunkOffsets: [Int] = []
    /// Side-specific line-start char indices, used by the row-mapped scroll
    /// sync to translate a viewport position on one side to the corresponding
    /// row index on the other side via `leftRowToRightRow`.
    private var leftLineStarts: [Int] = []
    private var rightLineStarts: [Int] = []
    private var leftRowToRightRow: [Int] = []
    private var rightRowToLeftRow: [Int] = []
    private var isSyncingScroll = false

    private let rulerWidth: CGFloat = 24

    func configure() {
        wantsLayer = true
        layer?.backgroundColor = DiffCodeContainer.editorBackground.cgColor

        for (scroll, text) in [(leftScroll, leftText), (rightScroll, rightText)] {
            DiffCodeContainer.configureCodePane(scrollView: scroll, textView: text)
            addSubview(scroll)
        }
        connector.bind(leftText: leftText, rightText: rightText)
        addSubview(connector)
        addSubview(overviewRuler)

        // Horizontal scroll wheel deltas still need bidirectional forwarding
        // (so the user can scroll long lines on either side without them
        // diverging). Vertical sync is handled separately by the row-mapped
        // pipeline below — pixel forwarding doesn't work when each side has
        // a different total height (the IntelliJ-style asymmetric layout).
        leftScroll.horizontalPartner = rightScroll
        rightScroll.horizontalPartner = leftScroll

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectorPrefsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
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

    static func makeCodeTextView() -> DiffTextView {
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

    static func configureCodePane(scrollView: NSScrollView, textView: NSTextView) {
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
        connectorSegments: [DiffConnectorSegment],
        leftRowToRightRow: [Int],
        rightRowToLeftRow: [Int],
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
        self.leftLineStarts = leftLineStarts
        self.rightLineStarts = rightLineStarts
        self.leftRowToRightRow = leftRowToRightRow
        self.rightRowToLeftRow = rightRowToLeftRow
        overviewRuler.update(
            leftKinds: leftLineKinds,
            rightKinds: rightLineKinds
        )
        connector.update(
            segments: connectorSegments,
            leftLineStarts: leftLineStarts,
            rightLineStarts: rightLineStarts
        )
        needsLayout = true
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
        if !isSyncingScroll {
            syncScroll(driver: .left)
        }
        updateThumbs()
        leftScroll.verticalRulerView?.needsDisplay = true
        connector.needsDisplay = true
    }

    @objc private func rightBoundsChanged(_ note: Notification) {
        if !isSyncingScroll {
            syncScroll(driver: .right)
        }
        updateThumbs()
        rightScroll.verticalRulerView?.needsDisplay = true
        connector.needsDisplay = true
    }

    private enum ScrollSide { case left, right }

    private func syncScroll(driver: ScrollSide) {
        guard !leftRowToRightRow.isEmpty, !rightRowToLeftRow.isEmpty else { return }
        let driverScroll: NSScrollView = driver == .left ? leftScroll : rightScroll
        let followerScroll: NSScrollView = driver == .left ? rightScroll : leftScroll
        let driverText: NSTextView = driver == .left ? leftText : rightText
        let followerText: NSTextView = driver == .left ? rightText : leftText
        let driverStarts: [Int] = driver == .left ? leftLineStarts : rightLineStarts
        let followerStarts: [Int] = driver == .left ? rightLineStarts : leftLineStarts
        let map: [Int] = driver == .left ? leftRowToRightRow : rightRowToLeftRow

        guard !driverStarts.isEmpty, !followerStarts.isEmpty,
              let dlm = driverText.layoutManager, let dtc = driverText.textContainer,
              let flm = followerText.layoutManager else { return }
        let driverInsetY = driverText.textContainerInset.height
        let followerInsetY = followerText.textContainerInset.height

        let driverClipY = driverScroll.contentView.bounds.origin.y
        // Translate to text-view coordinates (clipView and document share origin).
        let probeY = max(0, driverClipY - driverInsetY)
        let probePoint = NSPoint(x: 0, y: probeY)
        let glyphIndex = dlm.glyphIndex(for: probePoint, in: dtc)
        let charIndex = dlm.characterIndexForGlyph(at: glyphIndex)

        // Binary search the line index from the line-starts array.
        var lo = 0
        var hi = driverStarts.count - 1
        var driverRow = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if driverStarts[mid] <= charIndex {
                driverRow = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        // Look up the corresponding follower row and compute its top Y in
        // follower text-view coordinates.
        guard driverRow < map.count else { return }
        let mapped = map[driverRow]
        let followerRow = max(0, min(mapped, followerStarts.count - 1))
        let followerCharIndex = followerStarts[followerRow]
        let followerLength = followerText.textStorage?.length ?? 0
        let clamped = max(0, min(followerCharIndex, max(0, followerLength - 1)))
        guard flm.numberOfGlyphs > 0 else { return }
        let followerGlyph = flm.glyphIndexForCharacter(at: clamped)
        let followerRect = flm.lineFragmentRect(forGlyphAt: followerGlyph, effectiveRange: nil)
        let followerTextY = followerRect.minY + followerInsetY

        // Preserve the within-row pixel offset so partial-row scrolling on the
        // driver side carries over to the follower (smooth feel; without this,
        // the follower's viewport would snap on every row boundary).
        let driverRect = dlm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let driverTextY = driverRect.minY + driverInsetY
        let intraRowOffset = driverClipY - driverTextY

        let followerHeight = (followerScroll.documentView?.frame.height ?? 0)
        let followerVisible = followerScroll.contentView.bounds.height
        let maxFollowerY = max(0, followerHeight - followerVisible)
        let targetY = max(0, min(maxFollowerY, followerTextY + intraRowOffset))

        let currentX = followerScroll.contentView.bounds.origin.x
        if abs(followerScroll.contentView.bounds.origin.y - targetY) < 0.5 { return }
        isSyncingScroll = true
        followerScroll.contentView.scroll(to: NSPoint(x: currentX, y: targetY))
        followerScroll.reflectScrolledClipView(followerScroll.contentView)
        isSyncingScroll = false
    }

    @objc private func connectorPrefsChanged(_ note: Notification) {
        // Pick up `diff.connector.enabled` / `diff.connector.width` flips
        // without requiring a window reload.
        DispatchQueue.main.async { [weak self] in
            self?.needsLayout = true
            self?.connector.needsDisplay = true
        }
    }

    override func layout() {
        let previousBounds = bounds
        super.layout()
        let connectorEnabled = UserDefaults.standard.object(forKey: "diff.connector.enabled") as? Bool ?? true
        let configuredWidthRaw = UserDefaults.standard.object(forKey: "diff.connector.width") as? Double
        let configuredWidth = CGFloat(configuredWidthRaw ?? 36)
        let connectorWidth: CGFloat = connectorEnabled
            ? max(8, min(120, configuredWidth))
            : 2
        connector.isHidden = false
        connector.connectorEnabled = connectorEnabled
        // Whole-panel layout: each side splits equally in the horizontal
        // space left after reserving rulerWidth on the far right.
        let usableWidth = max(1, bounds.width - rulerWidth)
        let halfWidth = max(1, (usableWidth - connectorWidth) / 2)
        leftScroll.frame = NSRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        connector.frame = NSRect(x: halfWidth, y: 0, width: connectorWidth, height: bounds.height)
        let rightScrollWidth = max(1, usableWidth - halfWidth - connectorWidth)
        rightScroll.frame = NSRect(
            x: halfWidth + connectorWidth,
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
        connector.needsDisplay = true
        if previousBounds.size != bounds.size {
            updateThumbs()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Diff Connector (IntelliJ-style ribbons)

/// Draws curved ribbons in the gutter between the left and right diff panes,
/// linking each hunk on the left with its destination on the right. Visually
/// echoes the IntelliJ side-by-side diff: filled bezier shapes coloured per
/// kind (added / deleted / changed / moved), with pure insertions / deletions
/// collapsing one endpoint to a point so the shape becomes a funnel.
final class DiffConnectorView: NSView {
    private weak var leftText: DiffTextView?
    private weak var rightText: DiffTextView?
    private var segments: [DiffConnectorSegment] = []
    private var leftLineStarts: [Int] = []
    private var rightLineStarts: [Int] = []
    /// When false the view shrinks to a 2pt divider strip and skips ribbon
    /// drawing — used by the Debug toggle to fall back to the classic look.
    var connectorEnabled: Bool = true {
        didSet { if connectorEnabled != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    func bind(leftText: DiffTextView, rightText: DiffTextView) {
        self.leftText = leftText
        self.rightText = rightText
    }

    func update(
        segments: [DiffConnectorSegment],
        leftLineStarts: [Int],
        rightLineStarts: [Int]
    ) {
        self.segments = segments
        self.leftLineStarts = leftLineStarts
        self.rightLineStarts = rightLineStarts
        needsDisplay = true
    }

    private static let dividerColor = NSColor(
        srgbRed: 0x45/255, green: 0x45/255, blue: 0x45/255, alpha: 1
    )

    private struct RibbonStyle {
        let fill: NSColor
        let stroke: NSColor
        let dashed: Bool
    }

    private static let addedStyle = RibbonStyle(
        fill: NSColor(srgbRed: 0x6E/255, green: 0x9F/255, blue: 0x36/255, alpha: 0.22),
        stroke: NSColor(srgbRed: 0x6E/255, green: 0x9F/255, blue: 0x36/255, alpha: 0.65),
        dashed: false
    )
    private static let deletedStyle = RibbonStyle(
        fill: NSColor(srgbRed: 0xC4/255, green: 0x35/255, blue: 0x35/255, alpha: 0.22),
        stroke: NSColor(srgbRed: 0xC4/255, green: 0x35/255, blue: 0x35/255, alpha: 0.65),
        dashed: false
    )
    private static let changedStyle = RibbonStyle(
        fill: NSColor(srgbRed: 0xD0/255, green: 0xA8/255, blue: 0x35/255, alpha: 0.22),
        stroke: NSColor(srgbRed: 0xD0/255, green: 0xA8/255, blue: 0x35/255, alpha: 0.65),
        dashed: false
    )
    private static let movedStyle = RibbonStyle(
        fill: NSColor(srgbRed: 0x4D/255, green: 0x9D/255, blue: 0xE0/255, alpha: 0.18),
        stroke: NSColor(srgbRed: 0x4D/255, green: 0x9D/255, blue: 0xE0/255, alpha: 0.85),
        dashed: true
    )

    private static func style(for kind: DiffConnectorSegment.Kind) -> RibbonStyle {
        switch kind {
        case .added: return addedStyle
        case .deleted: return deletedStyle
        case .changed: return changedStyle
        case .moved: return movedStyle
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let backgroundColor = DiffCodeContainer.editorBackground
        backgroundColor.setFill()
        bounds.fill()

        // Vertical divider preserved on each edge so the gutter still reads
        // as a separator even when no segments cross it.
        Self.dividerColor.setStroke()
        let leftEdge = NSBezierPath()
        leftEdge.move(to: NSPoint(x: 0.5, y: 0))
        leftEdge.line(to: NSPoint(x: 0.5, y: bounds.height))
        leftEdge.lineWidth = 1
        leftEdge.stroke()
        let rightEdge = NSBezierPath()
        rightEdge.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        rightEdge.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        rightEdge.lineWidth = 1
        rightEdge.stroke()

        guard connectorEnabled else { return }
        guard !segments.isEmpty,
              let leftText = leftText,
              let rightText = rightText else { return }
        guard bounds.width >= 8 else { return }

        // Sort moved segments to the back so ordinary adds/deletes/changes
        // render first; moved ribbons (dashed) overlay them.
        let ordered = segments.sorted { lhs, rhs in
            if (lhs.kind == .moved) != (rhs.kind == .moved) {
                return lhs.kind != .moved
            }
            return lhs.leftAnchorRow + lhs.rightAnchorRow
                < rhs.leftAnchorRow + rhs.rightAnchorRow
        }

        for segment in ordered {
            guard let leftRange = self.yRange(
                in: leftText,
                lineRange: segment.leftLineRange,
                anchorRow: segment.leftAnchorRow,
                lineStarts: leftLineStarts
            ) else { continue }
            guard let rightRange = self.yRange(
                in: rightText,
                lineRange: segment.rightLineRange,
                anchorRow: segment.rightAnchorRow,
                lineStarts: rightLineStarts
            ) else { continue }

            // Cull ribbons fully above or below the visible gutter.
            let minY = min(leftRange.top, rightRange.top)
            let maxY = max(leftRange.bottom, rightRange.bottom)
            if maxY < dirtyRect.minY - 4 { continue }
            if minY > dirtyRect.maxY + 4 { continue }

            drawRibbon(
                leftTopY: leftRange.top,
                leftBottomY: leftRange.bottom,
                rightTopY: rightRange.top,
                rightBottomY: rightRange.bottom,
                style: Self.style(for: segment.kind)
            )
        }
    }

    private struct YRange { let top: CGFloat; let bottom: CGFloat }

    private func yRange(
        in textView: DiffTextView,
        lineRange: Range<Int>,
        anchorRow: Int,
        lineStarts: [Int]
    ) -> YRange? {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer else { return nil }
        guard !lineStarts.isEmpty else { return nil }
        lm.ensureLayout(for: tc)
        let inset = textView.textContainerInset.height
        let textLength = textView.textStorage?.length ?? 0
        guard textLength > 0, lm.numberOfGlyphs > 0 else { return nil }

        func glyphRectForRow(_ row: Int) -> NSRect {
            let r = max(0, min(row, lineStarts.count - 1))
            let charIndex = lineStarts[r]
            let clamped = max(0, min(charIndex, textLength - 1))
            let glyph = lm.glyphIndexForCharacter(at: clamped)
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }

        if lineRange.isEmpty {
            // Funnel apex on this side. If the gap is past the last row, pin
            // to the bottom of the file instead of the top of a missing row.
            let pinY: CGFloat
            if anchorRow >= lineStarts.count {
                let last = glyphRectForRow(lineStarts.count - 1)
                pinY = last.maxY + inset
            } else {
                let rect = glyphRectForRow(anchorRow)
                pinY = rect.minY + inset
            }
            let local = textView.convert(NSPoint(x: 0, y: pinY), to: self).y
            return YRange(top: local, bottom: local)
        }

        let topRect = glyphRectForRow(lineRange.lowerBound)
        let bottomRect = glyphRectForRow(lineRange.upperBound - 1)
        let topInText = topRect.minY + inset
        let bottomInText = bottomRect.maxY + inset
        let topLocal = textView.convert(NSPoint(x: 0, y: topInText), to: self).y
        let bottomLocal = textView.convert(NSPoint(x: 0, y: bottomInText), to: self).y
        let lo = min(topLocal, bottomLocal)
        let hi = max(topLocal, bottomLocal)
        return YRange(top: lo, bottom: hi)
    }

    private func drawRibbon(
        leftTopY: CGFloat,
        leftBottomY: CGFloat,
        rightTopY: CGFloat,
        rightBottomY: CGFloat,
        style: RibbonStyle
    ) {
        let width = bounds.width
        let cx = width * 0.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: leftTopY))
        path.curve(
            to: NSPoint(x: width, y: rightTopY),
            controlPoint1: NSPoint(x: cx, y: leftTopY),
            controlPoint2: NSPoint(x: cx, y: rightTopY)
        )
        path.line(to: NSPoint(x: width, y: rightBottomY))
        path.curve(
            to: NSPoint(x: 0, y: leftBottomY),
            controlPoint1: NSPoint(x: cx, y: rightBottomY),
            controlPoint2: NSPoint(x: cx, y: leftBottomY)
        )
        path.close()
        style.fill.setFill()
        path.fill()

        // Stroke only the top + bottom curves (skip the vertical edges so the
        // ribbon reads as connected to each pane rather than a closed shape).
        let topCurve = NSBezierPath()
        topCurve.move(to: NSPoint(x: 0, y: leftTopY))
        topCurve.curve(
            to: NSPoint(x: width, y: rightTopY),
            controlPoint1: NSPoint(x: cx, y: leftTopY),
            controlPoint2: NSPoint(x: cx, y: rightTopY)
        )
        let bottomCurve = NSBezierPath()
        bottomCurve.move(to: NSPoint(x: 0, y: leftBottomY))
        bottomCurve.curve(
            to: NSPoint(x: width, y: rightBottomY),
            controlPoint1: NSPoint(x: cx, y: leftBottomY),
            controlPoint2: NSPoint(x: cx, y: rightBottomY)
        )
        topCurve.lineWidth = 1
        bottomCurve.lineWidth = 1
        if style.dashed {
            topCurve.setLineDash([4, 3], count: 2, phase: 0)
            bottomCurve.setLineDash([4, 3], count: 2, phase: 0)
        }
        style.stroke.setStroke()
        topCurve.stroke()
        bottomCurve.stroke()
    }
}

// MARK: - DiffCodeScrollView

/// Pane scroll view used by the side-by-side diff. Vertical sync is handled
/// at the container level via row-mapped translation (so the IntelliJ-style
/// asymmetric layout works without one side getting clamped). The wheel
/// pipeline only forwards the horizontal delta to its partner so long lines
/// stay in sync horizontally.
final class DiffCodeScrollView: NSScrollView {
    weak var horizontalPartner: DiffCodeScrollView?
    fileprivate var isMirroringPartner: Bool = false

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard !isMirroringPartner, let partner = horizontalPartner else { return }
        // Only mirror horizontal deltas; vertical handled by row-mapped sync.
        if abs(event.scrollingDeltaX) <= 0.001 { return }
        partner.isMirroringPartner = true
        partner.scrollWheel(with: event)
        partner.isMirroringPartner = false
    }
}

// MARK: - Overview Ruler

/// Vertical strip that mirrors the change distribution of one side, so users
/// can jump anywhere there's a marker and see at a glance where the diffs are.
final class DiffOverviewRuler: NSView {
    private var leftKinds: [SideBySideLineKind] = []
    private var rightKinds: [SideBySideLineKind] = []
    /// When set, the ruler renders three lanes (ours | base | theirs) instead
    /// of the default two. Used by the 3-way conflict viewer.
    private var baseKinds: [SideBySideLineKind]? = nil
    private var thumbFraction: CGFloat = 0
    private var thumbVisibleFraction: CGFloat = 1
    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?
    var onClickFraction: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    func update(leftKinds: [SideBySideLineKind], rightKinds: [SideBySideLineKind]) {
        self.leftKinds = leftKinds
        self.rightKinds = rightKinds
        self.baseKinds = nil
        needsDisplay = true
    }

    func update(
        oursKinds: [SideBySideLineKind],
        baseKinds: [SideBySideLineKind],
        theirsKinds: [SideBySideLineKind]
    ) {
        self.leftKinds = oursKinds
        self.baseKinds = baseKinds
        self.rightKinds = theirsKinds
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

        let conflictColor = NSColor(srgbRed: 220/255, green: 90/255, blue: 200/255, alpha: 0.95)
        let deletedColor = NSColor(srgbRed: 255/255, green: 75/255, blue: 75/255, alpha: 0.9)
        let addedColor = NSColor(srgbRed: 155/255, green: 185/255, blue: 85/255, alpha: 0.9)
        let minBlockHeight: CGFloat = 2

        if let baseKinds {
            // 3-lane: ours | base | theirs.
            let totalCount = max(leftKinds.count, max(baseKinds.count, rightKinds.count))
            guard totalCount > 0 else { return }
            let oursPx = leftKinds.isEmpty ? 0 : bounds.height / CGFloat(leftKinds.count)
            let basePx = baseKinds.isEmpty ? 0 : bounds.height / CGFloat(baseKinds.count)
            let theirsPx = rightKinds.isEmpty ? 0 : bounds.height / CGFloat(rightKinds.count)
            let third = bounds.width / 3
            drawMarkers(
                kinds: leftKinds,
                xRange: 1..<(third - 0.5),
                pixelsPerLine: oursPx,
                minBlockHeight: minBlockHeight,
                addedColor: addedColor,
                deletedColor: deletedColor,
                hunkColor: nil,
                conflictColor: conflictColor
            )
            drawMarkers(
                kinds: baseKinds,
                xRange: (third + 0.5)..<(2 * third - 0.5),
                pixelsPerLine: basePx,
                minBlockHeight: minBlockHeight,
                addedColor: nil,
                deletedColor: nil,
                hunkColor: nil,
                conflictColor: conflictColor
            )
            drawMarkers(
                kinds: rightKinds,
                xRange: (2 * third + 0.5)..<(bounds.width - 1),
                pixelsPerLine: theirsPx,
                minBlockHeight: minBlockHeight,
                addedColor: addedColor,
                deletedColor: deletedColor,
                hunkColor: nil,
                conflictColor: conflictColor
            )
        } else {
            let totalCount = max(leftKinds.count, rightKinds.count)
            guard totalCount > 0 else { return }
            let leftPxPerLine = leftKinds.isEmpty ? 0 : bounds.height / CGFloat(leftKinds.count)
            let rightPxPerLine = rightKinds.isEmpty ? 0 : bounds.height / CGFloat(rightKinds.count)
            let midX = bounds.width / 2
            // Left half: markers for the left side (deletions). Right half:
            // markers for the right side (additions). Each side uses its own
            // pixels-per-line because the IntelliJ-style asymmetric layout means
            // left and right have different row counts.
            drawMarkers(
                kinds: leftKinds,
                xRange: 1..<(midX - 0.5),
                pixelsPerLine: leftPxPerLine,
                minBlockHeight: minBlockHeight,
                addedColor: nil,
                deletedColor: deletedColor,
                hunkColor: nil,
                conflictColor: conflictColor
            )
            drawMarkers(
                kinds: rightKinds,
                xRange: (midX + 0.5)..<(bounds.width - 1),
                pixelsPerLine: rightPxPerLine,
                minBlockHeight: minBlockHeight,
                addedColor: addedColor,
                deletedColor: nil,
                hunkColor: nil,
                conflictColor: conflictColor
            )
        }
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
