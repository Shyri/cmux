import AppKit
import SwiftUI

// MARK: - Public API

/// SwiftUI wrapper for the 3-pane (ours | base | theirs) viewer used when a
/// file has merge conflicts. Mirrors `DiffCodeTextView` but with three columns,
/// two connectors, and a 3-lane minimap.
struct DiffThreeWayCodeTextView: NSViewRepresentable {
    let prepared: ThreeWayPrepared
    @Binding var scrollHunkIndex: Int?

    func makeNSView(context: Context) -> DiffThreeWayContainer {
        let container = DiffThreeWayContainer()
        container.configure()
        return container
    }

    func updateNSView(_ container: DiffThreeWayContainer, context: Context) {
        container.apply(prepared)
        if let idx = scrollHunkIndex {
            container.scrollToHunk(at: idx)
            DispatchQueue.main.async { self.scrollHunkIndex = nil }
        }
    }
}

// MARK: - Container

/// Three NSScrollView panes arranged horizontally with two connectors and a
/// 3-lane minimap on the right. Scroll sync uses `base` as pivot.
final class DiffThreeWayContainer: NSView {
    private let oursScroll = DiffCodeScrollView()
    private let baseScroll = DiffCodeScrollView()
    private let theirsScroll = DiffCodeScrollView()
    private let oursText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let baseText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let theirsText: DiffTextView = DiffCodeContainer.makeCodeTextView()
    private let leftConnector = DiffConnectorView()
    private let rightConnector = DiffConnectorView()
    private let overviewRuler = DiffOverviewRuler()

    private let oursLabel = NSTextField(labelWithString: "")
    private let baseLabel = NSTextField(labelWithString: "")
    private let theirsLabel = NSTextField(labelWithString: "")

    private var oursLineStarts: [Int] = []
    private var baseLineStarts: [Int] = []
    private var theirsLineStarts: [Int] = []
    private var oursToBaseRow: [Int] = []
    private var baseToOursRow: [Int] = []
    private var baseToTheirsRow: [Int] = []
    private var theirsToBaseRow: [Int] = []
    private var hunkOffsetsBase: [Int] = []
    private var isSyncingScroll = false

    private let rulerWidth: CGFloat = 24
    private let headerHeight: CGFloat = 22

    func configure() {
        wantsLayer = true
        layer?.backgroundColor = DiffCodeContainer.editorBackground.cgColor

        for (scroll, text) in [(oursScroll, oursText), (baseScroll, baseText), (theirsScroll, theirsText)] {
            DiffCodeContainer.configureCodePane(scrollView: scroll, textView: text)
            addSubview(scroll)
        }

        leftConnector.bind(leftText: oursText, rightText: baseText)
        rightConnector.bind(leftText: baseText, rightText: theirsText)
        addSubview(leftConnector)
        addSubview(rightConnector)
        addSubview(overviewRuler)

        for label in [oursLabel, baseLabel, theirsLabel] {
            label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.backgroundColor = DiffCodeContainer.editorBackground
            label.drawsBackground = true
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }

        oursScroll.horizontalPartner = baseScroll
        baseScroll.horizontalPartner = theirsScroll
        theirsScroll.horizontalPartner = oursScroll

        for (scroll, sel) in [
            (oursScroll, #selector(oursBoundsChanged(_:))),
            (baseScroll, #selector(baseBoundsChanged(_:))),
            (theirsScroll, #selector(theirsBoundsChanged(_:))),
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: sel,
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
        }

        overviewRuler.onClickFraction = { [weak self] fraction in
            self?.scrollAllToFraction(fraction)
        }
        updateThumbs()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Apply

    func apply(_ p: ThreeWayPrepared) {
        if oursText.textStorage?.isEqual(to: p.oursAttr) != true {
            oursText.textStorage?.setAttributedString(p.oursAttr)
        }
        if baseText.textStorage?.isEqual(to: p.baseAttr) != true {
            baseText.textStorage?.setAttributedString(p.baseAttr)
        }
        if theirsText.textStorage?.isEqual(to: p.theirsAttr) != true {
            theirsText.textStorage?.setAttributedString(p.theirsAttr)
        }
        oursText.rowBackgrounds = p.oursRowBackgrounds.map { ($0.range, $0.color) }
        baseText.rowBackgrounds = p.baseRowBackgrounds.map { ($0.range, $0.color) }
        theirsText.rowBackgrounds = p.theirsRowBackgrounds.map { ($0.range, $0.color) }
        oursText.stubRanges = []
        baseText.stubRanges = []
        theirsText.stubRanges = []
        oursText.inlineWidgets = []
        baseText.inlineWidgets = []
        theirsText.inlineWidgets = []
        if let r = oursScroll.verticalRulerView as? DiffLineNumberRuler {
            r.update(lineNumbers: p.oursLineNumbers, lineStarts: p.oursLineStarts)
        }
        if let r = baseScroll.verticalRulerView as? DiffLineNumberRuler {
            r.update(lineNumbers: p.baseLineNumbers, lineStarts: p.baseLineStarts)
        }
        if let r = theirsScroll.verticalRulerView as? DiffLineNumberRuler {
            r.update(lineNumbers: p.theirsLineNumbers, lineStarts: p.theirsLineStarts)
        }
        oursLabel.stringValue = p.oursLabel
        baseLabel.stringValue = p.baseLabel
        theirsLabel.stringValue = p.theirsLabel
        oursLineStarts = p.oursLineStarts
        baseLineStarts = p.baseLineStarts
        theirsLineStarts = p.theirsLineStarts
        oursToBaseRow = p.oursToBaseRow
        baseToOursRow = p.baseToOursRow
        baseToTheirsRow = p.baseToTheirsRow
        theirsToBaseRow = p.theirsToBaseRow
        hunkOffsetsBase = p.hunkOffsetsBase
        overviewRuler.update(
            oursKinds: p.oursLineKinds,
            baseKinds: p.baseLineKinds,
            theirsKinds: p.theirsLineKinds
        )
        leftConnector.update(
            segments: p.oursBaseConnectorSegments,
            leftLineStarts: p.oursLineStarts,
            rightLineStarts: p.baseLineStarts
        )
        rightConnector.update(
            segments: p.baseTheirsConnectorSegments,
            leftLineStarts: p.baseLineStarts,
            rightLineStarts: p.theirsLineStarts
        )
        needsLayout = true
    }

    func scrollToHunk(at index: Int) {
        guard index >= 0, index < hunkOffsetsBase.count else { return }
        let baseOffset = hunkOffsetsBase[index]
        ensureLayout(on: baseText)
        scrollOffset(baseText, to: baseOffset)
    }

    private func ensureLayout(on textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
    }

    private func scrollOffset(_ textView: NSTextView, to characterIndex: Int) {
        guard let lm = textView.layoutManager, textView.textContainer != nil else { return }
        let length = textView.string.utf16.count
        let clamped = max(0, min(characterIndex, length))
        let glyphIndex = lm.glyphIndexForCharacter(at: clamped)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let insetY = textView.textContainerInset.height
        let targetY = max(0, lineRect.minY + insetY - 8)
        textView.scroll(NSPoint(x: 0, y: targetY))
    }

    private func scrollAllToFraction(_ fraction: CGFloat) {
        for scroll in [oursScroll, baseScroll, theirsScroll] {
            guard let doc = scroll.documentView else { continue }
            let totalHeight = doc.frame.height
            let viewHeight = scroll.contentView.bounds.height
            let maxOffset = max(0, totalHeight - viewHeight)
            let targetY = max(0, min(maxOffset, fraction * totalHeight - viewHeight / 2))
            var origin = scroll.contentView.bounds.origin
            origin.y = targetY
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func updateThumbs() {
        guard let doc = baseScroll.documentView else { return }
        let total = doc.frame.height
        let visible = baseScroll.contentView.bounds.height
        if total <= visible {
            overviewRuler.updateThumb(fraction: 0, visibleFraction: 1)
        } else {
            let frac = max(0, min(1, baseScroll.contentView.bounds.origin.y / (total - visible)))
            overviewRuler.updateThumb(fraction: frac, visibleFraction: visible / total)
        }
    }

    // MARK: Scroll sync (base as pivot)

    @objc private func oursBoundsChanged(_ note: Notification) {
        if !isSyncingScroll { syncFrom(.ours) }
        updateThumbs()
        oursScroll.verticalRulerView?.needsDisplay = true
        leftConnector.needsDisplay = true
    }

    @objc private func baseBoundsChanged(_ note: Notification) {
        if !isSyncingScroll { syncFrom(.base) }
        updateThumbs()
        baseScroll.verticalRulerView?.needsDisplay = true
        leftConnector.needsDisplay = true
        rightConnector.needsDisplay = true
    }

    @objc private func theirsBoundsChanged(_ note: Notification) {
        if !isSyncingScroll { syncFrom(.theirs) }
        updateThumbs()
        theirsScroll.verticalRulerView?.needsDisplay = true
        rightConnector.needsDisplay = true
    }

    private enum Side { case ours, base, theirs }

    private func syncFrom(_ driver: Side) {
        // Resolve driver row, map to base row, then map base→ours and base→theirs.
        guard let driverRow = currentTopRow(for: driver) else { return }
        let baseRow: Int
        switch driver {
        case .ours:
            guard driverRow < oursToBaseRow.count else { return }
            baseRow = clampBaseRow(oursToBaseRow[driverRow])
        case .base:
            baseRow = clampBaseRow(driverRow)
        case .theirs:
            guard driverRow < theirsToBaseRow.count else { return }
            baseRow = clampBaseRow(theirsToBaseRow[driverRow])
        }

        isSyncingScroll = true
        if driver != .base {
            scrollSide(.base, toRow: baseRow, intraRowOffset: intraRowOffset(for: driver, row: driverRow))
        }
        if driver != .ours, !baseToOursRow.isEmpty {
            let mapped = baseRow < baseToOursRow.count ? baseToOursRow[baseRow] : 0
            scrollSide(.ours, toRow: mapped, intraRowOffset: intraRowOffset(for: driver, row: driverRow))
        }
        if driver != .theirs, !baseToTheirsRow.isEmpty {
            let mapped = baseRow < baseToTheirsRow.count ? baseToTheirsRow[baseRow] : 0
            scrollSide(.theirs, toRow: mapped, intraRowOffset: intraRowOffset(for: driver, row: driverRow))
        }
        isSyncingScroll = false
    }

    private func clampBaseRow(_ r: Int) -> Int {
        max(0, min(r, max(0, baseLineStarts.count - 1)))
    }

    private func currentTopRow(for side: Side) -> Int? {
        let scroll: NSScrollView
        let textView: NSTextView
        let starts: [Int]
        switch side {
        case .ours:   scroll = oursScroll;   textView = oursText;   starts = oursLineStarts
        case .base:   scroll = baseScroll;   textView = baseText;   starts = baseLineStarts
        case .theirs: scroll = theirsScroll; textView = theirsText; starts = theirsLineStarts
        }
        guard !starts.isEmpty,
              let lm = textView.layoutManager,
              let tc = textView.textContainer else { return nil }
        let insetY = textView.textContainerInset.height
        let probeY = max(0, scroll.contentView.bounds.origin.y - insetY)
        let glyphIndex = lm.glyphIndex(for: NSPoint(x: 0, y: probeY), in: tc)
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)

        var lo = 0
        var hi = starts.count - 1
        var row = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= charIndex {
                row = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return row
    }

    private func intraRowOffset(for side: Side, row: Int) -> CGFloat {
        let scroll: NSScrollView
        let textView: NSTextView
        let starts: [Int]
        switch side {
        case .ours:   scroll = oursScroll;   textView = oursText;   starts = oursLineStarts
        case .base:   scroll = baseScroll;   textView = baseText;   starts = baseLineStarts
        case .theirs: scroll = theirsScroll; textView = theirsText; starts = theirsLineStarts
        }
        guard row < starts.count, let lm = textView.layoutManager else { return 0 }
        let insetY = textView.textContainerInset.height
        let glyphIndex = lm.glyphIndexForCharacter(at: starts[row])
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return scroll.contentView.bounds.origin.y - (lineRect.minY + insetY)
    }

    private func scrollSide(_ side: Side, toRow row: Int, intraRowOffset offset: CGFloat) {
        let scroll: NSScrollView
        let textView: NSTextView
        let starts: [Int]
        switch side {
        case .ours:   scroll = oursScroll;   textView = oursText;   starts = oursLineStarts
        case .base:   scroll = baseScroll;   textView = baseText;   starts = baseLineStarts
        case .theirs: scroll = theirsScroll; textView = theirsText; starts = theirsLineStarts
        }
        guard !starts.isEmpty, let lm = textView.layoutManager else { return }
        let r = max(0, min(row, starts.count - 1))
        let charIndex = starts[r]
        let length = textView.textStorage?.length ?? 0
        let clamped = max(0, min(charIndex, max(0, length - 1)))
        guard lm.numberOfGlyphs > 0 else { return }
        let glyph = lm.glyphIndexForCharacter(at: clamped)
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let insetY = textView.textContainerInset.height
        let totalHeight = scroll.documentView?.frame.height ?? 0
        let visibleHeight = scroll.contentView.bounds.height
        let maxY = max(0, totalHeight - visibleHeight)
        let targetY = max(0, min(maxY, lineRect.minY + insetY + offset))
        let currentX = scroll.contentView.bounds.origin.x
        if abs(scroll.contentView.bounds.origin.y - targetY) < 0.5 { return }
        scroll.contentView.scroll(to: NSPoint(x: currentX, y: targetY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Layout

    override func layout() {
        let previousBounds = bounds
        super.layout()
        let connectorEnabled = UserDefaults.standard.object(forKey: "diff.connector.enabled") as? Bool ?? true
        let configuredWidthRaw = UserDefaults.standard.object(forKey: "diff.connector.width") as? Double
        let configuredWidth = CGFloat(configuredWidthRaw ?? 36)
        let connectorWidth: CGFloat = connectorEnabled
            ? max(8, min(120, configuredWidth))
            : 2

        leftConnector.connectorEnabled = connectorEnabled
        rightConnector.connectorEnabled = connectorEnabled

        let usableWidth = max(1, bounds.width - rulerWidth)
        let paneWidth = max(1, (usableWidth - 2 * connectorWidth) / 3)
        let bodyHeight = max(0, bounds.height - headerHeight)

        let oursX: CGFloat = 0
        let baseX = oursX + paneWidth + connectorWidth
        let theirsX = baseX + paneWidth + connectorWidth
        let theirsW = max(1, usableWidth - 2 * paneWidth - 2 * connectorWidth)

        oursLabel.frame = NSRect(x: oursX + 6, y: bounds.height - headerHeight, width: paneWidth - 6, height: headerHeight)
        baseLabel.frame = NSRect(x: baseX + 6, y: bounds.height - headerHeight, width: paneWidth - 6, height: headerHeight)
        theirsLabel.frame = NSRect(x: theirsX + 6, y: bounds.height - headerHeight, width: theirsW - 6, height: headerHeight)

        oursScroll.frame = NSRect(x: oursX, y: 0, width: paneWidth, height: bodyHeight)
        leftConnector.frame = NSRect(x: oursX + paneWidth, y: 0, width: connectorWidth, height: bodyHeight)
        baseScroll.frame = NSRect(x: baseX, y: 0, width: paneWidth, height: bodyHeight)
        rightConnector.frame = NSRect(x: baseX + paneWidth, y: 0, width: connectorWidth, height: bodyHeight)
        theirsScroll.frame = NSRect(x: theirsX, y: 0, width: theirsW, height: bodyHeight)
        overviewRuler.frame = NSRect(x: bounds.width - rulerWidth, y: 0, width: rulerWidth, height: bounds.height)

        leftConnector.needsDisplay = true
        rightConnector.needsDisplay = true
        if previousBounds.size != bounds.size {
            updateThumbs()
        }
    }
}
