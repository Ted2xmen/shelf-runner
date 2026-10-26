import Foundation

/// The protocol v2 status JSON. Unknown values are written as explicit `null`, never omitted.
public struct StatusV2: Codable, Equatable, Sendable {
    public var v: Int = ProtocolV2.version
    public var bridge: String
    public var seen: String
    public var keyId: String?
    public var paused: Bool
    public var slots: Slots
    public var mac: Mac
    public var limits: [Limit]
    public var folders: [String]
    public var jobs: [Job]
    public var scheduled: [Scheduled]

    /// Machine limit, per-folder limit, running now.
    public struct Slots: Codable, Equatable, Sendable {
        public var max: Int
        public var perFolder: Int
        public var running: Int
        public init(max: Int, perFolder: Int, running: Int) { self.max = max; self.perFolder = perFolder; self.running = running }
    }

    public struct Mac: Codable, Equatable, Sendable {
        /// `normal` | `warn` | `critical`
        public var memory: String?
        public var diskFreeGB: Double?
        /// `charging` (on AC, desktops included) | `battery:<percent>` | `lowpower`
        public var battery: String?
        /// `nominal` | `fair` | `serious` | `critical`
        public var thermal: String?

        public init(memory: String?, diskFreeGB: Double?, battery: String?, thermal: String?) {
            self.memory = memory; self.diskFreeGB = diskFreeGB; self.battery = battery; self.thermal = thermal
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(memory, forKey: .memory); try c.encode(diskFreeGB, forKey: .diskFreeGB)
            try c.encode(battery, forKey: .battery); try c.encode(thermal, forKey: .thermal)
        }
    }

    public struct Limit: Codable, Equatable, Sendable {
        public var agent: String
        /// `statusline` (claude) | `session` (codex rollout)
        public var source: String
        public var at: String
        public var fiveHour: Double?
        public var week: Double?
        public var resetsFiveHour: String?
        public var resetsWeek: String?

        public init(agent: String, source: String, at: String, fiveHour: Double?, week: Double?,
                    resetsFiveHour: String?, resetsWeek: String?) {
            self.agent = agent; self.source = source; self.at = at; self.fiveHour = fiveHour; self.week = week
            self.resetsFiveHour = resetsFiveHour; self.resetsWeek = resetsWeek
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(agent, forKey: .agent); try c.encode(source, forKey: .source); try c.encode(at, forKey: .at)
            try c.encode(fiveHour, forKey: .fiveHour); try c.encode(week, forKey: .week)
            try c.encode(resetsFiveHour, forKey: .resetsFiveHour); try c.encode(resetsWeek, forKey: .resetsWeek)
        }
    }

    public struct Job: Codable, Equatable, Sendable {
        public var id: String
        public var folder: String
        public var ref: String?
        public var title: String
        public var agent: String
        public var mode: String
        public var state: String
        public var started: String?
        public var ended: String?
        /// `<session>:<window name>`
        public var tmux: String?
        /// One-line summary of the log, at most 120 characters.
        public var now: String?
        /// Attended job waiting for input.
        public var asking: Bool
        /// Only while `state` is `waiting:<reason>`.
        public var waitingSince: String?
        public var waitMaxMin: Int?
        /// At most 3 lines of at most 200 characters.
        public var log: [String]
        public var out: String?
        /// When Terminal was opened on the job's window (last `attach`).
        public var attached: String?
        /// `no-session` when the last `attach` found no tmux session.
        public var attachError: String?
        /// Unattended Claude's permission denials; `null` for attended jobs, Codex and unknown.
        public var blocked: Int?

        public init(id: String, folder: String, ref: String?, title: String, agent: String, mode: String, state: String,
                    started: String?, ended: String?, tmux: String?, now: String? = nil, asking: Bool = false,
                    waitingSince: String? = nil, waitMaxMin: Int? = nil, log: [String], out: String?,
                    attached: String? = nil, attachError: String? = nil, blocked: Int? = nil) {
            self.id = id; self.folder = folder; self.ref = ref; self.title = title; self.agent = agent; self.mode = mode
            self.state = state; self.started = started; self.ended = ended; self.tmux = tmux; self.now = now; self.asking = asking
            self.waitingSince = waitingSince; self.waitMaxMin = waitMaxMin; self.log = log; self.out = out
            self.attached = attached; self.attachError = attachError; self.blocked = blocked
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(folder, forKey: .folder); try c.encode(ref, forKey: .ref)
            try c.encode(title, forKey: .title); try c.encode(agent, forKey: .agent); try c.encode(mode, forKey: .mode)
            try c.encode(state, forKey: .state); try c.encode(started, forKey: .started); try c.encode(ended, forKey: .ended)
            try c.encode(tmux, forKey: .tmux); try c.encode(now, forKey: .now); try c.encode(asking, forKey: .asking)
            try c.encode(waitingSince, forKey: .waitingSince); try c.encode(waitMaxMin, forKey: .waitMaxMin)
            try c.encode(log, forKey: .log); try c.encode(out, forKey: .out)
            try c.encode(attached, forKey: .attached); try c.encode(attachError, forKey: .attachError)
            try c.encode(blocked, forKey: .blocked)
        }
    }

    public struct Scheduled: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var agent: String
        public var next: String?

        public init(id: String, title: String, agent: String, next: String?) {
            self.id = id; self.title = title; self.agent = agent; self.next = next
        }

        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
            try c.encode(agent, forKey: .agent); try c.encode(next, forKey: .next)
        }
    }

    public init(bridge: String, seen: String, keyId: String?, paused: Bool, slots: Slots, mac: Mac, limits: [Limit],
                folders: [String], jobs: [Job], scheduled: [Scheduled]) {
        self.bridge = bridge; self.seen = seen; self.keyId = keyId; self.paused = paused; self.slots = slots; self.mac = mac
        self.limits = limits; self.folders = folders; self.jobs = jobs; self.scheduled = scheduled
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v); try c.encode(bridge, forKey: .bridge); try c.encode(seen, forKey: .seen)
        try c.encode(keyId, forKey: .keyId); try c.encode(paused, forKey: .paused)
        try c.encode(slots, forKey: .slots); try c.encode(mac, forKey: .mac)
        try c.encode(limits, forKey: .limits); try c.encode(folders, forKey: .folders)
        try c.encode(jobs, forKey: .jobs); try c.encode(scheduled, forKey: .scheduled)
    }

    public static let maxJobs = 50
    public static let maxLogLines = 3
    public static let maxLogChars = 200
    public static let maxNowChars = 120

    /// The closed list of `waiting:` reasons, `signature` and `daily` included. Others render as plain "Waiting".
    public static let waitingReasons: Set<String> = ["memory", "disk", "battery", "thermal", "limit", "slot", "folder",
                                                     "paused", "signature", "daily"]
    /// Only the agent-limit wait has a ceiling (90 min, then it runs with a notification).
    public static func waitMaxMin(reason: String, limitMinutes: Int = 90) -> Int? { reason == "limit" ? limitMinutes : nil }
    public static let maxBytes = 16 * 1024

    /// Compact JSON for the notification; `pretty` for fixtures.
    public func json(pretty: Bool = false) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    /// Enforces the status size limits: 50 jobs, 3 log lines of 200 characters, under 16 KB
    /// (drops log lines, then the oldest finished jobs, until it fits).
    public func clamped() -> StatusV2 {
        var s = self
        s.jobs = Array(s.jobs.prefix(Self.maxJobs)).map { j in
            var j = j
            j.log = j.log.suffix(Self.maxLogLines).map { String($0.prefix(Self.maxLogChars)) }
            j.now = j.now.map { String($0.prefix(Self.maxNowChars)) }
            return j
        }
        func size(_ x: StatusV2) -> Int { ((try? x.json()) ?? "").utf8.count }
        if size(s) >= Self.maxBytes { s.jobs = s.jobs.map { var j = $0; j.log = []; return j } }
        while size(s) >= Self.maxBytes, let i = s.jobs.lastIndex(where: { $0.ended != nil }) { s.jobs.remove(at: i) }
        while size(s) >= Self.maxBytes, !s.jobs.isEmpty { s.jobs.removeLast() }
        return s
    }
}
