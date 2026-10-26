import Foundation

/// Runs a program with an argv array. No shell anywhere on our side.
///
/// `posix_spawn` + `waitpid`, not `Process.waitUntilExit()`: that spins the main run loop, so the
/// agent's timer and FSEvents fired inside a tick and started the same job twice.
enum Exec {
    struct Output { var status: Int32; var text: String }

    static func run(_ executable: String, _ args: [String], environment: [String: String]? = nil) throws -> Output {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw RunnerError.io("pipe: \(String(cString: strerror(errno)))") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envStrings: [UnsafeMutablePointer<CChar>?]? = environment.map { env in
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        }
        defer { envStrings?.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = envStrings.map { env in posix_spawn(&pid, executable, &actions, nil, argv, env) }
            ?? posix_spawn(&pid, executable, &actions, nil, argv, environ)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); throw RunnerError.io("\(executable): \(String(cString: strerror(rc)))") }
        let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let signalled = status & 0x7f
        return Output(status: signalled == 0 ? (status >> 8) & 0xff : 128 + signalled, text: String(decoding: data, as: UTF8.self))
    }
}

/// Drives tmux. Window commands are always passed as two or more arguments:
/// a single argument would make tmux run it through `sh -c`.
public struct Tmux: Sendable {
    public let executable: String
    public let socket: String?

    public init(executable: String, socket: String?) {
        self.executable = executable
        self.socket = socket
    }

    public struct Pane: Equatable, Sendable {
        public var session: String
        public var windowID: String
        public var paneID: String
    }

    /// `shelf-<folder name>`; tmux treats `.` and `:` in targets specially.
    public static func sessionName(folder: String) -> String {
        let base = (folder as NSString).lastPathComponent
        let safe = String(base.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return "shelf-" + (safe.isEmpty ? "root" : safe)
    }

    /// Exact-match target (`=name`), so `shelf-a` never matches `shelf-ab`.
    static func exact(_ session: String) -> String { "=" + session }

    func baseArgs() -> [String] { socket.map { ["-L", $0] } ?? [] }

    @discardableResult
    func tmux(_ args: [String]) throws -> Exec.Output {
        do { return try Exec.run(executable, baseArgs() + args) }
        catch { throw RunnerError.tmuxNotFound }
    }

    public func hasSession(_ name: String) throws -> Bool {
        try tmux(["has-session", "-t", Tmux.exact(name)]).status == 0
    }

    /// Opens the job in a new window, creating the session if needed.
    public func openWindow(session: String, windowName: String, cwd: String,
                           environment: [String: String], command: [String]) throws -> Pane {
        precondition(command.count >= 2, "a single-argument tmux command runs through sh -c")
        let env = environment.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
        let format = ["-P", "-F", "#{window_id} #{pane_id}"]
        let args: [String]
        if try hasSession(session) {
            args = ["new-window", "-d", "-t", Tmux.exact(session) + ":", "-n", windowName, "-c", cwd] + format + env + command
        } else {
            args = ["new-session", "-d", "-s", session, "-n", windowName, "-c", cwd, "-x", "200", "-y", "50"] + format + env + command
        }
        let out = try tmux(args)
        let parts = out.text.split(whereSeparator: \.isWhitespace)
        guard out.status == 0, parts.count == 2 else { throw RunnerError.tmuxFailed(args: args, output: out.text) }
        return Pane(session: session, windowID: String(parts[0]), paneID: String(parts[1]))
    }

    /// Appends pane output to `log`. tmux runs this through `sh -c`; only a fixed `cat` and a
    /// single-quoted path Bridge built go in.
    public func pipeToLog(pane: String, log: URL) throws {
        let quoted = "'" + log.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let args = ["pipe-pane", "-o", "-t", pane, "cat >> \(quoted)"]
        let out = try tmux(args)
        guard out.status == 0 else { throw RunnerError.tmuxFailed(args: args, output: out.text) }
    }

    /// Esc, then Ctrl-C twice, 0.3 s apart. Claude Code's folder-trust dialog ignores
    /// Ctrl-C and exits on Esc; elsewhere Esc only interrupts the turn. Claude Code and Codex treat
    /// one Ctrl-C as "press again to exit". Print mode stops on the first Ctrl-C.
    public func interrupt(pane: String) throws {
        let first = ["send-keys", "-t", pane, "Escape"]
        let out = try tmux(first)
        guard out.status == 0 else { throw RunnerError.tmuxFailed(args: first, output: out.text) }
        // An earlier key may already have ended the job and its window: later ones can fail.
        for _ in 0..<2 {
            usleep(300_000)
            _ = try? tmux(["send-keys", "-t", pane, "C-c"])
        }
    }

    /// `true` only if `window` exists and is still named `name` (the job id). Window ids restart
    /// at `@0` with every new tmux server, so an old record's id can point at another job's window.
    /// `display-message` exits 0 even for a missing target (tmux 3.6, empty fields), so the printed
    /// values are what count. `-n` turns automatic-rename off for our windows.
    public func windowAlive(_ window: String, name: String) -> Bool {
        guard !window.isEmpty, let out = try? tmux(["display-message", "-p", "-t", window, "#{window_id} #{window_name}"])
        else { return false }
        return out.status == 0 && out.text.trimmingCharacters(in: .whitespacesAndNewlines) == "\(window) \(name)"
    }

    /// The pane as the user sees it (plus up to `history` scrollback rows), plain text: no `-e`,
    /// so tmux has already applied every cursor move and redraw. `-J` joins wrapped rows.
    public func capture(window: String, history: Int = 500) -> [String]? {
        capture(window: window, history: history, escapes: false)?.lines
    }

    /// `escapes`: also `-e`, for the log-answer colours. The lines stay those of the plain
    /// capture: `AnsiText.parse` runs the same engine and only adds `styles`; nil without `-e`.
    public func capture(window: String, history: Int = 500, escapes: Bool) -> (lines: [String], styles: [[AnsiText.Run]]?)? {
        let args = ["capture-pane", "-p", "-J"] + (escapes ? ["-e"] : []) + ["-t", window, "-S", "-\(history)"]
        guard let out = try? tmux(args), out.status == 0 else { return nil }
        guard escapes else { return (LogTail.allLines(out.text), nil) }
        let parsed = AnsiText.parse(raw: out.text)
        return (parsed.lines, parsed.styles)
    }

    public func killWindow(_ window: String) {
        _ = try? tmux(["kill-window", "-t", window])
    }

    /// The `.command` script for `attach`: only Bridge's own tmux path, socket, session and
    /// job id (the window name) go in, each single-quoted; never the task text. The job's window
    /// is selected first, then the session attached.
    public func attachScript(session: String, window: String?) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let tmux = ([q(executable)] + (socket.map { ["-L", q($0)] } ?? [])).joined(separator: " ")
        var s = "#!/bin/sh\n# shelf-bridge attach; deleted when the job ends.\nunset TMUX\n"
        if let window { s += "\(tmux) select-window -t \(q(Tmux.exact(session) + ":" + window)) 2>/dev/null\n" }
        return s + "exec \(tmux) attach-session -t \(q(Tmux.exact(session)))\n"
    }

    public func attachHint(session: String) -> String {
        "tmux " + (socket.map { "-L \($0) " } ?? "") + "attach -t \(session)"
    }
}
