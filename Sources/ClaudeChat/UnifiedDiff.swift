import Foundation

/// One line of a unified-diff render.
enum UnifiedDiffLine: Identifiable {
    case context(id: UUID, text: String, oldLineNo: Int, newLineNo: Int)
    case removed(id: UUID, text: String, oldLineNo: Int)
    case added(id: UUID, text: String, newLineNo: Int)
    /// A run of unmodified lines that are far enough from any change to
    /// hide by default. The view layer can expand it to reveal the
    /// underlying `lines`.
    case gap(id: UUID, hiddenLines: [HiddenContextLine])

    var id: UUID {
        switch self {
        case .context(let id, _, _, _): return id
        case .removed(let id, _, _): return id
        case .added(let id, _, _): return id
        case .gap(let id, _): return id
        }
    }

    struct HiddenContextLine: Identifiable {
        let id: UUID = UUID()
        let text: String
        let oldLineNo: Int
        let newLineNo: Int
    }
}

enum UnifiedDiff {
    /// Compute a unified-diff line list from two raw multi-line strings.
    ///
    /// `context` is how many surrounding identical lines to keep around
    /// each change before collapsing the rest into a `.gap`.
    static func compute(old: String, new: String, context: Int = 3) -> [UnifiedDiffLine] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        return compute(oldLines: oldLines, newLines: newLines, context: context)
    }

    static func compute(oldLines: [String], newLines: [String], context: Int = 3) -> [UnifiedDiffLine] {
        // Step 1: use Foundation's CollectionDifference (Myers-based) to
        // know which old indices were removed and which new indices were
        // inserted.
        let diff = newLines.difference(from: oldLines)
        var removedFromOld = Set<Int>()
        var insertedInNew = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedFromOld.insert(offset)
            case .insert(let offset, _, _):
                insertedInNew.insert(offset)
            }
        }

        // Step 2: walk both arrays in tandem, producing a flat list where
        // each entry is one of: context, removed, added.
        struct RawLine {
            enum Kind { case context, removed, added }
            let kind: Kind
            let text: String
            let oldNo: Int  // 1-indexed; 0 if N/A
            let newNo: Int  // 1-indexed; 0 if N/A
        }

        var raw: [RawLine] = []
        var i = 0  // index into oldLines
        var j = 0  // index into newLines

        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removedFromOld.contains(i) {
                raw.append(RawLine(kind: .removed, text: oldLines[i], oldNo: i + 1, newNo: 0))
                i += 1
            } else if j < newLines.count, insertedInNew.contains(j) {
                raw.append(RawLine(kind: .added, text: newLines[j], oldNo: 0, newNo: j + 1))
                j += 1
            } else {
                // Both indices land on a common line.
                if i < oldLines.count, j < newLines.count {
                    raw.append(RawLine(
                        kind: .context,
                        text: oldLines[i],
                        oldNo: i + 1,
                        newNo: j + 1
                    ))
                }
                i += 1
                j += 1
            }
        }

        // Step 3: mark which lines should be kept (changes + their
        // `context` neighbours). Everything else can collapse into a gap.
        var keep = Array(repeating: false, count: raw.count)
        for (idx, line) in raw.enumerated() where line.kind != .context {
            let lo = Swift.max(0, idx - context)
            let hi = Swift.min(raw.count - 1, idx + context)
            for k in lo...hi { keep[k] = true }
        }

        // Step 4: emit the final list, replacing runs of dropped context
        // with a single `.gap` entry that holds the original text so the
        // UI can show it on demand.
        var result: [UnifiedDiffLine] = []
        var gapAccumulator: [UnifiedDiffLine.HiddenContextLine] = []

        func flushGap() {
            guard !gapAccumulator.isEmpty else { return }
            result.append(.gap(id: UUID(), hiddenLines: gapAccumulator))
            gapAccumulator.removeAll()
        }

        for (idx, line) in raw.enumerated() {
            if keep[idx] {
                flushGap()
                switch line.kind {
                case .context:
                    result.append(.context(
                        id: UUID(),
                        text: line.text,
                        oldLineNo: line.oldNo,
                        newLineNo: line.newNo
                    ))
                case .removed:
                    result.append(.removed(
                        id: UUID(),
                        text: line.text,
                        oldLineNo: line.oldNo
                    ))
                case .added:
                    result.append(.added(
                        id: UUID(),
                        text: line.text,
                        newLineNo: line.newNo
                    ))
                }
            } else {
                // line.kind is always .context here (changes are always kept).
                gapAccumulator.append(.init(
                    text: line.text,
                    oldLineNo: line.oldNo,
                    newLineNo: line.newNo
                ))
            }
        }
        flushGap()
        return result
    }

    private static func splitLines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        return s.components(separatedBy: "\n")
    }
}
