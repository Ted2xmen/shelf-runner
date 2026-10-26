import Foundation
import Testing
@testable import ShelfBridgeCore

/// A line appears and the job starts by itself; the line goes and the job stops.
/// Runs the real `shelf-bridge agent` against a temp home, a private tmux socket and the fake agent.
@Suite(.serialized, .enabled(if: Fixture.tmux != nil && Fixture.builtRunner != nil))
final class AgentIntegrationTests {
    let home: TempDir
    let work: TempDir
    let socket = "shelf-bridge-agent-test-\(UUID().uuidString.prefix(8))"
    var agent: Process?
    let store: RunStore
    let paths: Paths

    init() throws {
        home = try TempDir("ahome")
        work = try TempDir("awork")
        paths = Paths(home: home.url)
        store = RunStore(file: paths.runsFile)
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        [agents]
        claude = "\(Fixture.fakeAgent)"
        codex = "\(Fixture.fakeAgent)"
        [tmux]
        path = "\(Fixture.tmux!)"
        socket = "\(socket)"
        [bridge]
        stall_seconds = 2
        max_runtime_seconds = 8
        cancel_grace_seconds = 2
        max_parallel = 5

        """.write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    deinit {
        if ProcessInfo.processInfo.environment["SHOW_AGENT_ERR"] == "1",
           let e = try? String(contentsOf: home.url.appendingPathComponent("agent.err"), encoding: .utf8) { print("AGENT STDERR:\n" + e) }
        agent?.terminate()
        agent?.waitUntilExit()
        if let t = Fixture.tmux { _ = try? Exec.run(t, ["-L", socket, "kill-server"]) }
    }

    /// Pairs once; the start gate makes every line need a signature and an approval.
    func pair() throws {
        if KeyStore.load(paths) == nil { #expect(try cli(["pair"]).status == 0) }
    }

    /// A line signed by `shelf-bridge line`, optionally approved first.
    func signed(_ f: URL, _ title: String, agent: String = "claude", approve: Bool = true, extra: [String] = []) throws -> (id: String, line: String) {
        try pair()
        let out = try cli(["line", f.path, agent] + title.split(separator: " ").map(String.init) + extra)
        let line = out.text.split(separator: "\n").first { $0.hasPrefix("- [ ] ") }.map(String.init) ?? ""
        let id = String(line.split(separator: " ").first { $0.hasPrefix("id:") }?.dropFirst(3) ?? "")
        #expect(QueueGrammar.isValidID(id), "line: \(out.text)")
        if approve { #expect(try cli(["approve", id]).status == 0) }
        return (id, line)
    }

    func cli(_ args: [String]) throws -> Exec.Output {
        try Exec.run(Fixture.builtRunner!, args, environment: ["SHELF_BRIDGE_HOME": home.path, "PATH": "/usr/bin:/bin"])
    }

    func startAgent() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Fixture.builtRunner!)
        p.arguments = ["agent"]
        p.environment = ["SHELF_BRIDGE_HOME": home.path, "PATH": "/usr/bin:/bin", "SHELF_BRIDGE_TICK_SECONDS": "0.5",
                         "SHELF_BRIDGE_FIXED_READINGS": "1"]
        FileManager.default.createFile(atPath: home.url.appendingPathComponent("agent.err").path, contents: nil)
        p.standardError = try FileHandle(forWritingTo: home.url.appendingPathComponent("agent.err"))
        try p.run()
        agent = p
    }

    func folder(_ name: String, fake: String = "") throws -> URL {
        let f = try work.sub(name)
        try fake.write(to: f.appendingPathComponent("fake-agent.env"), atomically: true, encoding: .utf8)
        try "# queue\n".write(to: f.appendingPathComponent(QueueGrammar.fileName), atomically: true, encoding: .utf8)
        #expect(try cli(["enable", f.path]).status == 0)
        return f
    }

    func append(_ f: URL, _ line: String) throws {
        let h = try FileHandle(forWritingTo: f.appendingPathComponent(QueueGrammar.fileName))
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        try h.close()
    }

    func remove(_ f: URL, id: String) throws {
        let url = f.appendingPathComponent(QueueGrammar.fileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(id) }
            .joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Waits until the job's status satisfies `ok`; returns the statuses seen on the way.
    @discardableResult
    func wait(_ id: String, timeout: TimeInterval = 20, until ok: (String) -> Bool) -> [String] {
        var seen: [String] = []
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let s = store.latest(id: id)?.status {
                if seen.last != s { seen.append(s) }
                if ok(s) { return seen }
            }
            usleep(100_000)
        }
        return seen
    }

    @Test func lifecycle() throws {
        try startAgent()
        let ok = try folder("Okay")
        let long = try folder("Long", fake: "FAKE_SECONDS=60\n")
        let slow = try folder("Slow", fake: "FAKE_SECONDS=60\n")
        let stubborn = try folder("Stubborn", fake: "FAKE_SECONDS=60\nFAKE_IGNORE_INT=1\n")

        // Appended line starts by itself and finishes.
        let (a, la) = try signed(ok, "Starts by itself")
        try append(ok, la)
        #expect(wait(a) { $0 == "done" }.last == "done")

        // Removed line: Ctrl-C, recorded as cancelled (by wrap, through the stop marker).
        let (b, lb) = try signed(long, "Long job")
        try append(long, lb)
        #expect(wait(b) { $0 == "running" }.last == "running")
        try remove(long, id: b)
        #expect(wait(b) { $0 == "cancelled" }.last == "cancelled")

        // Silent past stall_seconds: stalled; past max_runtime: stopped as failed:timeout.
        let (c, lc) = try signed(slow, "Quiet job", agent: "codex")
        try append(slow, lc)
        let seenC = wait(c) { $0.hasPrefix("failed") }
        #expect(seenC.contains("stalled"))
        #expect(seenC.last == "failed:timeout")

        // Ignores Ctrl-C: after the grace the window is closed and the agent records the reason.
        let (ticked, lt) = try signed(stubborn, "A checked job does not start")
        try append(stubborn, lt.replacingOccurrences(of: "- [ ] ", with: "- [x] "))
        let (d, ld) = try signed(stubborn, "Stubborn job")
        try append(stubborn, ld)
        #expect(wait(d) { $0 == "running" || $0 == "stalled" }.isEmpty == false)
        try remove(stubborn, id: d)
        #expect(wait(d) { $0 == "cancelled" }.last == "cancelled")
        let window = store.latest(id: d)?.tmuxWindow ?? ""
        #expect(try Exec.run(Fixture.tmux!, ["-L", socket, "list-panes", "-t", window]).status != 0, "window closed")
        #expect(store.latest(id: ticked) == nil, "a ticked line never starts")

        // A second agent refuses to run.
        let second = try cli(["agent"])
        #expect(second.status != 0 && second.text.contains("already running"))

        // status shows the outcome.
        let st = try cli(["status"]).text
        #expect(st.contains("agent: running"))
        #expect(st.contains("\(a)  done"))
    }

    /// An unsigned line does not run; a new id does not run without approval;
    /// `..` escape is refused.
    @Test func security() throws {
        try startAgent()
        let f = try folder("Safety")

        let unsigned = "q-20261022T1700-0e01"
        try append(f, "- [ ] Unsigned id:\(unsigned) agent:claude")
        #expect(wait(unsigned) { $0 == "waiting:signature" }.last == "waiting:signature")

        let (pending, lp) = try signed(f, "Waits for approval", approve: false)
        try append(f, lp)
        #expect(wait(pending) { $0 == "needs-approval" }.last == "needs-approval")
        usleep(1_500_000)
        #expect(store.latest(id: pending)?.status == "needs-approval", "does not start on its own")
        #expect(try cli(["approve", pending]).status == 0)
        #expect(wait(pending) { $0 == "done" }.last == "done")

        let (ignored, li) = try signed(f, "To be ignored", approve: false)
        try append(f, li)
        #expect(wait(ignored) { $0 == "needs-approval" }.last == "needs-approval")
        #expect(try cli(["ignore", ignored]).status == 0)
        #expect(wait(ignored) { $0 == "cancelled" }.last == "cancelled")

        let (tampered, lx) = try signed(f, "Harmless task")
        try append(f, lx.replacingOccurrences(of: "Harmless task", with: "Evil task"))
        #expect(wait(tampered) { $0 == "waiting:signature" }.last == "waiting:signature")

        let (escape, le) = try signed(f, "Write outside", extra: ["--out", "../outside"])
        try append(f, le)
        #expect(wait(escape) { $0 == "failed:path" }.last == "failed:path")

        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent("link"), withDestinationURL: work.url)
        let (viaLink, ll) = try signed(f, "Through a link", extra: ["--out", "link/x.md"])
        try append(f, ll)
        #expect(wait(viaLink) { $0 == "failed:path" }.last == "failed:path")

        // Re-pairing invalidates lines signed with the old key, approval or not.
        let (stale, ls) = try signed(f, "Old key")
        #expect(try cli(["pair"]).status == 0)
        try append(f, ls)
        #expect(wait(stale) { $0 == "waiting:signature" }.last == "waiting:signature")

        #expect(!FileManager.default.fileExists(atPath: work.url.appendingPathComponent("outside").path))
    }

    /// A weekly line due a minute ago asks for approval once, then runs its occurrence.
    @Test func scheduledOccurrenceRuns() throws {
        try startAgent()
        let f = try folder("Calendar")
        try pair()
        let key = try #require(KeyStore.load(Paths(home: home.url)))
        let folderPath = try FolderRegistry.canonical(f.path)
        let when = Date().addingTimeInterval(-60)
        let day = DateFormatter(), time = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"; time.dateFormat = "HH:mm"
        let id = "s-20261022T1640-e5a1"
        var line = "- Weekly report due:\(day.string(from: when)) every:week at:\(time.string(from: when)) id:\(id) agent:codex mode:unattended"
        guard case .success(let item)? = ScheduledGrammar.parseLine(line) else { Issue.record("no parse"); return }
        line += " sig:\(ProtocolV2.lineSig(key: key, item: item, folder: folderPath))"
        try (line + "\n").write(to: f.appendingPathComponent(ScheduledGrammar.fileName), atomically: true, encoding: .utf8)

        #expect(wait(id) { $0 == "needs-approval" }.last == "needs-approval")
        #expect(try cli(["approve", id]).status == 0)
        #expect(wait(id) { $0 == "done" }.last == "done")
        let r = try #require(store.latest(id: id))
        #expect(r.occurrence.flatMap(ISO.parse) == item.schedule?.around(Date()).last)
        usleep(1_500_000)
        #expect(store.latest(id: id)?.status == "done", "the same occurrence does not run twice")
        #expect(try cli(["list"]).text.contains("\(id)  codex/scheduled  next"))
    }
}

