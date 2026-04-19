import Foundation
import AppKit

// MARK: - Language

enum HighlightLanguage: String, Sendable {
    case swift
    case tsJs
    case python
    case shell
    case json
    case yaml
    case markdown
    case html
    case css
    case go
    case rust
    case ruby
    case java
    case kotlin
    case plaintext

    static func detect(fromFilePath path: String) -> HighlightLanguage {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return .tsJs
        case "py": return .python
        case "sh", "bash", "zsh", "fish": return .shell
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "md", "markdown": return .markdown
        case "html", "htm", "xml", "vue", "svelte": return .html
        case "css", "scss", "sass", "less": return .css
        case "go": return .go
        case "rs": return .rust
        case "rb": return .ruby
        case "java": return .java
        case "kt", "kts": return .kotlin
        default: return .plaintext
        }
    }
}

// MARK: - Token classes + palette

enum HighlightKind: Sendable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case attribute
    case punct
}

private enum HighlightPalette {
    /// VS Code Dark+ defaults.
    static func color(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .keyword: return hex(0xC586C0)    // purple/pink — control flow
        case .type: return hex(0x4EC9B0)       // teal — types
        case .string: return hex(0xCE9178)     // salmon — strings
        case .number: return hex(0xB5CEA8)     // pale green — numbers
        case .comment: return hex(0x6A9955)    // green — comments
        case .function: return hex(0xDCDCAA)   // soft yellow — function names
        case .attribute: return hex(0x569CD6)  // blue — decorators / attributes
        case .punct: return NSColor.labelColor
        }
    }

    private static func hex(_ value: Int) -> NSColor {
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Pattern registry

private struct TokenPattern {
    let kind: HighlightKind
    let regex: NSRegularExpression
    /// When > 0, the capture group whose range is highlighted; 0 = whole match.
    let captureGroup: Int

    init(_ kind: HighlightKind, _ pattern: String, captureGroup: Int = 0, options: NSRegularExpression.Options = []) {
        self.kind = kind
        self.captureGroup = captureGroup
        // Treat patterns as multi-line friendly; "." does not match newlines
        // unless the pattern explicitly uses [\s\S].
        self.regex = (try? NSRegularExpression(pattern: pattern, options: options)) ?? Self.neverMatch()
    }

    private static func neverMatch() -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "(?!x)x", options: [])
    }
}

private enum LanguageDefinitions {
    static let cache: [HighlightLanguage: [TokenPattern]] = [
        .swift: swift,
        .tsJs: tsJs,
        .python: python,
        .shell: shell,
        .json: json,
        .yaml: yaml,
        .markdown: markdown,
        .html: html,
        .css: css,
        .go: go,
        .rust: rust,
        .ruby: ruby,
        .java: java,
        .kotlin: kotlin,
    ]

    // Order matters: comments and strings should be matched before keywords so
    // a keyword inside a string is not colored.
    private static let swift: [TokenPattern] = [
        TokenPattern(.comment, #"//[^\n]*"#),
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""""[\s\S]*?""""#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.attribute, #"@\w+"#),
        TokenPattern(.number, #"\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?)\b"#, options: [.caseInsensitive]),
        TokenPattern(.keyword, #"\b(?:import|let|var|func|return|if|else|guard|while|for|in|switch|case|default|break|continue|fallthrough|defer|do|try|catch|throw|throws|rethrows|async|await|class|struct|enum|protocol|extension|typealias|init|deinit|self|Self|super|public|private|internal|fileprivate|open|static|final|mutating|nonmutating|override|convenience|required|lazy|weak|unowned|indirect|associatedtype|where|is|as|nil|true|false|some|any|Any|throws)\b"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#),
    ]

    private static let tsJs: [TokenPattern] = [
        TokenPattern(.comment, #"//[^\n]*"#),
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'(?:\\.|[^'\\\n])*'"#),
        TokenPattern(.string, #"`(?:\\.|\$\{[^}]*\}|[^`\\])*`"#),
        TokenPattern(.number, #"\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?n?)\b"#, options: [.caseInsensitive]),
        TokenPattern(.keyword, #"\b(?:import|from|as|export|default|const|let|var|function|return|if|else|while|for|of|in|do|switch|case|break|continue|new|class|extends|implements|interface|type|enum|public|private|protected|readonly|static|abstract|async|await|yield|throw|try|catch|finally|this|super|typeof|instanceof|void|delete|null|undefined|true|false|keyof|satisfies|infer|never|unknown|any|namespace|module|declare)\b"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
        TokenPattern(.function, #"\b[a-z_$][A-Za-z0-9_$]*(?=\s*\()"#),
    ]

    private static let python: [TokenPattern] = [
        TokenPattern(.comment, #"#[^\n]*"#),
        TokenPattern(.string, #"(?:[rRbBuUfF]|[rR][bB]|[bB][rR]|[fF][rR]|[rR][fF])?"""[\s\S]*?""""#),
        TokenPattern(.string, #"(?:[rRbBuUfF]|[rR][bB]|[bB][rR]|[fF][rR]|[rR][fF])?'''[\s\S]*?'''"#),
        TokenPattern(.string, #"(?:[rRbBuUfF]|[rR][bB]|[bB][rR]|[fF][rR]|[rR][fF])?"(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"(?:[rRbBuUfF]|[rR][bB]|[bB][rR]|[fF][rR]|[rR][fF])?'(?:\\.|[^'\\\n])*'"#),
        TokenPattern(.attribute, #"@\w[\w.]*"#),
        TokenPattern(.number, #"\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?j?)\b"#),
        TokenPattern(.keyword, #"\b(?:def|class|return|if|elif|else|while|for|in|not|and|or|is|import|from|as|pass|break|continue|try|except|finally|raise|with|lambda|yield|async|await|global|nonlocal|True|False|None|self|cls)\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
    ]

    private static let shell: [TokenPattern] = [
        TokenPattern(.comment, #"#[^\n]*"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'[^'\n]*'"#),
        TokenPattern(.attribute, #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#),
        TokenPattern(.number, #"\b\d+\b"#),
        TokenPattern(.keyword, #"\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|exit|break|continue|export|local|readonly|set|unset|source|shift|trap)\b"#),
        TokenPattern(.function, #"^[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, options: [.anchorsMatchLines]),
    ]

    private static let json: [TokenPattern] = [
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*"(?=\s*:)"#), // keys
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
        TokenPattern(.keyword, #"\b(?:true|false|null)\b"#),
    ]

    private static let yaml: [TokenPattern] = [
        TokenPattern(.comment, #"#[^\n]*"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'[^'\n]*'"#),
        TokenPattern(.attribute, #"^\s*[A-Za-z0-9_.\-]+(?=\s*:)"#, options: [.anchorsMatchLines]),
        TokenPattern(.number, #"\b-?\d+(?:\.\d+)?\b"#),
        TokenPattern(.keyword, #"\b(?:true|false|null|yes|no|on|off|~)\b"#),
    ]

    private static let markdown: [TokenPattern] = [
        TokenPattern(.comment, #"<!--[\s\S]*?-->"#),
        TokenPattern(.keyword, #"^#{1,6}\s[^\n]+"#, options: [.anchorsMatchLines]),
        TokenPattern(.string, #"`[^`\n]+`"#),
        TokenPattern(.string, #"```[\s\S]*?```"#),
        TokenPattern(.function, #"\[[^\]]+\]\([^)]+\)"#),
        TokenPattern(.attribute, #"^\s*[-*+]\s"#, options: [.anchorsMatchLines]),
    ]

    private static let html: [TokenPattern] = [
        TokenPattern(.comment, #"<!--[\s\S]*?-->"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'[^'\n]*'"#),
        TokenPattern(.keyword, #"</?\s*[A-Za-z][A-Za-z0-9-]*"#),
        TokenPattern(.attribute, #"\b[A-Za-z][A-Za-z0-9-]*(?=\s*=)"#),
    ]

    private static let css: [TokenPattern] = [
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'[^'\n]*'"#),
        TokenPattern(.attribute, #"[A-Za-z\-]+(?=\s*:)"#),
        TokenPattern(.keyword, #"[#.][A-Za-z_][A-Za-z0-9_\-]*"#),
        TokenPattern(.number, #"\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b"#),
    ]

    private static let go: [TokenPattern] = [
        TokenPattern(.comment, #"//[^\n]*"#),
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"`[^`]*`"#),
        TokenPattern(.number, #"\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?)\b"#, options: [.caseInsensitive]),
        TokenPattern(.keyword, #"\b(?:package|import|func|return|if|else|for|range|switch|case|default|break|continue|fallthrough|go|defer|select|chan|const|var|type|struct|interface|map|true|false|nil|iota)\b"#),
        TokenPattern(.type, #"\b(?:string|int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float32|float64|byte|rune|bool|error|any)\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#),
    ]

    private static let rust: [TokenPattern] = [
        TokenPattern(.comment, #"//[^\n]*"#),
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.attribute, #"#\[[^\]]*\]"#),
        TokenPattern(.number, #"\b(?:0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?)\b"#, options: [.caseInsensitive]),
        TokenPattern(.keyword, #"\b(?:fn|let|mut|const|static|if|else|while|for|in|loop|match|return|break|continue|mod|pub|crate|use|as|struct|enum|impl|trait|where|self|Self|super|ref|move|type|dyn|async|await|unsafe|extern|true|false)\b"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#),
    ]

    private static let ruby: [TokenPattern] = [
        TokenPattern(.comment, #"#[^\n]*"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'[^'\n]*'"#),
        TokenPattern(.attribute, #"@[A-Za-z_][A-Za-z0-9_]*"#),
        TokenPattern(.number, #"\b\d[\d_]*(?:\.\d+)?\b"#),
        TokenPattern(.keyword, #"\b(?:def|end|class|module|if|elsif|else|unless|case|when|then|while|until|do|begin|rescue|ensure|return|yield|lambda|proc|true|false|nil|self|super|require|require_relative|attr_accessor|attr_reader|attr_writer)\b"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_!?]*(?=\s*[\(\s])"#),
    ]

    private static let java: [TokenPattern] = [
        TokenPattern(.comment, #"//[^\n]*"#),
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'(?:\\.|[^'\\\n])'"#),  // char literal
        TokenPattern(.attribute, #"@[A-Z][A-Za-z0-9_]*(?:\s*\([^)]*\))?"#),
        TokenPattern(.number, #"\b(?:0x[0-9a-fA-F_]+[lL]?|0b[01_]+[lL]?|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?[fFdDlL]?)\b"#),
        TokenPattern(.keyword, #"\b(?:abstract|assert|break|case|catch|class|const|continue|default|do|else|enum|extends|final|finally|for|goto|if|implements|import|instanceof|interface|native|new|package|private|protected|public|record|return|sealed|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|var|void|volatile|while|yield|true|false|null|non-sealed|permits)\b"#),
        TokenPattern(.type, #"\b(?:boolean|byte|char|double|float|int|long|short|String|Integer|Long|Float|Double|Boolean|Byte|Short|Character|Object|List|Map|Set|Collection|Iterator|Iterable|Optional|Stream|Void)\b"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#),
    ]

    private static let kotlin: [TokenPattern] = [
        TokenPattern(.comment, #"//[^\n]*"#),
        TokenPattern(.comment, #"/\*[\s\S]*?\*/"#),
        TokenPattern(.string, #""""[\s\S]*?""""#),  // raw/triple-quoted string
        TokenPattern(.string, #""(?:\\.|[^"\\\n])*""#),
        TokenPattern(.string, #"'(?:\\.|[^'\\\n])'"#),
        TokenPattern(.attribute, #"@[A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z_][A-Za-z0-9_]*)?(?:\s*\([^)]*\))?"#),
        TokenPattern(.number, #"\b(?:0x[0-9a-fA-F_]+[uUlL]*|0b[01_]+[uUlL]*|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?[fFLuU]?)\b"#),
        TokenPattern(.keyword, #"\b(?:abstract|actual|annotation|as|break|by|catch|class|companion|const|constructor|continue|crossinline|data|delegate|do|dynamic|else|enum|expect|external|false|field|file|final|finally|for|fun|get|if|import|in|infix|init|inline|inner|interface|internal|is|lateinit|noinline|null|object|open|operator|out|override|package|param|private|property|protected|public|receiver|reified|return|sealed|set|super|suspend|tailrec|this|throw|true|try|typealias|typeof|val|var|vararg|when|where|while)\b"#),
        TokenPattern(.type, #"\b(?:Int|Long|Short|Byte|Double|Float|Boolean|Char|String|Unit|Nothing|Any|Array|List|Map|Set|MutableList|MutableMap|MutableSet|Sequence|Pair|Triple)\b"#),
        TokenPattern(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#),
        TokenPattern(.function, #"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#),
    ]
}

// MARK: - Public API

enum SyntaxHighlighter {
    /// Applies foreground color attributes for the detected language.
    /// No-op when the language has no definition or the text is too large
    /// to keep highlighting responsive.
    static func apply(
        to attributed: NSMutableAttributedString,
        language: HighlightLanguage,
        maxLength: Int = 500_000
    ) {
        guard attributed.length <= maxLength else { return }
        guard let patterns = LanguageDefinitions.cache[language] else { return }

        let fullRange = NSRange(location: 0, length: attributed.length)
        // Track ranges that have been colored so later (less specific) patterns
        // do not overwrite comments or strings.
        var occupied = IndexSet()

        for pattern in patterns {
            pattern.regex.enumerateMatches(in: attributed.string, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                let idx = pattern.captureGroup
                let r = idx < match.numberOfRanges ? match.range(at: idx) : match.range
                if r.location == NSNotFound || r.length == 0 { return }
                let swiftRange = r.location..<(r.location + r.length)
                if occupied.contains(integersIn: swiftRange) { return }
                attributed.addAttribute(
                    .foregroundColor,
                    value: HighlightPalette.color(for: pattern.kind),
                    range: r
                )
                occupied.insert(integersIn: swiftRange)
            }
        }
    }
}
