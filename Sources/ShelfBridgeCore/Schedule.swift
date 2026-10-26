import Foundation

/// When a `SCHEDULED.md` line runs: `due:` anchors the series, `at:` is local
/// wall time, `every:` the step. Raw strings are kept: the signature is over them.
public struct Schedule: Equatable, Sendable {
    public enum Every: String, Sendable, CaseIterable { case day, week, month, year }

    /// `yyyy-MM-dd`
    public var due: String
    /// `HH:MM`; none = the start of the day.
    public var at: String?
    public var every: Every?

    var dueParts: DateComponents? {
        let p = due.split(separator: "-").compactMap { Int($0) }
        guard due.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil, p.count == 3 else { return nil }
        let c = DateComponents(year: p[0], month: p[1], day: p[2])
        // Real calendar day only: 2026-02-30 is not one.
        guard let d = Self.days.date(from: c), Self.days.dateComponents([.year, .month, .day], from: d) == c else { return nil }
        return c
    }

    var atParts: (hour: Int, minute: Int)? {
        guard let at else { return (0, 0) }
        guard at.wholeMatch(of: /[0-9]{2}:[0-9]{2}/) != nil else { return nil }
        let p = at.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) else { return nil }
        return (p[0], p[1])
    }

    /// Day arithmetic without time zones or DST: the series is whole days (Shelf Recur).
    static let days: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The series' days, `x0 = due`, `x(n+1) = x(n) + 1 step`; a month or year step clamps to the
    /// target month's last day and the clamp is never undone (Shelf Recur: Jan 31, Feb 28, Mar 28).
    func step(_ day: Date) -> Date? {
        switch every {
        case nil: return nil
        case .day?: return Self.days.date(byAdding: .day, value: 1, to: day)
        case .week?: return Self.days.date(byAdding: .day, value: 7, to: day)
        case .month?: return Self.days.date(byAdding: .month, value: 1, to: day)
        case .year?: return Self.days.date(byAdding: .month, value: 12, to: day)
        }
    }

    /// A series day at `at:` in the local time zone.
    func instant(_ day: Date, calendar: Calendar) -> Date? {
        guard let t = atParts else { return nil }
        var c = Self.days.dateComponents([.year, .month, .day], from: day)
        c.hour = t.hour; c.minute = t.minute
        return calendar.date(from: c)
    }

    /// Whether a stored occurrence is the series occurrence at `instant`. Compared by local wall
    /// clock (`yyyy-MM-ddTHH:mm`), not by instant: `at:09:00` is still the same occurrence after
    /// the Mac changes time zone, so it neither runs twice nor reads as missed.
    public static func isSame(_ stored: String?, _ instant: Date?, in zone: TimeZone = .current) -> Bool {
        guard let stored, let instant else { return false }
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return stored.prefix(16) == f.string(from: instant).prefix(16)
    }

    /// The latest occurrence at or before `now` and the first one after it.
    public func around(_ now: Date, calendar: Calendar = .current) -> (last: Date?, next: Date?) {
        guard let c = dueParts, var day = Self.days.date(from: c) else { return (nil, nil) }
        var last: Date?
        // Days and weeks jump close to `now` instead of walking (no clamp to preserve).
        if let every, every == .day || every == .week, let first = instant(day, calendar: calendar), first < now {
            let length = every == .day ? 1 : 7
            let n = max(0, Int(now.timeIntervalSince(first) / 86400) / length - 1)
            day = Self.days.date(byAdding: .day, value: n * length, to: day) ?? day
        }
        while let t = instant(day, calendar: calendar) {
            if t > now { return (last, t) }
            last = t
            guard let next = step(day) else { return (last, nil) }
            day = next
        }
        return (last, nil)
    }
}

/// `SCHEDULED.md`: the queue's closed keys plus `due:`, `at:`, `every:`; items are
/// unboxed (`- title …`); only `mode:unattended`.
public enum ScheduledGrammar {
    public static let fileName = "SCHEDULED.md"
    public static let keys = QueueGrammar.keys.union(["due", "at", "every"])

    static var itemPattern: Regex<(Substring, Substring)> { /^- (?!\[[ xX]\] )(.*)$/ }

    public static func parse(_ text: String) -> QueueFile {
        var lines = text.components(separatedBy: "\n")
        if !text.hasSuffix("\n") { lines.removeLast() }
        var items: [QueueItem] = [], invalid: [InvalidQueueLine] = []
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

    /// `nil` for a bullet with none of the keys: a plain note, not a scheduled item.
    public static func parseLine(_ text: String, line: Int = 1) -> Result<QueueItem, QueueLineError>? {
        guard let m = text.wholeMatch(of: itemPattern) else { return nil }
        var values: [String: String] = [:]
        var titleWords: [Substring] = []
        var sawKey = false
        var failure: QueueLineError?
        for token in m.1.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let colon = token.firstIndex(of: ":"), keys.contains(String(token[..<colon])) else {
                titleWords.append(token)
                continue
            }
            sawKey = true
            let key = String(token[..<colon]), value = String(token[token.index(after: colon)...])
            if failure == nil, value.isEmpty { failure = .emptyValue(key) }
            if failure == nil, values[key] != nil { failure = .duplicateKey(key) }
            values[key] = value
        }
        guard sawKey else { return nil }
        if let failure { return .failure(failure) }
        guard let id = values["id"] else { return .failure(.missingKey("id")) }
        guard ScheduledID.isValid(id) else { return .failure(.badValue(key: "id", value: id)) }
        guard let agentRaw = values["agent"] else { return .failure(.missingKey("agent")) }
        guard let agent = QueueItem.Agent(rawValue: agentRaw) else { return .failure(.badValue(key: "agent", value: agentRaw)) }
        guard let modeRaw = values["mode"] else { return .failure(.missingKey("mode")) }
        guard modeRaw == QueueItem.Mode.unattended.rawValue else { return .failure(.badValue(key: "mode", value: modeRaw)) }
        guard let due = values["due"] else { return .failure(.missingKey("due")) }
        var every: Schedule.Every?
        if let e = values["every"] {
            guard let v = Schedule.Every(rawValue: e) else { return .failure(.badValue(key: "every", value: e)) }
            every = v
        }
        let schedule = Schedule(due: due, at: values["at"], every: every)
        guard schedule.dueParts != nil else { return .failure(.badValue(key: "due", value: due)) }
        if let at = values["at"], schedule.atParts == nil { return .failure(.badValue(key: "at", value: at)) }
        if let ref = values["ref"], ref.wholeMatch(of: QueueGrammar.refPattern) == nil { return .failure(.badValue(key: "ref", value: ref)) }
        if let sig = values["sig"], sig.wholeMatch(of: QueueGrammar.sigPattern) == nil { return .failure(.badValue(key: "sig", value: sig)) }
        let title = titleWords.joined(separator: " ")
        if title.isEmpty { return .failure(.missingKey("title")) }
        return .success(QueueItem(id: id, title: title, checked: false, agent: agent, mode: .unattended,
                                  ref: values["ref"], out: values["out"], by: values["by"], sig: values["sig"], line: line,
                                  schedule: schedule))
    }
}
