import Foundation

/// Limits from `config.toml [runner]`.
public struct Policy: Equatable, Sendable {
    public var maxRuntime: TimeInterval = 2 * 3600
    public var stallAfter: TimeInterval = 6 * 60
    public var cancelGrace: TimeInterval = 60
    public var maxParallel = 2
    public var perFolder = 1
    public var dailyJobs = 20
    /// `config.toml [resources]`: under `diskWaitGB` a job starts only on an idle
    /// machine, under `diskStopGB` none does (same shape as memory warn / critical).
    public var diskWaitGB = 10
    public var diskStopGB = 5
    public var batteryMinPercent = 20
    public var limitPercent = 90
    /// A limit hold ends after this; the job then starts with a notification.
    public var limitMaxWait: TimeInterval = 90 * 60
    /// A scheduled occurrence first seen later than this after its time is `missed`.
    public var missedAfter: TimeInterval = 60 * 60

    public init() {}
}

/// The machine at plan time. An unknown reading (`nil`, missing, stale limit) never holds a job.
public struct Resources: Equatable, Sendable {
    public var mac: StatusV1.Mac?
    /// Free GB on each enabled folder's volume; the startup disk is `mac.diskFreeGB`.
    public var folderDiskGB: [String: Double]
    /// Fresh values only (15 minutes).
    public var limits: [StatusV1.Limit]

    public init(mac: StatusV1.Mac? = nil, folderDiskGB: [String: Double] = [:], limits: [StatusV1.Limit] = []) {
        self.mac = mac; self.folderDiskGB = folderDiskGB; self.limits = limits
    }
}

/// Why a job was asked to stop; a file in the state dir so `wrap` and a restarted agent see it.
public struct StopMarker: Codable, Equatable, Sendable {
    /// Final status to record: `cancelled` or `failed:timeout`.
    public var reason: String
    public var requestedAt: Date
    /// Last Ctrl-C sent for it; a repeated `stop` presses again. `nil` = `requestedAt`.
    public var signalledAt: Date? = nil

    /// A clean exit (0) counts as caused by the stop only this soon after the last key press;
    /// later, the user ended it (`/exit`) and it is `done`. A non-zero exit or a signal after a stop
    /// request always keeps the stop's reason: a slow shutdown is still a cancel or a timeout.
    public static let causalWindow: TimeInterval = 10

    public func caused(exitAt: Date, exitCode: Int32) -> Bool {
        exitCode != 0 || exitAt.timeIntervalSince(signalledAt ?? requestedAt) <= Self.causalWindow
    }
}

/// What the agent saw of a live job's tmux window just before planning.
public struct JobObservation: Equatable, Sendable {
    public var windowAlive: Bool
    public var logModified: Date?
    /// The live pane's text; `nil` when the window is gone or tmux could not read it.
    public var screen: [String]? = nil
}

public enum JobState {
    public static let active: Set<String> = ["running", "stalled"]
    /// Runner-internal (never in the status JSON): a scheduled job approved and waiting for its
    /// next occurrence. Counts as final: not active, not pending.
    public static let scheduled = "scheduled"
    public static func isPending(_ s: String) -> Bool { s == "queued" || s == "needs-approval" || s.hasPrefix("waiting:") }
    public static func isFinal(_ s: String) -> Bool { !active.contains(s) && !isPending(s) }
}

public enum Action: Equatable {
    /// `occurrence`: the scheduled occurrence this start is for.
    case start(QueueItem, folder: String, occurrence: String? = nil)
    /// Appends a record copying the latest one with a new status; final statuses get `endedAt`.
    /// A non-nil `occurrence` claims that scheduled occurrence; nil keeps the record's.
    case setStatus(id: String, status: String, occurrence: String? = nil)
    /// Writes the stop marker and sends Ctrl-C to the window.
    case interrupt(id: String, window: String, reason: String)
    /// Grace is over: closes the window and records the marker's reason.
    case kill(id: String, window: String, reason: String)
    case notify(id: String, title: String, body: String)
}

public struct Snapshot {
    public var enabledFolders: [String]
    /// `nil` = file missing or unreadable: nothing in that folder is cancelled because of it.
    public var queues: [String: QueueFile?]
    /// `SCHEDULED.md` per folder, same `nil` rule.
    public var schedules: [String: QueueFile?] = [:]
    public var records: [String: RunRecord]
    public var markers: [String: StopMarker]
    public var observations: [String: JobObservation]
    public var now: Date
    /// `pause`: no new starts (`waiting:paused`); running jobs carry on.
    public var paused = false
    /// Empty by default: no readings, no resource holds.
    public var resources = Resources()

    public init(enabledFolders: [String], queues: [String: QueueFile?], records: [String: RunRecord],
                markers: [String: StopMarker] = [:], observations: [String: JobObservation] = [:], now: Date) {
        self.enabledFolders = enabledFolders; self.queues = queues; self.records = records
        self.markers = markers; self.observations = observations; self.now = now
    }
}

/// Pure decisions: snapshot in, actions out.
public struct Supervisor {
    public var policy: Policy
    /// Start gate; `nil` lets every line through (tests).
    public var gate: ((QueueItem, String, RunRecord?) -> GateResult)?

    public enum GateResult: Equatable { case pass, hold(String) }

    public init(policy: Policy, gate: ((QueueItem, String, RunRecord?) -> GateResult)? = nil) {
        self.policy = policy
        self.gate = gate
    }

    static func duration(_ t: TimeInterval) -> String {
        t >= 3600 && Int(t) % 3600 == 0 ? "\(Int(t) / 3600) h" : t >= 60 ? "\(Int(t) / 60) min" : "\(Int(t)) s"
    }

    public func plan(_ s: Snapshot) -> [Action] {
        var actions: [Action] = []
        let enabled = Set(s.enabledFolders)
        func line(_ r: RunRecord) -> (readable: Bool, item: QueueItem?) {
            let files = ScheduledID.isValid(r.id) ? s.schedules : s.queues
            guard let q = files[r.folder], let file = q else { return (false, nil) }
            return (true, file.item(id: r.id))
        }

        var activeTotal = 0
        var activePerFolder: [String: Int] = [:]

        for r in s.records.values.sorted(by: { $0.id < $1.id }) where enabled.contains(r.folder) {
            let (readable, item) = line(r)
            let gone = readable && (item == nil || item!.checked)

            if JobState.active.contains(r.status) {
                let window = r.tmuxWindow ?? ""
                let obs = s.observations[r.id]
                if let obs, !obs.windowAlive {
                    // wrap records before it exits, so a dead window with an active record lost wrap.
                    actions.append(.setStatus(id: r.id, status: s.markers[r.id]?.reason ?? "failed:lost"))
                    continue
                }
                activeTotal += 1
                activePerFolder[r.folder, default: 0] += 1
                if let m = s.markers[r.id] {
                    if s.now.timeIntervalSince(m.requestedAt) >= policy.cancelGrace {
                        actions.append(.kill(id: r.id, window: window, reason: m.reason))
                    }
                    continue
                }
                if gone {
                    actions.append(.interrupt(id: r.id, window: window, reason: "cancelled"))
                    continue
                }
                let started = r.startedAt.flatMap(ISO.parse) ?? s.now
                if s.now.timeIntervalSince(started) >= policy.maxRuntime {
                    // The notice comes when `failed:timeout` is recorded: one per failure.
                    actions.append(.interrupt(id: r.id, window: window, reason: "failed:timeout"))
                    continue
                }
                let lastOutput = max(obs?.logModified ?? started, started)
                // Print mode is silent until it ends: only attended jobs are `stalled`.
                let quiet = r.mode == QueueItem.Mode.attended.rawValue && s.now.timeIntervalSince(lastOutput) >= policy.stallAfter
                if quiet && r.status == "running" { actions.append(.setStatus(id: r.id, status: "stalled")) }
                if !quiet && r.status == "stalled" { actions.append(.setStatus(id: r.id, status: "running")) }
            } else if JobState.isPending(r.status) && gone {
                actions.append(.setStatus(id: r.id, status: "cancelled"))
            }
        }

        let startsToday = s.records.values.filter { r in
            r.startedAt.flatMap(ISO.parse).map { Calendar.current.isDate($0, inSameDayAs: s.now) } ?? false
        }.count
        var started = 0

        /// Shared by queue and scheduled lines: pause, daily, slots, resources, then start.
        func admit(_ item: QueueItem, folder: String, _ r: RunRecord?, occurrence: String?) {
            func hold(_ status: String) {
                if r?.status != status { actions.append(.setStatus(id: item.id, status: status, occurrence: occurrence)) }
            }
            if s.paused { hold("waiting:paused"); return }
            if startsToday + started >= policy.dailyJobs { hold("waiting:daily"); return }
            guard activeTotal < policy.maxParallel else { hold("waiting:slot"); return }
            guard activePerFolder[folder, default: 0] < policy.perFolder else { hold("waiting:folder"); return }
            // Resources come after the slot checks so a job that was let through on the limit
            // ceiling is not sent back to `waiting:slot` and then to a fresh 90 minutes.
            if let why = resourceHold(item, folder: folder, busy: activeTotal > 0, s.resources) {
                let since = r?.status == "waiting:limit" ? r?.waitingSince.flatMap(ISO.parse) : nil
                guard why == "limit", let since, s.now.timeIntervalSince(since) >= policy.limitMaxWait else {
                    hold("waiting:\(why)"); return
                }
                actions.append(.notify(id: item.id, title: NoticeText.title(item.title),
                                       body: NoticeText.limitWaitOver(after: Self.duration(policy.limitMaxWait))))
            }
            actions.append(.start(item, folder: folder, occurrence: occurrence))
            activeTotal += 1
            activePerFolder[folder, default: 0] += 1
            started += 1
        }

        for folder in s.enabledFolders {
            guard let q = s.queues[folder], let file = q else { continue }
            for item in file.items where !item.checked {
                let r = s.records[item.id]
                if let r, !JobState.isPending(r.status) { continue }  // active or final: not a candidate
                if let gate, case .hold(let why) = gate(item, folder, r) {
                    if r?.status != why { actions.append(.setStatus(id: item.id, status: why)) }
                    continue
                }
                admit(item, folder: folder, r, occurrence: nil)
            }
        }

        // Scheduled lines: approval when the line is first seen, then one run per occurrence.
        for folder in s.enabledFolders {
            guard let q = s.schedules[folder], let file = q else { continue }
            for item in file.items {
                let r = s.records[item.id]
                if let r, JobState.active.contains(r.status) { continue }
                guard let schedule = item.schedule else { continue }
                let lastAt = schedule.around(s.now).last
                let last = lastAt.map(Clock.iso)
                let claimed = Schedule.isSame(r?.occurrence, lastAt)
                // This occurrence is over (done, failed, missed, cancelled): nothing can bring it back,
                // a gate hold included, or the next pass of the gate would run it again.
                if let r, claimed, JobState.isFinal(r.status), r.status != JobState.scheduled { continue }
                if let gate, case .hold(let why) = gate(item, folder, r) {
                    if r?.status != why { actions.append(.setStatus(id: item.id, status: why)) }
                    continue
                }
                let pending = r.map { JobState.isPending($0.status) } ?? false
                if let last, !claimed {
                    // A new occurrence. Seen too late (the Mac was off or asleep): missed, not run.
                    // Only after the line was known: one created after its own `due:` time starts at the next.
                    if let t = ISO.parse(last), s.now.timeIntervalSince(t) > policy.missedAfter {
                        let known = r?.occurrence != nil || r.flatMap { ISO.parse($0.at) }.map { $0 < t } == true
                        guard known else {
                            if r?.status != JobState.scheduled { actions.append(.setStatus(id: item.id, status: JobState.scheduled)) }
                            continue
                        }
                        actions.append(.setStatus(id: item.id, status: "missed", occurrence: last))
                        actions.append(.notify(id: item.id, title: NoticeText.title(item.title),
                                               body: NoticeText.missed(t)))
                        continue
                    }
                    admit(item, folder: folder, r, occurrence: last)
                } else if pending && claimed {
                    admit(item, folder: folder, r, occurrence: last)  // still waiting to start this occurrence
                } else if r == nil || pending {
                    // Approved, nothing due: out of `jobs`, listed under `scheduled`.
                    if r?.status != JobState.scheduled { actions.append(.setStatus(id: item.id, status: JobState.scheduled)) }
                }
            }
        }
        return actions
    }

    /// The first resource that holds a new start, as a `waiting:` reason.
    /// `busy` = a job is already running on the machine.
    func resourceHold(_ item: QueueItem, folder: String, busy: Bool, _ res: Resources) -> String? {
        let mac = res.mac
        switch mac?.memory {
        case "critical"?: return "memory"
        case "warn"? where busy: return "memory"
        default: break
        }
        if let free = [mac?.diskFreeGB, res.folderDiskGB[folder]].compactMap({ $0 }).min(),
           free < Double(policy.diskStopGB) || (free < Double(policy.diskWaitGB) && busy) { return "disk" }
        if let b = mac?.battery {
            if b == "lowpower" { return "battery" }
            if b.hasPrefix("battery:"), let pct = Int(b.dropFirst(8)), pct < policy.batteryMinPercent { return "battery" }
        }
        if mac?.thermal == "serious" || mac?.thermal == "critical" { return "thermal" }
        if let used = res.limits.first(where: { $0.agent == item.agent.rawValue })?.fiveHour,
           used >= Double(policy.limitPercent) { return "limit" }
        return nil
    }
}

public enum ISO {
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
