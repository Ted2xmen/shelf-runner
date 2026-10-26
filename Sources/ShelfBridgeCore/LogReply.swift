import Foundation

/// The answer to `cmd.log.<id>`: the job's plain-text log tail for Shelf's job window.
public struct LogReply: Codable, Equatable, Sendable {
    public var id: String
    public var at: String
    public var state: String
    public var lines: [String]
    /// Older lines exist that are not here, or a line was shortened.
    public var truncated: Bool
    /// Optional colours: one `[[start,len,fg,bg,flags]]` per line,
    /// `[]` for a plain line. Encoded only when present; old answers without it still decode.
    public var styles: [[[Int]]]?

    public static let maxLines = 200
    public static let maxLineChars = 400
    /// The whole JSON text, what travels in `userInfo`.
    public static let maxBytes = 16 * 1024
    /// Bytes read from the end of the log file; a TUI log is mostly escape sequences.
    static let readBytes: UInt64 = 512 * 1024

    public init(id: String, at: String, state: String, lines: [String], truncated: Bool, styles: [[[Int]]]? = nil) {
        self.id = id; self.at = at; self.state = state; self.lines = lines; self.truncated = truncated; self.styles = styles
    }

    /// `text` is the raw end of the log; `partial` = it does not start at the file start.
    public static func make(id: String, state: String, at: String, text: String, partial: Bool) -> LogReply {
        var all = LogTail.allLines(text)
        // A read that starts mid-file starts mid-line.
        if partial, !all.isEmpty { all.removeFirst() }
        return make(id: id, state: state, at: at, lines: all, partial: partial)
    }

    /// Plain lines (a live pane capture or a stripped log), oldest first. `styles`, if given, is
    /// parallel to `all` (`AnsiText.parse`); it never changes `lines` or `truncated`.
    public static func make(id: String, state: String, at: String, lines all: [String],
                            styles: [[AnsiText.Run]]? = nil, partial: Bool) -> LogReply {
        var truncated = partial || all.count > maxLines
        var lines = all.suffix(maxLines).map { l -> String in
            guard l.count > maxLineChars else { return l }
            truncated = true
            return String(l.prefix(maxLineChars))
        }
        var reply = LogReply(id: id, at: at, state: state, lines: lines, truncated: truncated)
        // Drop the oldest lines until the JSON fits; estimate first, then check exactly.
        var size = reply.byteCount
        while size > maxBytes, !lines.isEmpty {
            let excess = size - maxBytes
            var drop = 0, freed = 0
            while drop < lines.count - 1, freed < excess { freed += lines[drop].utf8.count + 3; drop += 1 }
            lines.removeFirst(max(drop, 1))
            reply.lines = lines
            reply.truncated = true
            size = reply.byteCount
        }
        guard let styles, styles.count == all.count else { return reply }
        // The 400 cut is by Character (as `lines` always was); runs are clipped to the scalars it kept.
        let kept = zip(lines, styles.suffix(lines.count)).map { line, runs in
            AnsiText.clip(runs, to: line.unicodeScalars.count).map(\.array)
        }
        return fitStyles(reply, kept)
    }

    /// `styles` after `lines` fit: over 16 KB, the oldest lines' runs become `[]`; if even
    /// that does not fit, or no line has a run, the field is left out.
    static func fitStyles(_ base: LogReply, _ styles: [[[Int]]]) -> LogReply {
        var reply = base
        var styles = styles
        var size = Int.max
        var next = 0
        while true {
            guard styles.contains(where: { !$0.isEmpty }) else { return base }
            reply.styles = styles
            size = reply.byteCount
            if size <= maxBytes { return reply }
            // Blank just enough of the oldest lines (exact JSON length of their runs), then check.
            var freed = 0
            while next < styles.count, freed < size - maxBytes {
                freed += styles[next].reduce(0) { $0 + 2 + $1.map { String($0).count + 1 }.reduce(0, +) }
                styles[next] = []
                next += 1
            }
        }
    }

    /// A live job answers with its pane (`screen`); otherwise the job's log file, if it started.
    /// `styles` (parallel to `screen`) only for a live pane captured with `-e`.
    public static func build(_ r: RunRecord, screen: [String]? = nil, styles: [[AnsiText.Run]]? = nil, now: Date = Date()) -> LogReply {
        if let screen { return make(id: r.id, state: r.status, at: Clock.iso(now), lines: screen, styles: styles, partial: false) }
        var text = "", partial = false
        if r.startedAt != nil, let path = r.logPath, let h = FileHandle(forReadingAtPath: path) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            partial = size > readBytes
            try? h.seek(toOffset: partial ? size - readBytes : 0)
            text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        }
        return make(id: r.id, state: r.status, at: Clock.iso(now), text: text, partial: partial)
    }

    var byteCount: Int { ((try? json()) ?? "").utf8.count }

    public func json(pretty: Bool = false) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }
}
