import AppKit
import Foundation
import ShelfRunnerCore

/// `CFBundleShortVersionString` (scripts/release.sh sets it); a bare build says `dev`.
let version = ownBundleInfo?["CFBundleShortVersionString"] ?? "dev"

let usage = """
shelf-runner \(version): from a Markdown queue to agents in tmux

Usage:
  shelf-runner enable <folder>     enable a folder (all folders are off by default)
  shelf-runner disable <folder>    disable a folder
  shelf-runner list                enabled folders, queue and scheduled lines
  shelf-runner run <id>            start the line in tmux now (q- or s-)
  shelf-runner status              state of every job
  shelf-runner logs <id> [lines]   tail of the job's log (default 40 lines)
  shelf-runner agent               background agent (started by launchd)
  shelf-runner pair                new pairing key and the SR1- code to paste into Shelf
  shelf-runner approve <id>        run a job that waits for approval
  shelf-runner ignore <id>         ignore a job that waits for approval
  shelf-runner line <folder> <claude|codex> <title...> [--mode m] [--ref file@hash] [--out path]
                                   print a signed queue line to add by hand
  shelf-runner limits-tee [--show]  save the status line JSON and pass it on (--show: print a short line)
  shelf-runner doctor              check the install (tmux, agents, LaunchAgent, pairing, folders)
  shelf-runner version

"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("shelf-runner: \(message)\n".utf8))
    exit(code)
}

/// The real binary, symlinks resolved: tmux must start the same build.
func selfExecutable() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return CommandLine.arguments[0] }
    let path = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

let args = Array(CommandLine.arguments.dropFirst())
let paths = Paths.current()

// macOS launches the app with no arguments to deliver a notification answer.
if args.isEmpty && runningInAgentBundle && isatty(STDIN_FILENO) == 0 { MainActor.assumeIsolated { runResponder() } }

guard let command = args.first else { print(usage, terminator: ""); exit(0) }
let rest = Array(args.dropFirst())

// Runs in front of the user's status line on every redraw: no config, no lock, never fails.
if command == "limits-tee" {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    LimitsTee.save(input, paths: paths)
    if rest == ["--show"] { print(LimitsTee.summary(input)) } else { FileHandle.standardOutput.write(input) }
    exit(0)
}

if command == "wrap" {
    do { exit(Wrap(paths: paths).run(try Wrap.parse(rest))) } catch { fail("\(error)", code: 2) }
}

let config: Config
do { config = try Config.load(from: paths.configFile) } catch { fail("\(error)") }
for k in config.unknownKeys { FileHandle.standardError.write(Data("shelf-runner: config.toml: unknown key \(k)\n".utf8)) }
let runner = Runner(paths: paths, config: config, wrapExecutable: selfExecutable())

do {
    switch (command, rest.count) {
    case ("enable", 1):
        let r = try runner.enable(rest[0])
        print(r.changed ? "enabled: \(r.path)" : "already enabled: \(r.path)")
    case ("disable", 1):
        let r = try runner.disable(rest[0])
        print(r.changed ? "disabled: \(r.path)" : "not enabled: \(r.path)")
    case ("list", 0):
        let listings = try runner.list()
        if listings.isEmpty { print("no enabled folders (shelf-runner enable <folder>)") }
        let runs = runner.store.latest()
        for l in listings {
            print(l.folder)
            if !l.queueExists { print("  (no \(QueueGrammar.fileName))"); continue }
            for item in l.queue.items {
                let state = item.checked ? "checked" : (runs[item.id]?.status ?? "-")
                print("  \(item.id)  \(item.agent.rawValue)/\(item.mode.rawValue)  \(state)  \(item.title)")
            }
            for bad in l.queue.invalid { print("  line \(bad.line): invalid: \(bad.error)") }
            printSchedule(l, runs: runs)
        }
    case ("run", 1):
        let s = try runner.run(id: rest[0])
        print("running: \(s.record.id) · tmux \(s.record.tmuxSession ?? "") \(s.record.tmuxWindow ?? "")")
        print("watch: \(s.attach)")
        print("log: \(s.record.logPath ?? "")")
    case ("status", 0):
        print("agent: \(Agent.lockHeld(paths).map { $0 ? "running" : "not running" } ?? "unknown (cannot open the lock file)")")
        let runs = runner.store.latest()
        for l in try runner.list() {
            print(l.folder)
            for item in l.queue.items where !item.checked || runs[item.id] != nil {
                let r = runs[item.id]
                var extra = ""
                if let r, JobState.active.contains(r.status), let s = r.startedAt.flatMap(ISO.parse) {
                    extra = " \(Int(Date().timeIntervalSince(s) / 60)) min · \(r.tmuxSession ?? ""):\(item.id)"
                }
                print("  \(item.id)  \(item.checked ? "checked/" : "")\(r?.status ?? "new")\(extra)  \(item.title)")
            }
            printSchedule(l, runs: runs)
        }
    case ("logs", 1), ("logs", 2):
        guard JobID.isValid(rest[0]) else { fail("invalid id: \(rest[0])") }
        let count = rest.count == 2 ? Int(rest[1]) ?? 40 : 40
        let text = (try? String(contentsOf: paths.logFile(id: rest[0]), encoding: .utf8)) ?? ""
        if text.isEmpty { fail("no log: \(rest[0])") }
        print(LogTail.lines(text, count).joined(separator: "\n"))
    case ("agent", 0):
        guard let lock = Agent.acquireLock(paths) else { fail("the agent is already running") }
        _ = lock  // held for the life of the process
        runAgent(runner: runner)
    case ("pair", 0):
        let key = try KeyStore.pair(paths)
        print(PairCode.encode(key))
        FileHandle.standardError.write(Data("""
        Paste this code into Shelf › Settings › Agents › Runner. It is shown once; any earlier pairing no longer works.
        keyId: \(ProtocolV1.keyId(key))

        """.utf8))
    case ("approve", 1), ("ignore", 1):
        let id = rest[0]
        guard JobID.isValid(id) else { fail("invalid id: \(id)") }
        try Approvals.record(paths, id: id, decision: command == "approve" ? .run : .ignore, via: "cli")
        print(command == "approve" ? "approved: \(id)" : "ignored: \(id)")
    case ("line", _) where rest.count >= 3:
        var words: [String] = [], opts: [String: String] = [:]
        var i = 2
        while i < rest.count {
            if ["--mode", "--ref", "--out"].contains(rest[i]), i + 1 < rest.count { opts[rest[i]] = rest[i + 1]; i += 2 }
            else { words.append(rest[i]); i += 1 }
        }
        guard let key = KeyStore.load(paths) else { fail("not paired: run shelf-runner pair first") }
        guard let agent = QueueItem.Agent(rawValue: rest[1]) else { fail("agent must be claude or codex") }
        guard let mode = QueueItem.Mode(rawValue: opts["--mode"] ?? "attended") else { fail("mode must be attended or unattended") }
        let folder = try FolderRegistry.canonical(rest[0])
        if !((try? FolderRegistry.load(paths))?.isEnabled(folder) ?? false) {
            FileHandle.standardError.write(Data("warning: folder is not enabled (shelf-runner enable \(folder))\n".utf8))
        }
        print(try QueueID.signedLine(key: key, folder: folder, title: words.joined(separator: " "), agent: agent, mode: mode,
                                     ref: opts["--ref"], out: opts["--out"]))
    case ("doctor", 0):
        let checks = Doctor.run(.init(paths: paths, environment: ProcessInfo.processInfo.environment, executable: selfExecutable(),
                                      inAppBundle: runningInAgentBundle,
                                      serviceLoaded: Doctor.launchdLoaded,
                                      agentRunning: { Agent.lockHeld(paths) }))
        print("shelf-runner \(version)")
        print(Doctor.render(checks))
        let fails = checks.filter { $0.level == .fail }.count
        print(fails == 0 ? "\nhealthy" : "\n\(fails) problem\(fails == 1 ? "" : "s")")
        exit(fails == 0 ? 0 : 1)
    case ("version", 0), ("--version", 0):
        print(version)
    case ("help", _), ("--help", _), ("-h", _):
        print(usage, terminator: "")
    default:
        fail("unknown command or missing argument: \(args.joined(separator: " "))\n\n\(usage)", code: 64)
    }
} catch {
    fail("\(error)")
}

/// `SCHEDULED.md` lines under a folder in `list` and `status`: next time and last state.
func printSchedule(_ l: Runner.FolderListing, runs: [String: RunRecord]) {
    for item in l.schedule.items {
        let next = item.schedule?.around(Date()).next.map { Clock.iso($0) } ?? "done"
        print("  \(item.id)  \(item.agent.rawValue)/scheduled  next \(next)  \(runs[item.id]?.status ?? "new")  \(item.title)")
    }
    for bad in l.schedule.invalid { print("  \(ScheduledGrammar.fileName) line \(bad.line): invalid: \(bad.error)") }
}

/// Never returns. Inside the app bundle it runs an NSApplication so notifications work.
@MainActor
func runAgent(runner: Runner) -> Never {
    let notifier: Notifier
    var app: AppNotifier?
    if runningInAgentBundle {
        let n = AppNotifier { id, action in recordAnswer(id: id, action: action) }
        n.requestAuthorization()
        app = n
        notifier = n
    } else {
        notifier = StderrNotifier()
    }
    let agent = Agent(paths: paths, runner: runner, notifier: notifier)
    agent.log("agent started · \(version) · \(runningInAgentBundle ? "app" : "CLI") · pid \(getpid())")
    // Test hook: the integration test shortens the fallback tick that drives stall and timeout clocks.
    let tick = Double(ProcessInfo.processInfo.environment["SHELF_RUNNER_TICK_SECONDS"] ?? "") ?? 5
    // Test hook: integration tests must not wait on this Mac's disk, battery or heat.
    let readings: MacReadings = ProcessInfo.processInfo.environment["SHELF_RUNNER_FIXED_READINGS"] == "1" ? IdleReadings() : SystemReadings()
    agent.readings = readings
    agent.startLoop(interval: tick)
    let bridge = Bridge(agent: agent, builder: StatusBuilder(runnerVersion: version, readings: readings, paths: paths))
    bridge.start(interval: Double(ProcessInfo.processInfo.environment["SHELF_RUNNER_STATUS_SECONDS"] ?? "") ?? 30)
    withExtendedLifetime((agent, app, bridge)) {
        if runningInAgentBundle {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        } else {
            RunLoop.main.run()
        }
    }
    exit(0)
}

func recordAnswer(id: String, action: String) {
    let decision: Approvals.Decision = action == AppNotifier.runAction ? .run : .ignore
    do {
        try Approvals.record(paths, id: id, decision: decision, via: "notification")
        FileHandle.standardError.write(Data("[\(Clock.iso())] notification answer \(id): \(decision.rawValue)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("[\(Clock.iso())] could not record the answer \(id): \(error)\n".utf8))
    }
}

/// Launched by macOS for a notification answer while the agent may or may not run: record the
/// answer (the agent sees approvals.json change) and exit. Never takes the agent lock.
@MainActor
func runResponder() -> Never {
    let n = AppNotifier { id, action in
        recordAnswer(id: id, action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
    withExtendedLifetime(n) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
    exit(0)
}
