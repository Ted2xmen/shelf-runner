import CoreServices
import Foundation

/// macOS notifications live in the app target (they need the bundle); the core only asks.
public protocol Notifier: AnyObject {
    /// `kind` `.approve` shows Run / Ignore; the kind is also the notification id prefix.
    func notify(id: String, title: String, body: String, kind: NoticeKind)
}

public final class StderrNotifier: Notifier {
    public init() {}
    public func notify(id: String, title: String, body: String, kind: NoticeKind) {
        FileHandle.standardError.write(Data("[\(Clock.iso())] notification \(kind.identifier(job: id)): \(title): \(body)\n".utf8))
    }
}

/// `shelf-bridge agent`: observes, plans with `Supervisor`, executes. Everything runs
/// on the main queue: FSEvents, the timer and the notification callbacks all deliver there.
@MainActor
public final class Agent {
    public let paths: Paths
    public private(set) var runner: Runner
    public let notifier: Notifier
    /// Called after a tick that changed state.
    public var onChange: (() -> Void)?
    /// Called after every tick (the bridge publishes the status when it changed).
    public var onTick: (() -> Void)?
    public var log: (String) -> Void = { FileHandle.standardError.write(Data("[\(Clock.iso())] \($0)\n".utf8)) }
    /// Machine readings that can hold new jobs; tests swap in fixed readings.
    public var readings: MacReadings = SystemReadings()
    public lazy var limits = LimitsReader(paths: paths)
    /// `attach` results per job, in memory; the status carries them while the job is active.
    public var attachments: [String: Attachment] = [:]
    /// Opens a `.command` file in Terminal; tests swap it out.
    public var openTerminal: (URL) -> Bool = Agent.openInTerminal
    /// Question and failure notices, edge-triggered, in memory.
    public var notices = NoticeWatch()

    private var watcher: FolderWatcher?
    private var watched: [String] = []
    private var lastPrune = Date.distantPast
    private var savedScreens: [String: [String]] = [:]
    private var pendingTick = false
    private var ticking = false

    public init(paths: Paths, runner: Runner, notifier: Notifier) {
        self.paths = paths
        self.runner = runner
        self.notifier = notifier
    }

    // MARK: one pass

    public struct Observed {
        public var snapshot: Snapshot
        public var items: [String: (folder: String, item: QueueItem)]
    }

    /// Windows are observed before records are read: a window that closed did so after its
    /// `wrap` wrote the final record, so a dead window with an active record really lost wrap.
    public func observe(now: Date = Date()) -> Observed {
        let folders = ((try? FolderRegistry.load(paths)) ?? FolderRegistry()).folders.map(\.path)
        var queues: [String: QueueFile?] = [:], schedules: [String: QueueFile?] = [:]
        var items: [String: (String, QueueItem)] = [:]
        for f in folders {
            let dir = URL(fileURLWithPath: f)
            let q = (try? String(contentsOf: dir.appendingPathComponent(QueueGrammar.fileName), encoding: .utf8)).map(QueueGrammar.parse)
            let sch = (try? String(contentsOf: dir.appendingPathComponent(ScheduledGrammar.fileName), encoding: .utf8)).map(ScheduledGrammar.parse)
            queues[f] = q
            schedules[f] = sch
            for item in (q?.items ?? []) + (sch?.items ?? []) where items[item.id] == nil { items[item.id] = (f, item) }
        }
        let tmux = try? runner.tmux()
        var observations: [String: JobObservation] = [:]
        if let tmux {
            for r in runner.store.latest().values where JobState.active.contains(r.status) && folders.contains(r.folder) {
                let mtime = r.logPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
                let alive = tmux.windowAlive(r.tmuxWindow ?? "", name: r.id)
                observations[r.id] = JobObservation(windowAlive: alive, logModified: mtime,
                                                    screen: alive ? tmux.capture(window: r.tmuxWindow ?? "") : nil)
            }
        }
        let records = runner.store.latest()
        var markers: [String: StopMarker] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: paths.stopMarkersDir, includingPropertiesForKeys: nil)) ?? [] {
            if let d = try? Data(contentsOf: url), let m = try? JSONDecoder.iso.decode(StopMarker.self, from: d) {
                markers[url.deletingPathExtension().lastPathComponent] = m
            }
        }
        var snap = Snapshot(enabledFolders: folders, queues: queues, records: records, markers: markers,
                            observations: observations, now: now)
        snap.paused = paused
        snap.schedules = schedules
        // Readings cost a sysctl, IOKit and a walk of ~/.codex/sessions: only when a line could start.
        let candidate = queues.values.contains { q in
            q?.items.contains { !$0.checked && (records[$0.id].map { JobState.isPending($0.status) } ?? true) } ?? false
        } || schedules.values.contains { q in
            q?.items.contains { item in
                guard let r = records[item.id] else { return true }
                let last = item.schedule?.around(now).last
                if JobState.isPending(r.status) { return true }
                // Idle since after this occurrence (a line written after its due time): nothing to start.
                if r.status == JobState.scheduled, let last, let since = ISO.parse(r.at), since >= last { return false }
                return last != nil && !Schedule.isSame(r.occurrence, last)
            } ?? false
        }
        if candidate {
            snap.resources = Resources(mac: readings.read(),
                                       folderDiskGB: folders.reduce(into: [:]) { $0[$1] = readings.diskFreeGB(atPath: $1) },
                                       limits: limits.read(now: now))
        }
        return Observed(snapshot: snap, items: items.mapValues { (folder: $0.0, item: $0.1) })
    }

    /// Not re-entrant: a nested call (anything that spins the run loop mid-tick) is deferred.
    @discardableResult
    public func tick(now: Date = Date()) -> [Action] {
        guard !ticking else { scheduleTick(); return [] }
        ticking = true
        defer { ticking = false }
        reloadConfig()
        let o = observe(now: now)
        // Not a setting: every line passes signature, path and approval checks.
        let gate = AgentGate(key: KeyStore.load(paths), approvals: Approvals.load(paths))
        let actions = Supervisor(policy: runner.config.policy, gate: { item, folder, _ in gate.check(item, folder: folder) })
            .plan(o.snapshot)
        for a in actions { execute(a, o, now: now) }
        // This tick's own status changes (lost, timeout, start) show in the next tick's records.
        for n in notices.failures(o.snapshot.records, folders: Set(o.snapshot.enabledFolders),
                                  titles: o.items.mapValues(\.item.title), maxRuntime: runner.config.policy.maxRuntime) {
            send(n)
        }
        saveScreens(o)
        pruneLogs(now: now)
        sweepAttachments(o)
        if !actions.isEmpty { onChange?() }
        onTick?()
        return actions
    }

    func execute(_ a: Action, _ o: Observed, now: Date) {
        switch a {
        case .start(let item, let folder, let occurrence):
            do {
                let s = try runner.start(item: item, folder: folder, occurrence: occurrence)
                log("started \(item.id) · \(s.record.tmuxSession ?? "") \(s.record.tmuxWindow ?? "")")
            } catch {
                log("could not start \(item.id): \(error)")
                append(id: item.id, status: "failed:start", o, now: now, occurrence: occurrence)
            }
        case .setStatus(let id, let status, let occurrence):
            let previous = o.snapshot.records[id]?.status
            append(id: id, status: status, o, now: now, occurrence: occurrence)
            if status == "needs-approval", previous != status, let found = o.items[id] {
                let when = found.item.schedule.map { s in "\(s.due)\(s.at.map { " \($0)" } ?? "")\(s.every.map { " every:\($0.rawValue)" } ?? "")" }
                notifier.notify(id: id, title: NoticeText.title(found.item.title),
                                body: NoticeText.approval(agent: found.item.agent.rawValue, folder: found.folder,
                                                          unattended: found.item.mode == .unattended, schedule: when), kind: .approve)
            }
            if JobState.isFinal(status) { try? FileManager.default.removeItem(at: paths.stopMarker(id: id)) }
            log("\(id) → \(status)")
        case .interrupt(let id, let window, let reason):
            let m = StopMarker(reason: reason, requestedAt: now)
            try? JSONEncoder.iso.encode(m).write(to: paths.stopMarker(id: id), options: .atomic)
            if let t = try? runner.tmux(), t.windowAlive(window, name: id) { _ = try? t.interrupt(pane: window) }
            log("\(id) stopping (\(reason)): Ctrl-C")
        case .kill(let id, let window, let reason):
            if let t = try? runner.tmux(), t.windowAlive(window, name: id) { t.killWindow(window) }
            append(id: id, status: reason, o, now: now)
            try? FileManager.default.removeItem(at: paths.stopMarker(id: id))
            log("\(id) closed (\(reason)): grace time over, window closed")
        case .notify(let id, let title, let body):
            notifier.notify(id: id, title: title, body: body, kind: .info)
        }
    }

    /// The bridge hands over every status it builds; a job that started asking is announced.
    public func noticeQuestions(_ jobs: [StatusV2.Job]) {
        for n in notices.questions(jobs) { send(n) }
    }

    func send(_ n: Notice) {
        notifier.notify(id: n.id, title: n.title, body: n.body, kind: n.kind)
        log("notification \(n.kind.identifier(job: n.id)): \(n.body.replacingOccurrences(of: "\n", with: " · "))")
    }

    /// Copies the latest record (or builds one from the queue line) with a new status.
    func append(id: String, status: String, _ o: Observed, now: Date, occurrence: String? = nil) {
        let found = o.items[id]
        var r = o.snapshot.records[id] ?? RunRecord(
            id: id, folder: found?.folder ?? "", status: status, agent: found?.item.agent.rawValue ?? "",
            mode: found?.item.mode.rawValue ?? "", title: found?.item.title, ref: found?.item.ref, out: found?.item.out)
        // A new reason restarts the wait clock; leaving `waiting:` clears it.
        if status.hasPrefix("waiting:") { if r.status != status || r.waitingSince == nil { r.waitingSince = Clock.iso(now) } }
        else { r.waitingSince = nil }
        // A new occurrence starts clean: last run's times, exit code and tmux window belong to the old one.
        if let occurrence, occurrence != r.occurrence {
            r.occurrence = occurrence
            r.startedAt = nil; r.endedAt = nil; r.exitCode = nil; r.blocked = nil
            r.tmuxSession = nil; r.tmuxWindow = nil; r.logPath = nil
        }
        r.status = status
        r.at = Clock.iso(now)
        if JobState.isFinal(status) && r.startedAt != nil && r.endedAt == nil { r.endedAt = Clock.iso(now) }
        if JobState.isPending(status) { r.endedAt = nil; r.exitCode = nil; r.blocked = nil }
        do { try runner.store.append(r) } catch { log("runs.jsonl: \(error)") }
    }

    func reloadConfig() {
        if let c = try? Config.load(from: paths.configFile), c != runner.config {
            runner = Runner(paths: paths, config: c, wrapExecutable: runner.wrapExecutable, environment: runner.environment)
            log("config.toml reloaded")
        }
    }

    /// `pause` / `resume`: a file, so it survives a restart. Paused = no new starts;
    /// running jobs, cancels and timeouts carry on.
    public var paused: Bool { FileManager.default.fileExists(atPath: paths.stateDir.appendingPathComponent("paused").path) }

    public func setPaused(_ on: Bool) {
        let url = paths.stateDir.appendingPathComponent("paused")
        if on { FileManager.default.createFile(atPath: url.path, contents: Data(Clock.iso().utf8)) }
        else { try? FileManager.default.removeItem(at: url) }
        log(on ? "paused" : "resumed")
    }

    /// Logs are kept 14 days.
    /// Keeps each live job's latest pane text on disk, written only when it changed.
    func saveScreens(_ o: Observed) {
        var kept: [String: [String]] = [:]
        for (id, obs) in o.snapshot.observations {
            guard let screen = obs.screen, !screen.isEmpty else { continue }
            kept[id] = screen
            if savedScreens[id] != screen {
                try? Data((screen.joined(separator: "\n") + "\n").utf8).write(to: paths.screenFile(id: id), options: .atomic)
            }
        }
        savedScreens = kept
    }

    func pruneLogs(now: Date) {
        guard now.timeIntervalSince(lastPrune) > 3600 else { return }
        lastPrune = now
        let cutoff = now.addingTimeInterval(-14 * 86400)
        for url in (try? FileManager.default.contentsOfDirectory(at: paths.logsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ["log", "txt", "json"].contains(url.pathExtension) && (url.lastPathComponent.hasPrefix("q-") || url.lastPathComponent.hasPrefix("s-")) {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: loop

    /// Watches the enabled folders and the state dir; ticks on change (debounced) and every
    /// `interval` seconds as a fallback for missed events and for stall / timeout clocks.
    public func startLoop(interval: TimeInterval = 5) {
        try? paths.ensureDirectories()
        rewatch()
        tick()
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAndRewatch() }
        }
    }

    func scheduleTick() {
        guard !pendingTick else { return }
        pendingTick = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pendingTick = false
            self?.tickAndRewatch()
        }
    }

    func tickAndRewatch() {
        rewatch()
        tick()
    }

    func rewatch() {
        let folders = ((try? FolderRegistry.load(paths)) ?? FolderRegistry()).folders.map(\.path)
        let wanted = folders + [paths.stateDir.path]
        guard wanted != watched else { return }
        watched = wanted
        watcher = FolderWatcher(paths: wanted) { [weak self] in MainActor.assumeIsolated { self?.scheduleTick() } }
        log("watching: \(folders.count) folder\(folders.count == 1 ? "" : "s")")
    }

    /// One agent per user: a second one exits (also the notification-launched instance).
    /// `true` when another process holds the agent lock; `nil` when the lock file cannot be opened
    /// (unwritable state dir), so `doctor` and `status` do not call that "running".
    nonisolated public static func lockHeld(_ paths: Paths) -> Bool? {
        try? paths.ensureDirectories()
        let fd = open(paths.agentLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }

    nonisolated public static func acquireLock(_ paths: Paths) -> Int32? {
        try? paths.ensureDirectories()
        let fd = open(paths.agentLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }
}

/// Directory-level FSEvents: flags are not trusted, any event means "re-read".
public final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    public init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags)
        else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}
