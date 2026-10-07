import Foundation

/// Minimal parser for Valve's KeyValues text format (.acf / .vdf).
///
///     "AppState"
///     {
///         "appid"   "570"
///         "name"    "Dota 2"
///     }
public indirect enum VDFNode: Equatable, Sendable {
    case value(String)
    case object([(String, VDFNode)])

    public static func == (lhs: VDFNode, rhs: VDFNode) -> Bool {
        switch (lhs, rhs) {
        case let (.value(a), .value(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { pair in
                pair.0.0 == pair.1.0 && pair.0.1 == pair.1.1
            }
        default: return false
        }
    }

    /// Case-insensitive child lookup (Steam is inconsistent about key casing).
    public subscript(key: String) -> VDFNode? {
        guard case let .object(children) = self else { return nil }
        let lower = key.lowercased()
        return children.first(where: { $0.0.lowercased() == lower })?.1
    }

    public var string: String? {
        if case let .value(s) = self { return s }
        return nil
    }

    public var children: [(String, VDFNode)] {
        if case let .object(c) = self { return c }
        return []
    }
}

public enum VDFParser {
    enum Token: Equatable { case string(String), open, close }

    public static func parse(_ text: String) -> VDFNode {
        var tokens = tokenize(text)[...]
        return .object(parseObject(&tokens))
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace {
                i = text.index(after: i)
            } else if ch == "/" , text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" {
                // Line comment.
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
            } else if ch == "{" {
                tokens.append(.open); i = text.index(after: i)
            } else if ch == "}" {
                tokens.append(.close); i = text.index(after: i)
            } else if ch == "\"" {
                var value = ""
                i = text.index(after: i)
                while i < text.endIndex, text[i] != "\"" {
                    if text[i] == "\\", text.index(after: i) < text.endIndex {
                        let next = text[text.index(after: i)]
                        switch next {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "\\": value.append("\\")
                        case "\"": value.append("\"")
                        default: value.append("\\"); value.append(next)
                        }
                        i = text.index(i, offsetBy: 2)
                    } else {
                        value.append(text[i]); i = text.index(after: i)
                    }
                }
                if i < text.endIndex { i = text.index(after: i) } // closing quote
                tokens.append(.string(value))
            } else {
                // Unquoted token.
                var value = ""
                while i < text.endIndex, !text[i].isWhitespace, text[i] != "{", text[i] != "}", text[i] != "\"" {
                    value.append(text[i]); i = text.index(after: i)
                }
                tokens.append(.string(value))
            }
        }
        return tokens
    }

    static func parseObject(_ tokens: inout ArraySlice<Token>) -> [(String, VDFNode)] {
        var result: [(String, VDFNode)] = []
        while let token = tokens.first {
            switch token {
            case .close:
                tokens.removeFirst()
                return result
            case .open:
                // Stray brace; skip it.
                tokens.removeFirst()
            case let .string(key):
                tokens.removeFirst()
                guard let next = tokens.first else { return result }
                switch next {
                case let .string(value):
                    tokens.removeFirst()
                    result.append((key, .value(value)))
                case .open:
                    tokens.removeFirst()
                    result.append((key, .object(parseObject(&tokens))))
                case .close:
                    // Key without value; let the outer loop close the object.
                    break
                }
            }
        }
        return result
    }
}
