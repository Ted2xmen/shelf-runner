import Foundation

/// Unattended Claude prints one JSON object at exit (`--output-format json`); its
/// `permission_denials` count is the job's `blocked`.
/// A denial never changes the job's state: exit 0 stays `done`.
public enum PrintResult {
    /// The value of `--output-format` in the unattended Claude template.
    public static let outputFormat = "json"

    /// The only job whose stdout is kept as `<id>.result.json` and parsed. Everything else
    /// (attended jobs, Codex) has `blocked: null`.
    public static func applies(agent: QueueItem.Agent, mode: QueueItem.Mode) -> Bool {
        agent == .claude && mode == .unattended
    }

    public static func applies(agent: String, mode: String) -> Bool {
        guard let a = QueueItem.Agent(rawValue: agent), let m = QueueItem.Mode(rawValue: mode) else { return false }
        return applies(agent: a, mode: m)
    }

    public struct Parsed: Equatable, Sendable {
        /// What goes to the job's log: the `result` text, else the raw output as it came.
        public var text: String
        /// `permission_denials.count`; `nil` when the output is not the expected JSON.
        public var blocked: Int?
    }

    /// `raw` is the agent's whole stdout. Never throws: anything unreadable logs as raw text
    /// with `blocked: nil`.
    public static func parse(_ raw: Data) -> Parsed {
        let rawText = String(decoding: raw, as: UTF8.self)
        guard let o = resultObject(raw) else { return Parsed(text: rawText, blocked: nil) }
        return Parsed(text: (o["result"] as? String) ?? rawText, blocked: (o["permission_denials"] as? [Any])?.count)
    }

    /// One object; with `--verbose` Claude prints an array of messages instead, the last
    /// `"type": "result"` one carries the answer.
    static func resultObject(_ raw: Data) -> [String: Any]? {
        guard let any = try? JSONSerialization.jsonObject(with: raw) else { return nil }
        if let o = any as? [String: Any] { return o }
        return (any as? [Any])?.compactMap { $0 as? [String: Any] }.last { $0["type"] as? String == "result" }
    }
}
