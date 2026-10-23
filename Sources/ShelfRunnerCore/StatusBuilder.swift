import Foundation
import IOKit.ps

/// The `mac` block of the status JSON; new jobs are held on the same readings.
public protocol MacReadings {
    func read() -> StatusV1.Mac
    /// Free GB on the volume holding `path` (the target folder's volume).
    func diskFreeGB(atPath path: String) -> Double?
}

public extension MacReadings {
    func diskFreeGB(atPath path: String) -> Double? { nil }
}

public struct SystemReadings: MacReadings {
    public init() {}

    public func read() -> StatusV1.Mac {
        StatusV1.Mac(memory: memory(), diskFreeGB: diskFreeGB(atPath: "/"), battery: battery(), thermal: thermal())
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
    func memory() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level { case 1: return "normal"; case 2: return "warn"; case 4: return "critical"; default: return nil }
    }

    /// "Important usage" capacity (what Finder shows), one decimal.
    public func diskFreeGB(atPath path: String) -> Double? {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = v?.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Double(bytes) / 1_000_000_000 * 10).rounded() / 10
    }

    /// `lowpower` wins; on AC (desktops included) `charging`; else `battery:<percent>`.
    func battery() -> String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "lowpower" }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?, type == kIOPMACPowerKey { return "charging" }
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return "battery:\(cur * 100 / max)"
        }
        return nil
    }

    func thermal() -> String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return nil
        }
    }
}

/// A calm machine: the agent's integration-test hook (`SHELF_RUNNER_FIXED_READINGS=1`).
public struct IdleReadings: MacReadings {
    public init() {}
    public func read() -> StatusV1.Mac { .init(memory: "normal", diskFreeGB: 100, battery: "charging", thermal: "nominal") }
}

/// Builds the protocol v1 status from the agent's snapshot.
public struct StatusBuilder {
    public var runnerVersion: String
    public var readings: MacReadings
    public var paths: Paths
    public var limits: LimitsReader

    public init(runnerVersion: String, readings: MacReadings, paths: Paths, limits: LimitsReader? = nil) {
        self.runnerVersion = runnerVersion
        self.readings = readings
        self.paths = paths
        self.limits = limits ?? LimitsReader(paths: paths)
    }

    public func build(_ o: Agent.Observed, paused: Bool, policy: Policy = Policy(),
                      attachments: [String: Attachment] = [:]) -> StatusV1 {
        let now = o.snapshot.now
        let dayAgo = now.addingTimeInterval(-86400)
        func rank(_ s: String) -> Int { JobState.active.contains(s) ? 0 : JobState.isPending(s) ? 1 : 2 }
        let records = o.snapshot.records.values.filter { r in
            guard o.snapshot.enabledFolders.contains(r.folder), r.status != JobState.scheduled else { return false }
            if !JobState.isFinal(r.status) { return true }
            return ISO.parse(r.endedAt ?? r.at).map { $0 >= dayAgo } ?? false
        }.sorted { a, b in
            rank(a.status) != rank(b.status) ? rank(a.status) < rank(b.status) : (a.startedAt ?? a.at) > (b.startedAt ?? b.at)
        }
        let jobs = records.prefix(StatusV1.maxJobs).map { r -> StatusV1.Job in
            let item = o.items[r.id]?.item
            // The live screen is what the user would see; the log file is the fallback.
            let lines = o.snapshot.observations[r.id]?.screen.map { Array($0.suffix(12)).map { String($0.prefix(StatusV1.maxLogChars)) } }
                ?? logTail(r, count: 12)
            let started = r.startedAt.flatMap(ISO.parse) ?? now
            let quiet = now.timeIntervalSince(max(o.snapshot.observations[r.id]?.logModified ?? started, started))
            let waiting = r.status.hasPrefix("waiting:")
            // `ref` goes back exactly as the line wrote it; the runner never computes it.
            return StatusV1.Job(id: r.id, folder: r.folder, ref: r.ref ?? item?.ref, title: r.title ?? item?.title ?? r.id,
                                agent: r.agent, mode: r.mode, state: r.status,
                                started: r.startedAt, ended: r.endedAt,
                                tmux: r.tmuxSession.map { "\($0):\(r.id)" },
                                now: JobSummary.now(lines),
                                asking: JobSummary.asking(mode: r.mode, state: r.status, lines: lines, quietFor: quiet),
                                waitingSince: waiting ? r.waitingSince : nil,
                                waitMaxMin: waiting ? StatusV1.waitMaxMin(reason: String(r.status.dropFirst(8)), limitMinutes: Int(policy.limitMaxWait / 60)) : nil,
                                log: Array(JobSummary.meaningful(lines).suffix(StatusV1.maxLogLines)), out: r.out ?? item?.out,
                                attached: attachments[r.id]?.attached, attachError: attachments[r.id]?.error,
                                blocked: r.blocked)
        }
        let running = o.snapshot.records.values.filter { JobState.active.contains($0.status) }.count
        return StatusV1(runner: runnerVersion, seen: Clock.iso(now), keyId: KeyStore.load(paths).map(ProtocolV1.keyId),
                        paused: paused, slots: .init(max: policy.maxParallel, perFolder: policy.perFolder, running: running),
                        mac: readings.read(), limits: limits.read(now: now), folders: o.snapshot.enabledFolders,
                        jobs: jobs, scheduled: scheduled(o, now: now)).clamped()
    }

    /// Every valid `SCHEDULED.md` line of the enabled folders, soonest first; `next` is `null`
    /// once a series has ended.
    func scheduled(_ o: Agent.Observed, now: Date) -> [StatusV1.Scheduled] {
        let rows = o.snapshot.enabledFolders.flatMap { f in (o.snapshot.schedules[f] ?? nil)?.items ?? [] }.map { item in
            (item, item.schedule?.around(now).next)
        }
        return rows.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?): return x != y ? x < y : a.0.id < b.0.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.0.id < b.0.id
            }
        }.map { StatusV1.Scheduled(id: $0.0.id, title: $0.0.title, agent: $0.0.agent.rawValue, next: $0.1.map { Clock.iso($0) }) }
    }

    /// Last plain-text lines; reads only the end of the file.
    /// A finished attended job's saved screen comes first; print mode's result is only in the log.
    func logTail(_ r: RunRecord, count: Int) -> [String] {
        guard r.startedAt != nil else { return [] }
        if r.mode == QueueItem.Mode.attended.rawValue, let saved = try? String(contentsOf: paths.screenFile(id: r.id), encoding: .utf8) {
            return LogTail.lines(saved, count).map { String($0.prefix(StatusV1.maxLogChars)) }
        }
        guard let path = r.logPath, let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        // A TUI log is mostly escape sequences: 32 KB holds a few screens of text.
        try? h.seek(toOffset: size > 32768 ? size - 32768 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return LogTail.lines(text, count).map { String($0.prefix(StatusV1.maxLogChars)) }
    }
}
