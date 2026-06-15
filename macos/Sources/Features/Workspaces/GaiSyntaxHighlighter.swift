#if os(macOS)
import AppKit

/// A lightweight, dependency-free syntax highlighter for the in-stage code
/// editor. It's regex/token based (not a full parser) but covers the things
/// that make code readable — comments, strings, numbers, keywords, types and
/// function calls — across the common languages, in a One-Dark-style palette.
enum GaiSyntax {
    /// Don't re-highlight huge files on every keystroke (keeps typing snappy).
    static let maxLength = 200_000

    enum Theme {
        static let text = NSColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1)
        static let keyword = NSColor(srgbRed: 0.78, green: 0.47, blue: 0.87, alpha: 1)   // purple
        static let string = NSColor(srgbRed: 0.60, green: 0.76, blue: 0.47, alpha: 1)    // green
        static let number = NSColor(srgbRed: 0.82, green: 0.60, blue: 0.40, alpha: 1)    // orange
        static let comment = NSColor(srgbRed: 0.50, green: 0.53, blue: 0.58, alpha: 1)   // gray
        static let function = NSColor(srgbRed: 0.38, green: 0.69, blue: 0.94, alpha: 1)  // blue
        static let type = NSColor(srgbRed: 0.90, green: 0.75, blue: 0.48, alpha: 1)      // gold
    }

    // MARK: Public

    static func highlight(_ storage: NSTextStorage, language: String, font: NSFont) {
        let string = storage.string
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.text], range: full)

        // Above the size cap, leave it plain (just the base color) — no lag.
        if ns.length <= maxLength {
            paint(numberRE, Theme.number, in: storage, string)
            if let kw = keywordRE(for: language) { paint(kw, Theme.keyword, in: storage, string) }
            paint(typeRE, Theme.type, in: storage, string)
            paintCapture(funcRE, Theme.function, in: storage, string)   // the name before "("
            paint(doubleStringRE, Theme.string, in: storage, string)
            paint(singleStringRE, Theme.string, in: storage, string)
            if usesBacktick(language) { paint(backtickStringRE, Theme.string, in: storage, string) }
            paint(blockCommentRE, Theme.comment, in: storage, string)
            paint(usesHashComments(language) ? hashCommentRE : lineCommentRE, Theme.comment, in: storage, string)
        }

        storage.endEditing()
    }

    // MARK: Painting

    private static func paint(_ re: NSRegularExpression, _ color: NSColor, in storage: NSTextStorage, _ s: String) {
        let range = NSRange(location: 0, length: (s as NSString).length)
        re.enumerateMatches(in: s, options: [], range: range) { match, _, _ in
            if let r = match?.range, r.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
    }

    private static func paintCapture(_ re: NSRegularExpression, _ color: NSColor, in storage: NSTextStorage, _ s: String) {
        let range = NSRange(location: 0, length: (s as NSString).length)
        re.enumerateMatches(in: s, options: [], range: range) { match, _, _ in
            if let r = match?.range(at: 1), r.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }
    }

    // MARK: Regexes

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let numberRE = re(#"\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#)
    private static let typeRE = re(#"\b[A-Z][A-Za-z0-9_]*\b"#)
    private static let funcRE = re(#"\b([a-zA-Z_]\w*)\s*\("#)
    private static let doubleStringRE = re(#""(?:\\.|[^"\\\n])*""#)
    private static let singleStringRE = re(#"'(?:\\.|[^'\\\n])*'"#)
    private static let backtickStringRE = re("`(?:\\\\.|[^`\\\\])*`")
    private static let blockCommentRE = re(#"/\*[\s\S]*?\*/"#)
    private static let lineCommentRE = re(#"//[^\n]*"#)
    private static let hashCommentRE = re(#"#[^\n]*"#)

    // MARK: Languages

    private static func usesBacktick(_ lang: String) -> Bool {
        ["swift", "js", "mjs", "cjs", "jsx", "ts", "tsx"].contains(lang)
    }

    private static func usesHashComments(_ lang: String) -> Bool {
        ["py", "rb", "sh", "bash", "zsh", "fish", "yml", "yaml", "toml", "ini",
         "cfg", "conf", "env", "makefile", "dockerfile", "pl", "r"].contains(lang)
    }

    private static var keywordCache: [String: NSRegularExpression] = [:]

    private static func keywordRE(for lang: String) -> NSRegularExpression? {
        if let cached = keywordCache[lang] { return cached }
        let words = keywords(for: lang)
        guard !words.isEmpty else { return nil }
        let pattern = "\\b(?:" + words.joined(separator: "|") + ")\\b"
        let regex = re(pattern)
        keywordCache[lang] = regex
        return regex
    }

    private static func keywords(for lang: String) -> [String] {
        switch lang {
        case "swift":
            return ["func", "let", "var", "if", "else", "guard", "return", "struct", "class",
                    "enum", "protocol", "extension", "import", "for", "while", "repeat", "switch",
                    "case", "default", "break", "continue", "fallthrough", "in", "self", "Self",
                    "init", "deinit", "subscript", "override", "private", "fileprivate", "public",
                    "internal", "open", "static", "final", "lazy", "weak", "unowned", "throws",
                    "rethrows", "try", "catch", "throw", "async", "await", "defer", "where", "as",
                    "is", "nil", "true", "false", "some", "any", "associatedtype", "typealias",
                    "mutating", "nonmutating", "indirect", "convenience", "required", "didSet", "willSet", "get", "set"]
        case "js", "mjs", "cjs", "jsx", "ts", "tsx":
            return ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
                    "switch", "case", "default", "break", "continue", "class", "extends", "new",
                    "this", "super", "import", "export", "from", "as", "async", "await", "try",
                    "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "delete",
                    "null", "undefined", "true", "false", "void", "yield", "interface", "type",
                    "enum", "public", "private", "protected", "readonly", "static", "abstract",
                    "implements", "namespace", "declare", "keyof", "infer"]
        case "py":
            return ["def", "return", "if", "elif", "else", "for", "while", "in", "import", "from",
                    "as", "class", "try", "except", "finally", "raise", "with", "lambda", "yield",
                    "global", "nonlocal", "pass", "break", "continue", "and", "or", "not", "is",
                    "None", "True", "False", "async", "await", "del", "assert", "self"]
        case "go":
            return ["func", "var", "const", "type", "struct", "interface", "package", "import",
                    "return", "if", "else", "for", "range", "switch", "case", "default", "break",
                    "continue", "go", "defer", "chan", "select", "map", "nil", "true", "false", "make", "new"]
        case "rs":
            return ["fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "pub", "use",
                    "mod", "return", "if", "else", "for", "while", "loop", "match", "break",
                    "continue", "self", "Self", "where", "async", "await", "move", "ref", "as",
                    "dyn", "true", "false", "in"]
        case "c", "h", "cpp", "hpp", "cc", "java", "kt":
            return ["int", "char", "void", "float", "double", "long", "short", "unsigned", "signed",
                    "struct", "class", "enum", "union", "const", "static", "return", "if", "else",
                    "for", "while", "do", "switch", "case", "default", "break", "continue", "public",
                    "private", "protected", "new", "delete", "this", "true", "false", "null", "nullptr",
                    "namespace", "template", "typename", "using", "import", "package", "extends", "implements", "final"]
        case "json":
            return ["true", "false", "null"]
        default:
            return ["function", "func", "def", "return", "if", "else", "elif", "for", "while", "do",
                    "switch", "case", "break", "continue", "class", "struct", "enum", "import",
                    "export", "const", "let", "var", "new", "try", "catch", "throw", "true", "false",
                    "null", "nil", "none", "self", "this", "in", "of", "and", "or", "not"]
        }
    }
}
#endif
