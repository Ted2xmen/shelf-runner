import Foundation

/// Shelf bridge: status every 30 s and on every change, `ping` answers,
/// signed commands. Also writes `heartbeat.json`, a fallback file Shelf can bookmark.
@MainActor
public final class Bridge {
    public let agent: Agent
    public var builder: StatusBuilder
    let center = DistributedNotificationCenter.default()
    private var gate: CommandGate?
    private var lastBody: String?
    private var lastPublish = Date.distantPast
    private var deferred = false
    private var observer: NSObjectProtocol?
    /// At most one log answer per job per second.
    private var lastLogReply: [String: Date] = [:]
    public var log: (String) -> Void
    /// Posts a distributed notification; tests swap it so they never reach a real Shelf.
    public var post: (String, [String: Any]) -> Void = { name, info in
        DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: info, deliverImmediately: true)
    }

    public init(agent: Agent, builder: StatusBuilder) {
        self.agent = agent
        self.builder = builder
        self.log = agent.log
    }

    public func start(interval: TimeInterval = 30) {
        // name nil + Shelf's object: the only shape macOS delivers for names it cannot know.
        observer = center.addObserver(forName: nil, object: ProtocolV1.shelfObject, queue: .main) { [weak self] n in
            let name = n.name.rawValue
            MainActor.assumeIsolated { self?.received(name) }
        }
        let previous = agent.onTick
        agent.onTick = { [weak self] in previous?(); self?.publish(force: false) }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish(force: true) }
        }
        publish(force: true)
    }

    /// Sends when the status changed (ignoring `seen`) or when forced (timer, ping).
    /// Change-driven sends are at most one per 2 s (limits-tee writes on every status line
    /// redraw); a skipped change is sent when the window ends.
    public func publish(force: Bool) {
        if !force, Date().timeIntervalSince(lastPublish) < 2 {
            guard !deferred else { return }
            deferred = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.deferred = false; self?.publish(force: false) }
            }
            return
        }
        let status = builder.build(agent.observe(), paused: agent.paused, policy: agent.runner.config.policy,
                                   attachments: agent.attachments)
        agent.noticeQuestions(status.jobs)
        var unseen = status
        unseen.seen = ""
        let body = (try? unseen.json()) ?? ""
        guard force || body != lastBody, let json = try? status.json() else { return }
        lastBody = body
        lastPublish = Date()
        post(ProtocolV1.statusName, ["v": ProtocolV1.version, "json": json])
        try? Data(json.utf8).write(to: agent.paths.stateDir.appendingPathComponent("heartbeat.json"), options: .atomic)
    }

    func received(_ name: String) {
        if name == ProtocolV1.pingName { publish(force: true); return }
        guard name.hasPrefix(ProtocolV1.commandPrefix) else { return }
        guard let key = KeyStore.load(agent.paths) else { log("command refused: not paired"); return }
        if gate?.key != key { gate = CommandGate(key: key) }
        switch gate!.accept(name, now: Int(Date().timeIntervalSince1970)) {
        case .failure(let why):
            log("command refused (\(why)): \(name.dropFirst(ProtocolV1.commandPrefix.count).prefix(60))")
        case .success(let c):
            switch c.verb {
            case .log:
                if let id = c.id { replyLog(id: id) }
            case .attach:
                log("command: attach \(c.id ?? "-")")
                if let id = c.id { agent.attach(id: id) }
                publish(force: true)
            default:
                log("command: \(c.verb.rawValue) \(c.id ?? "-")")
                agent.apply(c)
                publish(force: true)
            }
        }
    }

    /// Shelf asks every 2 s while the job window is open; an unknown job gets no answer.
    /// Returns whether an answer went out.
    @discardableResult
    public func replyLog(id: String, now: Date = Date()) -> Bool {
        if let last = lastLogReply[id], now.timeIntervalSince(last) < 1 { return false }
        guard let r = agent.runner.store.latest(id: id) else { return false }
        var screen: [String]?
        var styles: [[AnsiText.Run]]?
        // Only a live pane is coloured (`-e`); saved screens and log files stay plain.
        if JobState.active.contains(r.status), let window = r.tmuxWindow, let t = try? agent.runner.tmux(), t.windowAlive(window, name: id),
           let capture = t.capture(window: window, escapes: true) {
            screen = capture.lines
            styles = capture.styles
        }
        // A finished attended job: its last saved screen beats the raw TUI log. Print mode
        // writes its result only at exit, after the last capture: its log file is the answer.
        if screen == nil, r.mode == QueueItem.Mode.attended.rawValue, let saved = try? String(contentsOf: agent.paths.screenFile(id: id), encoding: .utf8) {
            screen = LogTail.allLines(saved)
        }
        guard let json = try? LogReply.build(r, screen: screen, styles: styles, now: now).json() else { return false }
        lastLogReply = lastLogReply.filter { now.timeIntervalSince($0.value) < 60 }
        lastLogReply[id] = now
        post(ProtocolV1.logName, ["v": ProtocolV1.version, "id": id, "json": json])
        return true
    }
}

extension Agent {
    /// A `stop` while one is pending presses Ctrl-C again (the agent may have shown "press again");
    /// the grace clock keeps the first request's time.
    func repress(id: String, window: String, _ m: StopMarker, now: Date = Date()) {
        var m = m
        m.signalledAt = now
        try? JSONEncoder.iso.encode(m).write(to: paths.stopMarker(id: id), options: .atomic)
        if let t = try? runner.tmux(), t.windowAlive(window, name: id) { _ = try? t.interrupt(pane: window) }
        log("\(id) stopping again (\(m.reason)): Ctrl-C")
    }

    /// Command verbs. `run` / `ignore` are approvals, but `ignore` on a failed job only ends it
    /// as `cancelled` (Shelf's "Take it back" / "Mark done"); `requeue` re-approves a finished job;
    /// `runnow` is the same as the CLI `run` (skips holds); `stop` cancels like a removed line.
    public func apply(_ c: ProtocolV1.Command) {
        let paths = self.paths
        do {
            switch c.verb {
            case .run, .ignore:
                guard let id = c.id else { return }
                // A failed job's `ignore` ends only that run: no approval is written, so a
                // scheduled line's next occurrence still runs.
                let o = observe()
                if c.verb == .ignore, let r = o.snapshot.records[id], r.status.hasPrefix("failed") {
                    append(id: id, status: "cancelled", o, now: Date())
                } else {
                    try Approvals.record(paths, id: id, decision: c.verb == .run ? .run : .ignore, via: "shelf")
                }
            case .requeue:
                guard let id = c.id else { return }
                try Approvals.record(paths, id: id, decision: .run, via: "shelf")
                let o = observe()
                if let r = o.snapshot.records[id], JobState.isFinal(r.status) { append(id: id, status: "queued", o, now: Date()) }
            case .stop:
                guard let id = c.id else { return }
                let o = observe()
                if let r = o.snapshot.records[id], JobState.active.contains(r.status) {
                    if let m = o.snapshot.markers[id] { repress(id: id, window: r.tmuxWindow ?? "", m) }
                    else { execute(.interrupt(id: id, window: r.tmuxWindow ?? "", reason: "cancelled"), o, now: Date()) }
                } else if let r = o.snapshot.records[id], JobState.isPending(r.status) {
                    append(id: id, status: "cancelled", o, now: Date())
                }
            case .runnow:
                guard let id = c.id else { return }
                _ = try runner.run(id: id)
            case .pause, .resume:
                setPaused(c.verb == .pause)
            case .log, .attach:
                return  // Bridge answers these; they change no state
            }
        } catch {
            log("command \(c.verb.rawValue) \(c.id ?? "-"): \(error)")
        }
        tick()
    }
}
