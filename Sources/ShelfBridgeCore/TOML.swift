import Foundation

/// The small TOML subset `config.toml` needs: `[section]`, `key = value` with strings,
/// integers, floats, booleans and flat arrays of those, `#` comments. No dependency.
public enum TOMLValue: Equatable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool), array([TOMLValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .int(let i) = self { return i }; return nil }
    public var double: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "config.toml line \(line): \(message)" }
}

public enum TOML {
    /// Keys are flattened as `section.key`.
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var out: [String: TOMLValue] = [:]
        var section = ""
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let n = i + 1
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else { throw TOMLError(line: n, message: "section header") }
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard isBareKey(section) else { throw TOMLError(line: n, message: "section name '\(section)'") }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw TOMLError(line: n, message: "missing '='") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else { throw TOMLError(line: n, message: "key '\(key)'") }
            var rest = Substring(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            let value = try parseValue(&rest, line: n)
            guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { throw TOMLError(line: n, message: "trailing content") }
            let full = section.isEmpty ? key : "\(section).\(key)"
            guard out[full] == nil else { throw TOMLError(line: n, message: "'\(full)' given twice") }
            out[full] = value
        }
        return out
    }

    static func isBareKey<S: StringProtocol>(_ s: S) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Drops a `#` comment that is not inside a string.
    static func stripComment(_ s: String) -> String {
        var inString = false, escaped = false
        for (idx, c) in zip(s.indices, s) {
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString { return String(s[..<idx]) }
        }
        return s
    }

    static func parseValue(_ s: inout Substring, line: Int) throws -> TOMLValue {
        s = s.drop { $0 == " " || $0 == "\t" }
        guard let first = s.first else { throw TOMLError(line: line, message: "missing value") }
        if first == "\"" { return .string(try parseString(&s, line: line)) }
        if first == "[" {
            s.removeFirst()
            var items: [TOMLValue] = []
            while true {
                s = s.drop { $0 == " " || $0 == "\t" }
                if s.first == "]" { s.removeFirst(); return .array(items) }
                items.append(try parseValue(&s, line: line))
                s = s.drop { $0 == " " || $0 == "\t" }
                if s.first == "," { s.removeFirst(); continue }
                guard s.first == "]" else { throw TOMLError(line: line, message: "unclosed array") }
            }
        }
        let token = s.prefix { $0 != "," && $0 != "]" && $0 != " " && $0 != "\t" }
        s = s.dropFirst(token.count)
        switch token {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            let clean = token.replacingOccurrences(of: "_", with: "")
            if let i = Int(clean) { return .int(i) }
            if let d = Double(clean) { return .double(d) }
            throw TOMLError(line: line, message: "value '\(token)'")
        }
    }

    static func parseString(_ s: inout Substring, line: Int) throws -> String {
        s.removeFirst()
        var out = ""
        while let c = s.first {
            s.removeFirst()
            switch c {
            case "\"": return out
            case "\\":
                guard let e = s.first else { break }
                s.removeFirst()
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: throw TOMLError(line: line, message: "escape '\\\(e)'")
                }
            default: out.append(c)
            }
        }
        throw TOMLError(line: line, message: "unclosed string")
    }
}
