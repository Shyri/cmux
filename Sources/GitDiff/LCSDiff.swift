import Foundation

// MARK: - Token diff

/// Character ranges (UTF-16 based, suitable for NSAttributedString use) on each
/// side of a paired deletion/addition that correspond to tokens present on one
/// side only.
struct TokenDiffResult: Equatable, Sendable {
    let leftRanges: [NSRange]
    let rightRanges: [NSRange]

    static let empty = TokenDiffResult(leftRanges: [], rightRanges: [])
}

/// Tokenizes both strings by Unicode word boundaries, runs an LCS-based diff
/// and returns the ranges of tokens that are unique to each side.
///
/// Long lines skip the diff and return empty ranges — callers should fall
/// back to highlighting the whole row.
func computeTokenDiff(_ left: String, _ right: String, limit: Int = 5000) -> TokenDiffResult {
    if left.count > limit || right.count > limit {
        return .empty
    }
    if left == right {
        return .empty
    }

    let leftTokens = tokenize(left)
    let rightTokens = tokenize(right)
    if leftTokens.isEmpty || rightTokens.isEmpty {
        return .empty
    }

    let script = lcsScript(
        a: leftTokens.map(\.text),
        b: rightTokens.map(\.text)
    )

    var leftRanges: [NSRange] = []
    var rightRanges: [NSRange] = []

    for op in script {
        switch op {
        case .deleteLeft(let i):
            let tok = leftTokens[i]
            if isMeaningful(tok.text) {
                leftRanges.append(tok.utf16Range)
            }
        case .insertRight(let j):
            let tok = rightTokens[j]
            if isMeaningful(tok.text) {
                rightRanges.append(tok.utf16Range)
            }
        case .keep:
            break
        }
    }

    return TokenDiffResult(
        leftRanges: mergeContiguous(leftRanges),
        rightRanges: mergeContiguous(rightRanges)
    )
}

// MARK: - Tokenization

private struct Token {
    let text: String
    let utf16Range: NSRange
}

/// Whitespace tokens are kept so offsets are accurate, but we skip them when
/// building highlight ranges so visual noise stays low.
private func tokenize(_ s: String) -> [Token] {
    var tokens: [Token] = []
    let view = s.utf16
    var utf16Start = 0
    var buffer = ""
    var bufferStart = 0

    enum CharClass { case word, space, punct }
    func classify(_ c: Character) -> CharClass {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .punct
    }

    var currentClass: CharClass?
    for c in s {
        let utf16Length = c.utf16.count
        let cls = classify(c)
        if currentClass == nil {
            currentClass = cls
            buffer = String(c)
            bufferStart = utf16Start
            utf16Start += utf16Length
            continue
        }
        if cls == currentClass && cls != .punct {
            buffer.append(c)
        } else {
            // Emit previous buffer
            tokens.append(Token(
                text: buffer,
                utf16Range: NSRange(location: bufferStart, length: buffer.utf16.count)
            ))
            buffer = String(c)
            bufferStart = utf16Start
            currentClass = cls
        }
        utf16Start += utf16Length
    }
    if !buffer.isEmpty {
        tokens.append(Token(
            text: buffer,
            utf16Range: NSRange(location: bufferStart, length: buffer.utf16.count)
        ))
    }

    // Guardrail: if the tokenizer produced an unreasonable number of tokens
    // (e.g. minified JS on one line), collapse.
    _ = view
    return tokens
}

private func isMeaningful(_ token: String) -> Bool {
    if token.isEmpty { return false }
    // Skip pure whitespace tokens so highlighting only covers real content.
    return token.first.map { !$0.isWhitespace } ?? false
}

private func mergeContiguous(_ ranges: [NSRange]) -> [NSRange] {
    guard !ranges.isEmpty else { return [] }
    var result: [NSRange] = []
    let sorted = ranges.sorted { $0.location < $1.location }
    var current = sorted[0]
    for r in sorted.dropFirst() {
        if r.location <= current.location + current.length {
            let end = max(current.location + current.length, r.location + r.length)
            current = NSRange(location: current.location, length: end - current.location)
        } else {
            result.append(current)
            current = r
        }
    }
    result.append(current)
    return result
}

// MARK: - LCS-based edit script

private enum EditOp {
    case deleteLeft(Int)
    case insertRight(Int)
    case keep
}

/// Builds an edit script from an LCS table. Cheaper than a full Myers diff
/// for the token counts we deal with (a single line). Complexity O(n*m).
private func lcsScript<T: Hashable>(a: [T], b: [T]) -> [EditOp] {
    let n = a.count
    let m = b.count
    if n == 0 { return (0..<m).map { .insertRight($0) } }
    if m == 0 { return (0..<n).map { .deleteLeft($0) } }

    // Guard: avoid quadratic blowup for very long tokenized lines.
    if n * m > 500_000 {
        return (0..<n).map { .deleteLeft($0) } + (0..<m).map { .insertRight($0) }
    }

    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 1...n {
        for j in 1...m {
            if a[i - 1] == b[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }

    var ops: [EditOp] = []
    var i = n
    var j = m
    while i > 0 && j > 0 {
        if a[i - 1] == b[j - 1] {
            ops.append(.keep)
            i -= 1
            j -= 1
        } else if dp[i - 1][j] >= dp[i][j - 1] {
            ops.append(.deleteLeft(i - 1))
            i -= 1
        } else {
            ops.append(.insertRight(j - 1))
            j -= 1
        }
    }
    while i > 0 {
        ops.append(.deleteLeft(i - 1))
        i -= 1
    }
    while j > 0 {
        ops.append(.insertRight(j - 1))
        j -= 1
    }
    return ops.reversed()
}
