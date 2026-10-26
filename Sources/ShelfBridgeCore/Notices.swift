import Foundation

/// What a notification is for; also its id prefix (`ask:<jobid>`). One notification per job and
/// kind: a newer one replaces the older instead of stacking.
public enum NoticeKind: String, Sendable, CaseIterable {
    /// First run: Run / Ignore.
    case approve
    /// Something happened to the job: failed, missed, limit wait over.
    case info
    /// An attended job asks the user something.
    case ask

    public func identifier(job id: String) -> String { "\(rawValue):\(id)" }

    /// The job id inside a notification id, `nil` for one Bridge did not post.
    public static func job(fromIdentifier ident: String) -> String? {
        for k in allCases where ident.hasPrefix(k.rawValue + ":") {
            let id = String(ident.dropFirst(k.rawValue.count + 1))
            return JobID.isValid(id) ? id : nil
        }
        return nil
    }
}

public struct Notice: Equatable, Sendable {
    public var id: String
    public var kind: NoticeKind
    public var title: String
    public var body: String
}

/// The notices that call the user back to a job (a question, a failure). Edge-triggered:
/// the watch remembers what it last saw per job, in memory, for the life of the agent.
public struct NoticeWatch: Sendable {
    /// Status and occurrence per job id from the last pass; `nil` until the first pass, which
    /// only records (a restart does not re-announce old failures).
    var seen: [String: String]?
    /// `asking` per job id from the last status. Empty after a restart: a job still asking is
    /// announced once more.
    var asking: [String: Bool] = [:]

    public init() {}

    /// A job that entered any `failed:` status since the last pass (not `cancelled`), once.
    /// `records` are all records (a disabled folder's too, so enabling it again is not news);
    /// only `folders` get notices. `titles` fills in for records written before titles were kept.
    public mutating func failures(_ records: [String: RunRecord], folders: Set<String>, titles: [String: String] = [:],
                                  maxRuntime: TimeInterval) -> [Notice] {
        let now = records.mapValues { "\($0.status)@\($0.occurrence ?? "")" }
        defer { seen = now }
        guard let seen else { return [] }
        return records.values.sorted { $0.id < $1.id }.compactMap { r in
            guard folders.contains(r.folder), seen[r.id] != now[r.id],
                  let body = NoticeText.failed(r.status, limit: Supervisor.duration(maxRuntime)) else { return nil }
            return Notice(id: r.id, kind: .info, title: NoticeText.title(r.title ?? titles[r.id] ?? r.id), body: body)
        }
    }

    /// A job whose `asking` turned true since the last status, once; again only after it was
    /// false. `asking` is already mode-aware (attended, active, quiet 60 s; `JobSummary.asking`).
    public mutating func questions(_ jobs: [StatusV2.Job]) -> [Notice] {
        var next: [String: Bool] = [:]
        var out: [Notice] = []
        for j in jobs {
            if j.asking && asking[j.id] != true {
                out.append(Notice(id: j.id, kind: .ask, title: NoticeText.title(j.title),
                                  body: NoticeText.asking(agent: j.agent, folder: j.folder, now: j.now)))
            }
            next[j.id] = j.asking
        }
        asking = next
        return out
    }
}

/// Clicking a Bridge notification (not its Run / Ignore buttons): Shelf Bench when it is
/// installed, else Shelf, else nothing.
public enum NoticeClick: Equatable {
    case openDesk(URL)
    case openShelf
    case nothing

    public static let deskScheme = "shelfbench"
    /// Shelf has no URL scheme: the app is opened.
    public static let shelfBundleID = "dev.ted2xmen.shelf"

    public static func deskURL(job id: String?) -> URL {
        URL(string: id.flatMap { JobID.isValid($0) ? "\(deskScheme)://job/\($0)" : nil } ?? "\(deskScheme)://")!
    }

    public static func decide(job id: String?, deskInstalled: Bool, shelfInstalled: Bool) -> NoticeClick {
        if deskInstalled { return .openDesk(deskURL(job: id)) }
        return shelfInstalled ? .openShelf : .nothing
    }
}
