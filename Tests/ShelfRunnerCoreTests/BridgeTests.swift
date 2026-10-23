import Foundation
import Testing
@testable import ShelfRunnerCore

@MainActor
@Suite struct BridgeTests {
    let home: TempDir
    let work: TempDir
    let paths: Paths
    let agent: Agent
    let folder: URL

    init() throws {
        home = try TempDir("bhome")
        work = try TempDir("bwork")
        paths = Paths(home: home.url)
        try paths.ensureDirectories()
        var config = Config()
        config.tmuxSocket = "shelf-runner-bridge-unused"
        let runner = Runner(paths: paths, config: config, wrapExecutable: "/usr/bin/false", environment: [:])
        agent = Agent(paths: paths, runner: runner, notifier: StderrNotifier())
        agent.log = { _ in }
        agent.readings = IdleReadings()
        folder = try work.sub("Bridge")
        _ = try runner.enable(folder.path)
    }

    var builder: StatusBuilder { StatusBuilder(runnerVersion: "9.9.9", readings: IdleReadings(), paths: paths) }

    func rec(_ id: String, _ status: String, endedHoursAgo: Double? = nil, title: String? = "t") -> RunRecord {
        let now = Date()
        return RunRecord(id: id, folder: folder.path, status: status, agent: "claude", mode: "attended", title: title,
                         startedAt: Clock.iso(now.addingTimeInterval(-3600 * (endedHoursAgo ?? 0) - 60)),
                         endedAt: endedHoursAgo.map { Clock.iso(now.addingTimeInterval(-3600 * $0)) },
                         tmuxSession: "shelf-Bridge", logPath: paths.logFile(id: id).path,
                         at: Clock.iso(now.addingTimeInterval(-3600 * (endedHoursAgo ?? 0))))
    }

    @Test func scheduledListAndIdleJobsHidden() throws {
        let id = "s-20261022T1640-b20d"
        try "- Report due:2026-10-26 at:09:00 every:week id:\(id) agent:codex mode:unattended\n- Ended due:2020-01-01 id:s-20261022T1641-c31e agent:claude mode:unattended\n"
            .write(to: folder.appendingPathComponent(ScheduledGrammar.fileName), atomically: true, encoding: .utf8)
        var r = rec(id, JobState.scheduled); r.startedAt = nil
        try agent.runner.store.append(r)
        let s = builder.build(agent.observe(), paused: false)
        #expect(s.jobs.isEmpty, "an idle scheduled job is not a job")
        #expect(s.scheduled.map(\.id) == [id, "s-20261022T1641-c31e"], "soonest first, ended series last")
        #expect(s.scheduled[0].next.flatMap(ISO.parse).map { $0 > Date() } == true)
        #expect(s.scheduled[1].next == nil)
    }

    @Test func statusContents() throws {
        let store = agent.runner.store
        try store.append(rec("q-20261022T1700-0001", "done", endedHoursAgo: 2))
        try store.append(rec("q-20261022T1700-0002", "done", endedHoursAgo: 30))
        try store.append(rec("q-20261022T1700-0003", "running"))
        try store.append(rec("q-20261022T1700-0004", "needs-approval", title: nil))
        try "- [ ] Title from the line id:q-20261022T1700-0004 agent:claude\n"
            .write(to: folder.appendingPathComponent(QueueGrammar.fileName), atomically: true, encoding: .utf8)
        try "\u{1B}[32mone\u{1B}[0m\ntwo\r\nth\u{E9}\rTH\u{C9}\n\(String(repeating: "x", count: 300))\n"
            .write(to: paths.logFile(id: "q-20261022T1700-0003"), atomically: true, encoding: .utf8)

        let s = builder.build(agent.observe(), paused: false)
        #expect(s.v == 1 && s.runner == "9.9.9" && s.keyId == nil && s.folders == [folder.path])
        #expect(s.jobs.map(\.id) == ["q-20261022T1700-0003", "q-20261022T1700-0004", "q-20261022T1700-0001"],
                "active, then pending, then finished in the last 24 h; 30 h old dropped")
        let running = s.jobs[0]
        #expect(running.log == ["two", "TH\u{C9}", String(repeating: "x", count: 200)], "escapes stripped, CR overwrite, 200 chars")
        #expect(running.tmux == "shelf-Bridge:q-20261022T1700-0003")
        #expect(s.jobs[1].title == "Title from the line", "title falls back to the queue line")

        _ = try KeyStore.pair(paths)
        #expect(builder.build(agent.observe(), paused: true).keyId == KeyStore.load(paths).map(ProtocolV1.keyId))
    }

    @Test func clampKeepsUnder16KB() {
        let big = (0..<80).map { i in
            StatusV1.Job(id: String(format: "q-20261022T1700-%04x", i), folder: "/f", ref: nil, title: String(repeating: "\u{E9}", count: 150),
                         agent: "claude", mode: "attended", state: i < 5 ? "running" : "done", started: "s", ended: i < 5 ? nil : "e",
                         tmux: nil, log: Array(repeating: String(repeating: "y", count: 300), count: 5), out: nil)
        }
        let s = StatusV1(runner: "1", seen: "s", keyId: nil, paused: false, slots: .init(max: 2, perFolder: 1, running: 0),
                         mac: IdleReadings().read(), limits: [],
                         folders: [], jobs: big, scheduled: []).clamped()
        #expect(((try? s.json()) ?? "").utf8.count < StatusV1.maxBytes)
        #expect(s.jobs.count <= 50)
        #expect(s.jobs.prefix(5).allSatisfy { $0.ended == nil }, "running jobs are kept, finished ones dropped first")
    }

    @Test func commands() throws {
        let id = "q-20261022T1700-0005"
        try agent.runner.store.append(rec(id, "needs-approval"))
        agent.apply(.init(verb: .ignore, id: id, ts: 0, sig: ""))
        #expect(Approvals.load(paths).entries[id]?.decision == .ignore)
        #expect(Approvals.load(paths).entries[id]?.via == "shelf")

        agent.apply(.init(verb: .pause, id: nil, ts: 0, sig: ""))
        #expect(agent.paused)
        #expect(builder.build(agent.observe(), paused: agent.paused).paused)
        agent.apply(.init(verb: .resume, id: nil, ts: 0, sig: ""))
        #expect(!agent.paused)

        let pending = "q-20261022T1700-0006"
        try agent.runner.store.append(rec(pending, "queued"))
        agent.apply(.init(verb: .stop, id: pending, ts: 0, sig: ""))
        #expect(agent.runner.store.latest(id: pending)?.status == "cancelled")

        agent.apply(.init(verb: .requeue, id: pending, ts: 0, sig: ""))
        #expect(agent.runner.store.latest(id: pending)?.status == "queued")
        #expect(Approvals.load(paths).entries[pending]?.decision == .run)

        // Shelf's "Take it back" on a failed job ends it; on any other state only the approval.
        let failed = "q-20261022T1700-0008"
        try agent.runner.store.append(rec(failed, "failed:timeout"))
        agent.apply(.init(verb: .ignore, id: failed, ts: 0, sig: ""))
        #expect(agent.runner.store.latest(id: failed)?.status == "cancelled")
        #expect(Approvals.load(paths).entries[failed] == nil, "no lasting ignore: a schedule's next run still goes")
        #expect(agent.runner.store.latest(id: id)?.status == "needs-approval", "ignore on a first run stays an approval")
    }

    @Test func pausedPlansNoStarts() {
        let q = QueueGrammar.parse("- [ ] job id:q-20261022T1700-0007 agent:claude\n")
        var s = Snapshot(enabledFolders: ["/f"], queues: ["/f": q], records: [:], now: Date())
        s.paused = true
        #expect(Supervisor(policy: Policy()).plan(s) == [.setStatus(id: "q-20261022T1700-0007", status: "waiting:paused")])
    }
}

@Suite struct LogTailTests {
    @Test func paneLogShapes() {
        #expect(LogTail.strip("a\r\nb\r\n") == "a\nb\n", "CRLF is a line end")
        #expect(LogTail.strip("10%\r50%\r100%\n") == "100%\n", "lone CR overwrites")
        #expect(LogTail.strip("\u{1B}[1;32mok\u{1B}[0m \u{1B}]0;title\u{07}x\n") == "ok x\n")
        #expect(LogTail.lines("a\n\n  b  \nc\nd\n", 3) == ["b", "c", "d"])
    }
}


@Suite struct LimitsAndSummaryTests {
    @Test func claudeFromTeeAndCodexFromRollout() throws {
        let home = try TempDir("lim")
        let paths = Paths(home: home.url)
        let now = Date()
        let statusline = #"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":34.2,"resets_at":1792681200},"seven_day":{"used_percentage":61,"resets_at":1793095200}}}"#
        LimitsTee.save(Data(statusline.utf8), paths: paths)
        #expect(LimitsTee.summary(Data(statusline.utf8)) == "Opus · 5h 34% · week 61%")
        #expect(LimitsTee.summary(Data("{}".utf8)) == "shelf-runner")

        let day = home.url.appendingPathComponent(".codex/sessions/2026/10/22")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":1792681200},"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1793095200}}}}
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"window_minutes":300,"resets_at":1792681200},"secondary":{"used_percent":41,"window_minutes":10080,"resets_at":1793095200}}}}

        """.write(to: day.appendingPathComponent("rollout-2026-10-22T16-00-00-x.jsonl"), atomically: true, encoding: .utf8)

        let limits = LimitsReader(paths: paths).read(now: now)
        #expect(limits.map(\.agent) == ["claude", "codex"])
        #expect(limits[0].source == "statusline" && limits[0].fiveHour == 34.2 && limits[0].week == 61)
        #expect(limits[0].resetsFiveHour == Clock.iso(Date(timeIntervalSince1970: 1792681200)))
        #expect(limits[1].source == "session" && limits[1].fiveHour == 12 && limits[1].week == 41, "last event wins")

        #expect(LimitsReader(paths: paths).read(now: now.addingTimeInterval(16 * 60)).isEmpty, "older than 15 min: unknown")
    }

    @Test func codexFreePlanMonthlyWindowIsNotAFiveHourLimit() throws {
        let home = try TempDir("lim2")
        let day = home.url.appendingPathComponent(".codex/sessions/2026/10/22")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try #"{"payload":{"rate_limits":{"primary":{"used_percent":6,"window_minutes":43200,"resets_at":1795039836},"secondary":null}}}"#
            .appending("\n").write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        #expect(LimitsReader(paths: Paths(home: home.url)).read().isEmpty)
    }

    @Test func teeCommandPassesBytesThrough() throws {
        guard let bin = Fixture.builtRunner else { return }
        let home = try TempDir("tee")
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1}}}"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["limits-tee"]
        p.environment = ["SHELF_RUNNER_HOME": home.path]
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o
        try p.run()
        i.fileHandleForWriting.write(Data(input.utf8)); try i.fileHandleForWriting.close()
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(out == Data(input.utf8), "same bytes on stdout")
        #expect(try Data(contentsOf: LimitsReader.claudeFile(Paths(home: home.url))) == Data(input.utf8))
    }

    @Test func nowAndAsking() {
        #expect(JobSummary.now(["Reading CHANGELOG.md", "╰────────╯", "❯ ", "⏺ Wrote docs/release-1.4.md"]) == "Wrote docs/release-1.4.md")
        #expect(JobSummary.now(["───", "> "]) == nil)
        #expect(JobSummary.now([String(repeating: "a", count: 300)])?.count == 120)
        let prompt = ["Editing x", "│ Do you want to allow edits to Paywall.swift? (y/n)"]
        #expect(JobSummary.asking(mode: "attended", state: "stalled", lines: prompt, quietFor: 61))
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: prompt, quietFor: 30), "not quiet long enough")
        #expect(!JobSummary.asking(mode: "unattended", state: "running", lines: prompt, quietFor: 600))
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: ["Building module 7"], quietFor: 600))
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: ["Which file should I use?"], quietFor: 90))
    }
}

@MainActor
@Suite struct WaitingClockTests {
    @Test func waitingSinceStartsOnEntryAndClears() throws {
        let home = try TempDir("wait"), work = try TempDir("waitw")
        let paths = Paths(home: home.url)
        let runner = Runner(paths: paths, config: Config(), wrapExecutable: "/usr/bin/false", environment: [:])
        let agent = Agent(paths: paths, runner: runner, notifier: StderrNotifier())
        agent.log = { _ in }
        agent.readings = IdleReadings()
        let f = try work.sub("W")
        _ = try runner.enable(f.path)
        let id = "q-20261022T1700-0aa1"
        try "- [ ] job id:\(id) agent:claude\n".write(to: f.appendingPathComponent(QueueGrammar.fileName), atomically: true, encoding: .utf8)
        let t0 = Date(), o = agent.observe(now: t0)
        agent.append(id: id, status: "waiting:slot", o, now: t0)
        let since = runner.store.latest(id: id)?.waitingSince
        #expect(since == Clock.iso(t0))
        agent.append(id: id, status: "waiting:slot", agent.observe(), now: t0.addingTimeInterval(300))
        #expect(runner.store.latest(id: id)?.waitingSince == since, "same reason keeps the clock")
        agent.append(id: id, status: "waiting:folder", agent.observe(), now: t0.addingTimeInterval(400))
        #expect(runner.store.latest(id: id)?.waitingSince == Clock.iso(t0.addingTimeInterval(400)), "new reason restarts it")
        agent.append(id: id, status: "needs-approval", agent.observe(), now: t0.addingTimeInterval(500))
        #expect(runner.store.latest(id: id)?.waitingSince == nil)
    }

    struct HotReadings: MacReadings {
        func read() -> StatusV1.Mac { .init(memory: "normal", diskFreeGB: 50, battery: "charging", thermal: "critical") }
        func diskFreeGB(atPath path: String) -> Double? { 3 }
    }

    @Test func resourcesAreReadOnlyWhenALineCouldStart() throws {
        let home = try TempDir("res"), work = try TempDir("resw")
        let paths = Paths(home: home.url)
        let runner = Runner(paths: paths, config: Config(), wrapExecutable: "/usr/bin/false", environment: [:])
        let agent = Agent(paths: paths, runner: runner, notifier: StderrNotifier())
        agent.log = { _ in }
        agent.readings = HotReadings()
        let f = try work.sub("R")
        let folder = try runner.enable(f.path).path
        let queue = f.appendingPathComponent(QueueGrammar.fileName)
        try "- [x] done id:q-20261022T1700-0bb1 agent:claude\n".write(to: queue, atomically: true, encoding: .utf8)
        #expect(agent.observe().snapshot.resources == Resources(), "nothing could start: no readings")
        try "- [ ] new id:q-20261022T1700-0bb2 agent:claude\n".write(to: queue, atomically: true, encoding: .utf8)
        let res = agent.observe().snapshot.resources
        #expect(res.mac?.thermal == "critical")
        #expect(res.folderDiskGB == [folder: 3])
        #expect(Supervisor(policy: Policy()).resourceHold(QueueGrammar.parse(try String(contentsOf: queue, encoding: .utf8)).items[0],
                                                          folder: folder, busy: false, res) == "disk")
    }
}
