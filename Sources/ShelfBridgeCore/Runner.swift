import Foundation

/// `enable` / `disable` / `list` / `run`.
public struct Runner {
    public let paths: Paths
    public let config: Config
    /// The `shelf-bridge` binary tmux starts as `wrap`.
    public let wrapExecutable: String
    public let environment: [String: String]

    public init(paths: Paths, config: Config, wrapExecutable: String,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.config = config
        self.wrapExecutable = wrapExecutable
        self.environment = environment
    }

    public var store: RunStore { RunStore(file: paths.runsFile) }

    // MARK: folders

    public func enable(_ path: String) throws -> (path: String, changed: Bool) {
        let p = try FolderRegistry.canonical(path)
        var reg = try FolderRegistry.load(paths)
        let changed = reg.enable(p)
        try reg.save(paths)
        return (p, changed)
    }

    public func disable(_ path: String) throws -> (path: String, changed: Bool) {
        // A folder that no longer exists can still be disabled by its stored path.
        let p = (try? FolderRegistry.canonical(path)) ?? URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var reg = try FolderRegistry.load(paths)
        let changed = reg.disable(p)
        try reg.save(paths)
        return (p, changed)
    }

    public struct FolderListing {
        public var folder: String
        public var queueExists: Bool
        public var queue: QueueFile
        /// `SCHEDULED.md`; empty when missing.
        public var schedule: QueueFile
    }

    public func list() throws -> [FolderListing] {
        try FolderRegistry.load(paths).folders.map { e in
            let url = URL(fileURLWithPath: e.path).appendingPathComponent(QueueGrammar.fileName)
            let text = try? String(contentsOf: url, encoding: .utf8)
            let sched = try? String(contentsOf: URL(fileURLWithPath: e.path).appendingPathComponent(ScheduledGrammar.fileName), encoding: .utf8)
            return FolderListing(folder: e.path, queueExists: text != nil,
                                 queue: text.map(QueueGrammar.parse) ?? QueueFile(items: [], invalid: []),
                                 schedule: sched.map(ScheduledGrammar.parse) ?? QueueFile(items: [], invalid: []))
        }
    }

    // MARK: run

    public func find(id: String) throws -> (folder: String, item: QueueItem) {
        for l in try list() {
            let file = ScheduledID.isValid(id) ? l.schedule : l.queue
            if let item = file.item(id: id) { return (l.folder, item) }
            if let bad = file.invalid.first(where: { $0.text.contains("id:\(id)") }) {
                throw RunnerError.invalidLine(id: id, line: bad.line, reason: bad.error.description)
            }
        }
        throw RunnerError.idNotFound(id)
    }

    public func tmux() throws -> Tmux {
        guard let path = ExecutableLocator.find("tmux", configured: config.tmuxPath, home: paths.home, environment: environment)
        else { throw RunnerError.tmuxNotFound }
        return Tmux(executable: path, socket: config.tmuxSocket)
    }

    public func agentCommand(_ agent: QueueItem.Agent) throws -> AgentCommand {
        guard let path = ExecutableLocator.find(agent.rawValue, configured: config.agentPaths[agent], home: paths.home, environment: environment)
        else { throw RunnerError.agentNotFound(agent.rawValue) }
        return CLIAgentCommand(agent: agent, executable: path, model: config.unattendedModels[agent])
    }

    public struct Started: Equatable {
        public var record: RunRecord
        public var attach: String
    }

    /// `run <id>` from the CLI: the user's explicit action, so it is not held for a signature or
    /// approval; still refuses ticked and already active jobs.
    public func run(id: String) throws -> Started {
        guard JobID.isValid(id) else { throw RunnerError.usage("invalid id: \(id)") }
        let (folder, item) = try find(id: id)
        if item.checked { throw RunnerError.alreadyChecked(id) }
        let latest = store.latest(id: id)
        if let latest, JobState.active.contains(latest.status) {
            throw RunnerError.alreadyRunning(id, session: latest.tmuxSession)
        }
        // A scheduled job run by hand counts as its latest due occurrence, so the agent does not run it again.
        let occurrence = item.schedule?.around(Date()).last.map(Clock.iso) ?? latest?.occurrence
        return try start(item: item, folder: folder, occurrence: occurrence)
    }

    /// Starts one job in tmux (attended interactive, unattended in print mode). The job waits
    /// in `wrap` until its log pipe and
    /// `running` record exist, then the start signal releases it.
    public func start(item: QueueItem, folder: String, occurrence: String? = nil) throws -> Started {
        let id = item.id
        try? FileManager.default.removeItem(at: paths.stopMarker(id: id))
        let agentArgv = try agentCommand(item.agent).argv(prompt: Prompt.wrap(item, folder: folder), mode: item.mode)
        let tmux = try tmux()
        try paths.ensureDirectories()
        let signal = paths.startSignal(id: id)
        try? FileManager.default.removeItem(at: signal)

        var env: [String: String] = [:]
        if let h = environment["SHELF_BRIDGE_HOME"] { env["SHELF_BRIDGE_HOME"] = h }
        let command = [wrapExecutable, "wrap", "--id", id, "--folder", folder, "--agent", item.agent.rawValue,
                       "--mode", item.mode.rawValue, "--"] + agentArgv
        let session = Tmux.sessionName(folder: folder)
        let pane = try tmux.openWindow(session: session, windowName: id, cwd: folder, environment: env, command: command)
        let log = paths.logFile(id: id)
        try? FileManager.default.removeItem(at: log)  // a re-run starts a fresh log (and no wait clock)
        try? FileManager.default.removeItem(at: paths.screenFile(id: id))
        try? FileManager.default.removeItem(at: paths.resultFile(id: id))
        var record = RunRecord(id: id, folder: folder, status: "running", agent: item.agent.rawValue, mode: item.mode.rawValue,
                               title: item.title, ref: item.ref,
                               startedAt: Clock.iso(), tmuxSession: session, tmuxWindow: pane.windowID,
                               logPath: log.path, out: item.out)
        record.occurrence = occurrence
        do {
            try tmux.pipeToLog(pane: pane.paneID, log: log)
            try store.append(record)
        } catch {
            // Without a log or a record nobody could follow the job: stop it before it starts.
            _ = try? tmux.interrupt(pane: pane.paneID)
            throw error
        }
        guard FileManager.default.createFile(atPath: signal.path, contents: nil) else {
            throw RunnerError.io("could not write the start signal: \(signal.path)")
        }
        return Started(record: record, attach: tmux.attachHint(session: session))
    }
}
