import Foundation

/// `shelf-bridge wrap`: runs inside the tmux window, starts the agent with the window's tty,
/// and records `done` or `failed:<code>`.
public struct Wrap {
    public struct Options: Equatable {
        public var id: String
        public var folder: String
        public var agent: String
        public var mode: String
        public var argv: [String]
    }

    public let paths: Paths
    public let startTimeout: TimeInterval

    public init(paths: Paths, startTimeout: TimeInterval = 10) {
        self.paths = paths
        self.startTimeout = startTimeout
    }

    public static func parse(_ args: [String]) throws -> Options {
        guard let dash = args.firstIndex(of: "--") else { throw RunnerError.usage("wrap: missing '--'") }
        var named: [String: String] = [:]
        var i = 0
        let head = Array(args[..<dash])
        while i < head.count {
            guard head[i].hasPrefix("--"), i + 1 < head.count else { throw RunnerError.usage("wrap: \(head[i])") }
            named[String(head[i].dropFirst(2))] = head[i + 1]
            i += 2
        }
        let argv = Array(args[(dash + 1)...])
        guard let id = named["id"], JobID.isValid(id), let folder = named["folder"],
              let agent = named["agent"], let mode = named["mode"], !argv.isEmpty
        else { throw RunnerError.usage("wrap: missing argument") }
        return Options(id: id, folder: folder, agent: agent, mode: mode, argv: argv)
    }

    /// Returns the exit code to exit with.
    public func run(_ o: Options) -> Int32 {
        let store = RunStore(file: paths.runsFile)
        waitForStartSignal(id: o.id)
        let started = store.latest(id: o.id)?.startedAt ?? Clock.iso()
        // Unattended Claude: stdout is the JSON result, kept apart from the pane.
        let result = PrintResult.applies(agent: o.agent, mode: o.mode) ? paths.resultFile(id: o.id) : nil
        func finish(_ status: String, _ code: Int32?, blocked: Int? = nil) -> Int32 {
            var r = store.latest(id: o.id) ?? RunRecord(id: o.id, folder: o.folder, status: status, agent: o.agent, mode: o.mode)
            r.status = status
            r.blocked = blocked
            // Bridge asked for the stop and the agent ended because of it: its reason (cancelled,
            // failed:timeout) wins over the exit code. An exit long after the Ctrl-C (the user typed
            // /exit) keeps the exit code's status.
            let marker = paths.stopMarker(id: o.id)
            if let data = try? Data(contentsOf: marker), let m = try? JSONDecoder.iso.decode(StopMarker.self, from: data) {
                if m.caused(exitAt: Date(), exitCode: code ?? 1) { r.status = m.reason }
                try? FileManager.default.removeItem(at: marker)
            }
            r.exitCode = code
            r.startedAt = r.startedAt ?? started
            r.endedAt = Clock.iso()
            r.at = Clock.iso()
            try? store.append(r)
            return code ?? 1
        }

        // A handler (not SIG_IGN) so Ctrl-C reaches the agent while wrap survives to record it;
        // handlers reset to default across exec, SIG_IGN would not.
        signal(SIGINT) { _ in }

        let pid: pid_t
        do { pid = try Self.spawn(o.argv, cwd: o.folder, stdout: result?.path) } catch {
            FileHandle.standardError.write(Data("shelf-bridge wrap: could not start: \(error)\n".utf8))
            return finish("failed:127", 127)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // WIFEXITED / WTERMSIG by hand: the C macros are not imported into Swift.
        let signalled = status & 0x7f
        let code: Int32 = signalled == 0 ? (status >> 8) & 0xff : 128 + signalled
        let blocked = result.flatMap { collect($0, log: store.latest(id: o.id)?.logPath.map { URL(fileURLWithPath: $0) } ?? paths.logFile(id: o.id)) }
        return finish(RunRecord.status(exitCode: code), code, blocked: blocked)
    }

    /// Appends the result text (or whatever raw output there was) to the job's log, where the
    /// pane output also goes, and returns the denial count. A missing file is no output.
    func collect(_ result: URL, log: URL) -> Int? {
        guard let raw = try? Data(contentsOf: result) else { return nil }
        let parsed = PrintResult.parse(raw)
        Self.append(parsed.text, to: log)
        return parsed.blocked
    }

    static func append(_ text: String, to log: URL) {
        guard !text.isEmpty else { return }
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// `posix_spawn` keeps the agent in wrap's process group, which is the tty's foreground group:
    /// an interactive agent can read the terminal and receives Ctrl-C. Foundation `Process`
    /// moves the child to its own group.
    /// `stdout`: a file for the agent's standard output instead of the tty.
    static func spawn(_ argv: [String], cwd: String, stdout: String? = nil) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        if let stdout { posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t(), empty = sigset_t()
        sigemptyset(&defaults); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM)
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, environ)
        guard rc == 0 else { throw RunnerError.io("\(argv[0]): \(String(cString: strerror(rc)))") }
        return pid
    }

    func waitForStartSignal(id: String) {
        let signal = paths.startSignal(id: id)
        let deadline = Date().addingTimeInterval(startTimeout)
        while !FileManager.default.fileExists(atPath: signal.path), Date() < deadline { usleep(50_000) }
        try? FileManager.default.removeItem(at: signal)
    }
}
