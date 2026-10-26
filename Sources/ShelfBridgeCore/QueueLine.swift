import Foundation

/// One `AGENT-QUEUE.md` task line.
///
/// Grammar: `- [ ] <title words and key:value tokens>`. Only the closed key list below is
/// extracted from the title; any other `word:word` token stays part of the title.
public struct QueueItem: Equatable, Sendable {
    public enum Agent: String, Sendable, CaseIterable { case claude, codex }
    public enum Mode: String, Sendable, CaseIterable { case attended, unattended }

    public var id: String
    public var title: String
    public var checked: Bool
    public var agent: Agent
    public var mode: Mode
    public var ref: String?
    public var out: String?
    public var by: String?
    public var sig: String?
    /// 1-based line number in the file it came from.
    public var line: Int
    /// Set for a `SCHEDULED.md` line; `nil` for the queue.
    public var schedule: Schedule? = nil
}

public enum QueueLineError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingKey(String)
    case emptyValue(String)
    case duplicateKey(String)
    case badValue(key: String, value: String)
    case duplicateID(String, firstLine: Int)

    public var description: String {
        switch self {
        case .missingKey(let k): return "\(k): missing"
        case .emptyValue(let k): return "\(k): empty value"
        case .duplicateKey(let k): return "\(k): given twice"
        case .badValue(let k, let v): return "\(k): invalid value '\(v)'"
        case .duplicateID(let id, let first): return "id:\(id) is also on line \(first)"
        }
    }
}

/// A task line that looked like a queue item but could not be used.
public struct InvalidQueueLine: Equatable, Sendable {
    public var line: Int
    public var text: String
    public var error: QueueLineError
}

public struct QueueFile: Equatable, Sendable {
    public var items: [QueueItem]
    public var invalid: [InvalidQueueLine]

    public func item(id: String) -> QueueItem? { items.first { $0.id == id } }
}

public enum QueueGrammar {
    public static let fileName = "AGENT-QUEUE.md"
    public static let keys: Set<String> = ["id", "agent", "mode", "ref", "out", "by", "sig"]

    // Computed: `Regex` is not Sendable, so it cannot be a stored static under Swift 6.
    static var idPattern: Regex<Substring> { /^q-[0-9]{8}T[0-9]{4}-[0-9a-f]{4}$/ }
    static var refPattern: Regex<Substring> { /^[^@\s]+@[0-9a-f]{8}$/ }
    static var sigPattern: Regex<Substring> { /^[0-9a-f]{8}$/ }
    static var taskPattern: Regex<(Substring, Substring, Substring)> { /^- \[([ xX])\] (.*)$/ }

    public static func isValidID(_ s: String) -> Bool { s.wholeMatch(of: idPattern) != nil }

    /// Parses file contents. A trailing fragment without a final newline is ignored: it may be
    /// a half-written line.
    public static func parse(_ text: String) -> QueueFile {
        var lines = text.components(separatedBy: "\n")
        if !text.hasSuffix("\n") { lines.removeLast() }
        var items: [QueueItem] = []
        var invalid: [InvalidQueueLine] = []
        var seen: [String: Int] = [:]
        for (i, raw) in lines.enumerated() {
            let lineText = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            switch parseLine(lineText, line: i + 1) {
            case .none: continue
            case .failure(let e)?: invalid.append(.init(line: i + 1, text: lineText, error: e))
            case .success(let item)?:
                if let first = seen[item.id] {
                    invalid.append(.init(line: i + 1, text: lineText, error: .duplicateID(item.id, firstLine: first)))
                } else {
                    seen[item.id] = item.line
                    items.append(item)
                }
            }
        }
        return QueueFile(items: items, invalid: invalid)
    }

    /// `nil` when the line is not a task line at all.
    public static func parseLine(_ text: String, line: Int = 1) -> Result<QueueItem, QueueLineError>? {
        guard let m = text.wholeMatch(of: taskPattern) else { return nil }
        let checked = m.1 != " "
        var values: [String: String] = [:]
        var titleWords: [Substring] = []
        for token in m.2.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let colon = token.firstIndex(of: ":"), keys.contains(String(token[..<colon])) else {
                titleWords.append(token)
                continue
            }
            let key = String(token[..<colon])
            let value = String(token[token.index(after: colon)...])
            if value.isEmpty { return .failure(.emptyValue(key)) }
            if values[key] != nil { return .failure(.duplicateKey(key)) }
            values[key] = value
        }
        guard let id = values["id"] else { return .failure(.missingKey("id")) }
        guard isValidID(id) else { return .failure(.badValue(key: "id", value: id)) }
        guard let agentRaw = values["agent"] else { return .failure(.missingKey("agent")) }
        guard let agent = QueueItem.Agent(rawValue: agentRaw) else { return .failure(.badValue(key: "agent", value: agentRaw)) }
        let modeRaw = values["mode"] ?? QueueItem.Mode.attended.rawValue
        guard let mode = QueueItem.Mode(rawValue: modeRaw) else { return .failure(.badValue(key: "mode", value: modeRaw)) }
        if let ref = values["ref"], ref.wholeMatch(of: refPattern) == nil { return .failure(.badValue(key: "ref", value: ref)) }
        if let sig = values["sig"], sig.wholeMatch(of: sigPattern) == nil { return .failure(.badValue(key: "sig", value: sig)) }
        let title = titleWords.joined(separator: " ")
        if title.isEmpty { return .failure(.missingKey("title")) }
        return .success(QueueItem(id: id, title: title, checked: checked, agent: agent, mode: mode,
                                  ref: values["ref"], out: values["out"], by: values["by"], sig: values["sig"], line: line))
    }
}
