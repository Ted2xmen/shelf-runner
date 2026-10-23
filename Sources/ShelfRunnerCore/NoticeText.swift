import Foundation

/// macOS notification texts: macOS already shows "ShelfRunner" above them, so no prefix;
/// the title is the task, the body one short line of what happened.
public enum NoticeText {
    /// Long titles are cut so the banner stays one line.
    static let maxTitle = 60

    public static func title(_ task: String) -> String {
        let t = task.trimmingCharacters(in: .whitespaces)
        return t.count > maxTitle ? String(t.prefix(maxTitle - 1)) + "…" : t
    }

    /// "Claude · SHELF-TEST", plus "unattended" and the schedule when there is one.
    public static func approval(agent: String, folder: String, unattended: Bool, schedule: String?) -> String {
        var parts = [name(agent), (folder as NSString).lastPathComponent]
        if unattended { parts.append("unattended") }
        if let schedule { parts.append(schedule) }
        return parts.joined(separator: " · ")
    }

    static func name(_ agent: String) -> String { agent.prefix(1).uppercased() + agent.dropFirst() }

    /// The question shown under the body, at most this long.
    static let maxQuestion = 100

    /// "Claude is asking · SHELF-TEST", and on a second line the question when `now` is one.
    public static func asking(agent: String, folder: String, now: String?) -> String {
        let head = "\(name(agent)) is asking · \((folder as NSString).lastPathComponent)"
        guard let q = now?.trimmingCharacters(in: .whitespaces), q.hasSuffix("?") else { return head }
        return head + "\n" + (q.count > maxQuestion ? String(q.prefix(maxQuestion - 1)) + "…" : q)
    }

    /// The body for a `failed:` status; `nil` for any other status. `limit`: the time limit
    /// for `failed:timeout`, as `timedOut` writes it.
    public static func failed(_ status: String, limit: String) -> String? {
        guard status.hasPrefix("failed:") else { return nil }
        let why = String(status.dropFirst("failed:".count))
        switch why {
        case "timeout": return timedOut(after: limit)
        case "lost": return "Lost while the runner restarted"
        case "start": return "Could not start"
        case "path": return "Not started: ref: or out: is outside the folder"
        default: return Int32(why).map { "Stopped with exit code \($0)" } ?? "Stopped: \(why)"
        }
    }

    public static func timedOut(after limit: String) -> String { "Stopped at the \(limit) limit" }
    public static func limitWaitOver(after wait: String) -> String { "Started after a \(wait) limit wait" }
    /// The missed occurrence as "Oct 23, 09:00", in English whatever the Mac's language, in the
    /// Mac's time zone.
    public static func missed(_ at: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "MMM d, HH:mm"
        return "Missed the \(f.string(from: at)) run: the runner was off"
    }
}
