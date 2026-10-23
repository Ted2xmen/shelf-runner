import Foundation

/// Agent limits: read-only, best effort, fresh for 15 minutes.
public struct LimitsReader {
    public var paths: Paths
    /// `~/.codex`, injectable for tests.
    public var codexHome: URL
    public var freshFor: TimeInterval = 15 * 60

    public init(paths: Paths, codexHome: URL? = nil) {
        self.paths = paths
        self.codexHome = codexHome ?? paths.home.appendingPathComponent(".codex")
    }

    public static func claudeFile(_ paths: Paths) -> URL { paths.stateDir.appendingPathComponent("claude-limits.json") }

    public func read(now: Date = Date()) -> [StatusV1.Limit] {
        [claude(now: now), codex(now: now)].compactMap { $0 }
    }

    /// The status line JSON `limits-tee` saved: `rate_limits.five_hour` / `seven_day`.
    func claude(now: Date) -> StatusV1.Limit? {
        let url = Self.claudeFile(paths)
        guard let at = mtime(url), now.timeIntervalSince(at) <= freshFor,
              let d = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rl = root["rate_limits"] as? [String: Any] else { return nil }
        let five = rl["five_hour"] as? [String: Any], week = rl["seven_day"] as? [String: Any]
        guard five != nil || week != nil else { return nil }
        return StatusV1.Limit(agent: "claude", source: "statusline", at: Clock.iso(at),
                              fiveHour: number(five?["used_percentage"]), week: number(week?["used_percentage"]),
                              resetsFiveHour: epoch(five?["resets_at"]), resetsWeek: epoch(week?["resets_at"]))
    }

    /// The newest rollout's last `rate_limits` (undocumented; windows of 300 and 10080 minutes).
    func codex(now: Date) -> StatusV1.Limit? {
        let sessions = codexHome.appendingPathComponent("sessions")
        var newest: (URL, Date)?
        if let e = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let u as URL in e where u.pathExtension == "jsonl" && u.lastPathComponent.hasPrefix("rollout-") {
                if let m = mtime(u), newest == nil || m > newest!.1 { newest = (u, m) }
            }
        }
        guard let (url, at) = newest, now.timeIntervalSince(at) <= freshFor, let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        var rl: [String: Any]?
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let p = o["payload"] as? [String: Any], let r = p["rate_limits"] as? [String: Any] { rl = r; break }
        }
        guard let rl else { return nil }
        var five: [String: Any]?, week: [String: Any]?
        for w in [rl["primary"], rl["secondary"]].compactMap({ $0 as? [String: Any] }) {
            switch (w["window_minutes"] as? NSNumber)?.intValue {
            case 300?: five = w
            case 10080?: week = w
            default: break
            }
        }
        guard five != nil || week != nil else { return nil }
        return StatusV1.Limit(agent: "codex", source: "session", at: Clock.iso(at),
                              fiveHour: number(five?["used_percent"]), week: number(week?["used_percent"]),
                              resetsFiveHour: epoch(five?["resets_at"]), resetsWeek: epoch(week?["resets_at"]))
    }

    func mtime(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
    func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    func epoch(_ v: Any?) -> String? { number(v).map { Clock.iso(Date(timeIntervalSince1970: $0)) } }
}

/// `shelf-runner limits-tee`: save the status line JSON, pass the same bytes on.
public enum LimitsTee {
    /// Atomic write; errors are swallowed so the user's status line never breaks.
    public static func save(_ data: Data, paths: Paths) {
        try? paths.ensureDirectories()
        try? data.write(to: LimitsReader.claudeFile(paths), options: .atomic)
    }

    /// `--show`: a short line for people without a status line of their own.
    public static func summary(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "shelf-runner" }
        let rl = root["rate_limits"] as? [String: Any]
        func pct(_ k: String) -> String? {
            ((rl?[k] as? [String: Any])?["used_percentage"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))%" }
        }
        var parts: [String] = []
        if let m = (root["model"] as? [String: Any])?["display_name"] as? String { parts.append(m) }
        if let f = pct("five_hour") { parts.append("5h \(f)") }
        if let w = pct("seven_day") { parts.append("week \(w)") }
        return parts.isEmpty ? "shelf-runner" : parts.joined(separator: " · ")
    }
}

/// `now` and `asking`: what a running job is doing, in one line.
public enum JobSummary {
    /// Prompt and TUI frame glyphs stripped from both ends.
    public static func clean(_ line: String) -> String {
        let junk = CharacterSet(charactersIn: "❯›>$%#⏺●•◦✻✶✳✢✽*·-=|+").union(.whitespaces)
        let s = line.unicodeScalars.filter { !(0x2500...0x259F).contains($0.value) }  // box drawing and blocks
        return String(String.UnicodeScalarView(s)).trimmingCharacters(in: junk)
    }

    /// TUI chrome that is never what the job is doing: Claude Code / Codex footers and hints.
    static let chrome = ["shift+tab to cycle", "? for shortcuts", "-- insert --", "esc to interrupt", "ctrl+c to exit",
                         "press ctrl-c again", "for agents", "/effort", "auto mode on", "context left"]

    /// Chrome only at the start of a line (glyphs stripped): "I worked for hours…" is a reply.
    static let chromeStarts = ["worked for "]

    static func isChrome(_ line: String) -> Bool {
        let l = line.lowercased()
        let start = clean(line).lowercased()
        return chrome.contains { l.contains($0) } || chromeStarts.contains { start.hasPrefix($0) }
    }

    /// A line drawn only with box-drawing characters (Claude Code's horizontal rules).
    static func isRule(_ line: String) -> Bool {
        line.unicodeScalars.count >= 10 && line.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// The screen without TUI furniture, in two cuts:
    /// 1. Claude Code's input box and the footer under it: a short block between the last two
    ///    rules that starts with the `❯` prompt. A question's option list also sits between rules,
    ///    but does not start with `❯` right after the rule.
    /// 2. The user's own status line: Claude Code draws it between its activity line and the
    ///    input box, 1-3 lines, and `-J` can interleave their columns. From the last activity line
    ///    down to the first rule or Claude Code content line, else to the end. No activity line,
    ///    no cut: a status line on a screen without one still shows (known limit).
    static func content(_ lines: [String]) -> [String] {
        var body = lines[...]
        let rules = lines.indices.filter { isRule(lines[$0]) }
        if rules.count >= 2 {
            let a = rules[rules.count - 2], b = rules[rules.count - 1]
            if b - a <= 4, a + 1 < b, lines[a + 1].hasPrefix("❯") || lines[a + 1].hasPrefix(">") { body = lines[..<a] }
        }
        guard let start = body.lastIndex(where: isActivity) else { return Array(body) }
        let end = body[(start + 1)...].firstIndex { isRule($0) || isContent($0) } ?? body.endIndex
        return Array(body[..<start] + body[end...])
    }

    /// Claude Code's activity line: a spinner glyph, a space, then "Worked for 34s · done 10:05 AM"
    /// or a verb with `…`, `(28s` or "esc to interrupt". `*` and `·` are also Markdown bullets, so
    /// a reply line like "* Waiting for CI…" must not cut what follows: after them only "Worked for"
    /// or "esc to interrupt" counts. A user status line that looks like this is taken for one
    /// (known limit; the last such line wins).
    static func isActivity(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        let u = Array(t.unicodeScalars.prefix(3))
        guard u.count == 3, "·✢✳✶✻✽*".unicodeScalars.contains(u[0]), u[1] == " ", !CharacterSet.whitespaces.contains(u[2])
        else { return false }
        let rest = String(String.UnicodeScalarView(t.unicodeScalars.dropFirst(2)))
        if rest.hasPrefix("Worked for") || t.lowercased().contains("esc to interrupt") { return true }
        return !"·*".unicodeScalars.contains(u[0]) && (t.contains("…") || t.contains(/\(\d+s\b/))
    }

    /// A line Claude Code itself drew below an activity line: tool output, a box, a prompt or a question.
    static func isContent(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if ["⏺", "●", "⎿", "│", "╭", "╰", "❯", "›"].contains(where: { t.hasPrefix($0) }) { return true }
        let l = t.lowercased()
        return clean(t).hasSuffix("?") || prompts.contains { l.contains($0) }
    }

    /// Key hints under a dialog ("Enter to select · Esc to cancel"): never the summary, but they
    /// still count for `asking`.
    static let hints = ["enter to select", "enter to confirm", "esc to cancel", "tab/arrow keys"]

    static func isHint(_ line: String) -> Bool {
        let l = line.lowercased()
        return hints.contains { l.contains($0) }
    }

    /// The lines `now` and the status `log` may show: no input box, chrome, rules or key hints.
    public static func meaningful(_ lines: [String]) -> [String] {
        content(lines).filter { !isChrome($0) && !isRule($0) && !isHint($0) }
    }

    /// A question among the last 12 lines wins (Shelf shows it as "Asking you: …"); otherwise the
    /// last line with a letter or digit. At most 120 characters.
    public static func now(_ lines: [String]) -> String? {
        let shown = meaningful(lines)
        if let q = shown.suffix(12).last(where: { clean($0).hasSuffix("?") }) {
            return String(clean(q).prefix(StatusV1.maxNowChars))
        }
        for l in shown.reversed() {
            let c = clean(l)
            if c.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                return String(c.prefix(StatusV1.maxNowChars))
            }
        }
        return nil
    }

    /// Approval prompts of Claude Code (folder trust, tool permission) and Codex, lower case.
    static let prompts = ["(y/n)", "[y/n]", "(yes/no)", "do you want", "do you trust", "trust this folder", "allow ", "approve",
                          "❯ 1.", "› 1.", "1. yes", "yes, proceed", "enter to confirm", "enter to select", "esc to cancel", "would you like", "press enter", "continue?"]

    /// Lines looked at from the end: a TUI prompt sits above its option list and footer.
    static let promptLines = 6

    /// Attended, silent for 60 s, and one of the last lines (chrome skipped) is a question or an
    /// approval prompt (the folder-trust screen ends in its options, not a `?`).
    public static func asking(mode: String, state: String, lines: [String], quietFor: TimeInterval) -> Bool {
        guard mode == "attended", JobState.active.contains(state), quietFor >= 60 else { return false }
        let tail = content(lines).filter { !isChrome($0) }.suffix(promptLines)
        guard let last = tail.last else { return false }
        if clean(last).hasSuffix("?") { return true }
        return tail.contains { l in let l = l.lowercased(); return prompts.contains { l.contains($0) } }
    }
}
