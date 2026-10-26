import Foundation
import Testing
@testable import ShelfBridgeCore

/// Terminal text, `asking`, the stop/exit rule and the log answer, without tmux.
@Suite struct TerminalTextTests {
    let esc = "\u{1B}"

    @Test func leftoversAndCursorMoves() {
        #expect(LogTail.strip("mark\(esc)(B\(esc)[m\n") == "mark\n", "ESC ( B leaves no B")
        #expect(LogTail.strip("a\(esc)]0;title\(esc)\\b\n") == "ab\n", "OSC ended by ESC \\ leaves no backslash")
        #expect(LogTail.strip("x\(esc)P1$r0m\(esc)\\y\n") == "xy\n", "DCS string dropped")
        #expect(LogTail.strip("Enter\(esc)[8Gto\(esc)[11Gconfirm\n") == "Enter to confirm\n", "column moves are spaces")
        #expect(LogTail.strip("a\(esc)[3Cb\n") == "a b\n")
        #expect(LogTail.strip("top\(esc)[2Bbottom\n") == "top\nbottom\n", "a row move ends the line")
        #expect(LogTail.strip("kept\r\(esc)[1Bnext\n") == "kept\nnext\n", "CR then a row move keeps the line")
        #expect(LogTail.strip("10%\r50%\r100%\n") == "100%\n", "CR then text overwrites")
        #expect(LogTail.strip("abx\u{08}c\n") == "abc\n", "backspace")
        #expect(LogTail.strip("\(esc)7\(esc)[r\(esc)8\(esc)[?25hok\u{0F}\n") == "ok\n")
    }

    /// The folder-trust screen from a real job log, as Claude Code drew it.
    var trustScreen: String {
        [
            "\(esc)[2G\(esc)[1mAccessing\(esc)[12Gworkspace:\(esc)[22m\r\r\n",
            "\(esc)[2GQuick\(esc)[8Gsafety\(esc)[15Gcheck:\(esc)[22GIs\(esc)[25Gthis\(esc)[30Ga\(esc)[32Gproject\(esc)[40Gyou\(esc)[44Gtrust?\r\r\n",
            "\(esc)[2G\(esc)[38;5;153m❯\(esc)[4GNo,\(esc)[8Gexit\(esc)[39m\r\r\n",
            "\(esc)[4GYes,\(esc)[9GI\(esc)[11Gtrust\(esc)[17Gthis\(esc)[22Gfolder\r\r\n",
            "\r\r\n",
            "\(esc)[2G\(esc)[38;5;246mEnter\(esc)[8Gto\(esc)[11Gconfirm\(esc)[19G·\(esc)[21GEsc\(esc)[25Gto\(esc)[28Gcancel\(esc)[39m\r\r\n",
        ].joined()
    }

    @Test func trustPromptIsAsking() {
        let lines = LogTail.lines(trustScreen, 12)
        #expect(lines.last == "Enter to confirm · Esc to cancel")
        #expect(lines.contains("Yes, I trust this folder"))
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: lines, quietFor: 61))
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: lines, quietFor: 20))
    }

    @Test func claudeQuestionScreenIsAsking() {
        let screen = [
            "│ I could not find the portfolio site's code. How should I go on?",
            "❯ 1. I will give the path", "  2. Only a content draft", "  3. Leave it for now", "  4. Type something.",
            "  5. Chat about this", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ]
        #expect(JobSummary.asking(mode: "attended", state: "stalled", lines: screen, quietFor: 400))
    }

    @Test func nowSkipsChrome() {
        let lines = ["⏺ Wrote reports/2026-10-22.md", "❯ ", "-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]
        #expect(JobSummary.now(lines) == "Wrote reports/2026-10-22.md")
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: lines, quietFor: 600))
    }

    @Test func idleInputBoxIsNotNowOrAsking() {
        let rule = String(repeating: "─", count: 40)
        let idle = ["⏺ Done: wrote the list.", rule, "❯ Try \"refactor <filepath>\"", rule,
                    "~/SHELF-TEST · Opus", "-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle)"]
        #expect(JobSummary.now(idle) == "Done: wrote the list.")
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: idle, quietFor: 600))
        let typed = ["⏺ Done.", rule, "❯ is this ok?", rule, "-- INSERT --"]
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: typed, quietFor: 600), "the user's own draft")
        let question = [rule, "← ☐ Site code  ✔ Submit  →", "│ How should I go on?", "❯ 1. I will give the path", "  4. Type something.",
                        rule, "  5. Chat about this", "Enter to select · Esc to cancel"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: question, quietFor: 600))
        #expect(JobSummary.now(question) == "How should I go on?", "the question, not the key hint")
        #expect(!JobSummary.meaningful(question).contains(rule))
        let trust = ["Quick safety check: Is this a project you created or one you trust?", "❯ No, exit",
                     "Yes, I trust this folder", "Enter to confirm · Esc to cancel"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: trust, quietFor: 61), "2.1.308: no 1. numbering")
    }

    @Test func stopCausedTheExitOnlyIfSoon() {
        let t = Date()
        let m = StopMarker(reason: "cancelled", requestedAt: t)
        #expect(m.caused(exitAt: t.addingTimeInterval(3), exitCode: 0))
        #expect(!m.caused(exitAt: t.addingTimeInterval(33), exitCode: 0), "the user typed /exit later")
        #expect(m.caused(exitAt: t.addingTimeInterval(33), exitCode: 130), "slow shutdown by the signal")
        #expect(m.caused(exitAt: t.addingTimeInterval(90), exitCode: 1), "any non-zero exit after a stop")
        var again = m
        again.signalledAt = t.addingTimeInterval(30)
        #expect(again.caused(exitAt: t.addingTimeInterval(33), exitCode: 0), "a repeated stop restarts the window")
        // Markers from older runner versions have no signalledAt.
        let old = #"{"reason":"cancelled","requestedAt":"2026-10-22T17:05:55Z"}"#
        #expect((try? JSONDecoder.iso.decode(StopMarker.self, from: Data(old.utf8)))?.signalledAt == nil)
    }

    @Test func logReplyLimits() throws {
        let few = LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "x", text: "a\r\n\(esc)[1mb\(esc)[0m\r\n", partial: false)
        #expect(few.lines == ["a", "b"] && !few.truncated)

        let many = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        let r = LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "x", text: many, partial: false)
        #expect(r.lines.count == 200 && r.lines.first == "line 100" && r.lines.last == "line 299" && r.truncated)

        let long = LogReply.make(id: "q-20261022T1630-7f3a", state: "done", at: "x", text: String(repeating: "\u{15F}", count: 900), partial: false)
        #expect(long.lines == [String(repeating: "\u{15F}", count: 400)] && long.truncated)

        let big = (0..<200).map { "\($0) " + String(repeating: "x", count: 390) }.joined(separator: "\n")
        let b = LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "x", text: big, partial: false)
        #expect(try b.json().utf8.count <= LogReply.maxBytes)
        #expect(b.truncated && b.lines.last?.hasPrefix("199 ") == true && b.lines.count > 30)

        let partial = LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "x", text: "ial line\nwhole\n", partial: true)
        #expect(partial.lines == ["whole"] && partial.truncated, "a mid-file read drops its first, partial line")
    }

    @Test func newVerbsParse() {
        let key = ProtocolFixture.key
        for verb in [ProtocolV2.Verb.log, .attach] {
            let name = ProtocolV2.commandName(key: key, verb: verb, id: "q-20261022T1630-7f3a", ts: 100)
            #expect(ProtocolV2.parseCommand(name)?.verb == verb)
            #expect(ProtocolV2.parseCommand(name.replacingOccurrences(of: "q-20261022T1630-7f3a", with: "-")) == nil, "needs an id")
        }
    }
}

/// The log answer and `attach` through the ShelfChannel and a real tmux on a private socket; Terminal is stubbed.
@MainActor
@Suite(.serialized, .enabled(if: Fixture.tmux != nil && Fixture.builtRunner != nil))
final class LogAndAttachIntegrationTests {
    let home: TempDir
    let work: TempDir
    let socket = "shelf-bridge-attach-\(UUID().uuidString.prefix(8))"
    let runner: Runner
    let agent: Agent
    var opened: [URL] = []
    var posted: [(String, [String: Any])] = []

    init() throws {
        home = try TempDir("ahome")
        work = try TempDir("awork")
        // From a file: `tick` reloads config.toml and would otherwise fall back to the default tmux server.
        let paths = Paths(home: home.url)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        [agents]
        claude = "\(Fixture.fakeAgent)"
        codex = "\(Fixture.fakeAgent)"
        [tmux]
        path = "\(Fixture.tmux!)"
        socket = "\(socket)"

        """.write(to: paths.configFile, atomically: true, encoding: .utf8)
        runner = Runner(paths: paths, config: try Config.load(from: paths.configFile), wrapExecutable: Fixture.builtRunner!,
                        environment: ["SHELF_BRIDGE_HOME": home.path, "PATH": "/usr/bin:/bin"])
        agent = Agent(paths: runner.paths, runner: runner, notifier: StderrNotifier())
        agent.log = { _ in }
        agent.readings = IdleReadings()
    }

    deinit {
        if let t = Fixture.tmux { _ = try? Exec.run(t, ["-L", socket, "kill-server"]) }
    }

    func start(_ id: String, title: String, seconds: Int) throws {
        let f = try work.sub("Attach-\(id.suffix(4))")
        try "- [ ] \(title) id:\(id) agent:claude by:you\n".write(to: f.appendingPathComponent(QueueGrammar.fileName), atomically: true, encoding: .utf8)
        try "FAKE_SECONDS=\(seconds)\n".write(to: f.appendingPathComponent("fake-agent.env"), atomically: true, encoding: .utf8)
        _ = try runner.enable(f.path)
        _ = try runner.run(id: id)
    }

    func waitForEnd(_ id: String, timeout: TimeInterval = 20) -> RunRecord? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = runner.store.latest(id: id), !JobState.active.contains(r.status) { return r }
            usleep(100_000)
        }
        return runner.store.latest(id: id)
    }

    func bridge() -> ShelfChannel {
        let b = ShelfChannel(agent: agent, builder: StatusBuilder(bridgeVersion: "9.9.9", readings: IdleReadings(), paths: runner.paths))
        b.post = { [unowned self] name, info in self.posted.append((name, info)) }
        return b
    }

    @Test func attachWritesScriptAndStatus() throws {
        let id = "q-20261022T2100-a001"
        try start(id, title: "Secret $(task) text", seconds: 6)
        agent.openTerminal = { [unowned self] url in self.opened.append(url); return true }
        agent.attach(id: id)

        let file = runner.paths.attachFile(id: id)
        #expect(opened == [file])
        let script = try String(contentsOf: file, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("select-window -t '=shelf-Attach-a001:\(id)'"))
        #expect(script.contains("exec '\(Fixture.tmux!)' -L '\(socket)' attach-session -t '=shelf-Attach-a001'"))
        #expect(!script.contains("Secret") && !script.contains("task)"), "no task text")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)

        let status = bridge().builder.build(agent.observe(), paused: false, attachments: agent.attachments)
        let job = try #require(status.jobs.first { $0.id == id })
        #expect(job.attached != nil && job.attachError == nil)
        #expect(job.state == "running")

        #expect(waitForEnd(id)?.status == "done")
        agent.tick()
        #expect(!FileManager.default.fileExists(atPath: file.path), "deleted when the job ends")
        #expect(agent.attachments[id] == nil)
    }

    @Test func attachWithoutSessionIsAnErrorNotAFailure() throws {
        let id = "q-20261022T2100-a002"
        try start(id, title: "Short job", seconds: 0)
        let ended = try #require(waitForEnd(id))
        agent.openTerminal = { [unowned self] url in self.opened.append(url); return true }
        agent.attach(id: id)
        #expect(opened.isEmpty)
        #expect(agent.attachments[id] == Attachment(attached: nil, error: "no-session"))
        #expect(runner.store.latest(id: id)?.status == ended.status, "state unchanged")
    }

    @Test func logAnswerUsesTheLivePaneAndIsRateLimited() throws {
        let id = "q-20261022T2100-a003"
        try start(id, title: "Log job", seconds: 6)
        usleep(800_000)
        let b = bridge()
        let t = Date()
        #expect(b.replyLog(id: id, now: t))
        #expect(!b.replyLog(id: id, now: t.addingTimeInterval(0.5)), "one per second per job")
        #expect(b.replyLog(id: id, now: t.addingTimeInterval(1.1)))
        #expect(!b.replyLog(id: "q-20261022T2100-ffff", now: t), "unknown job: no answer")

        let (name, info) = try #require(posted.first)
        #expect(name == ProtocolV2.logName)
        #expect(info["v"] as? Int == 2 && info["id"] as? String == id)
        let reply = try JSONDecoder().decode(LogReply.self, from: Data(try #require(info["json"] as? String).utf8))
        #expect(reply.id == id && reply.state == "running")
        #expect(reply.lines.contains { $0.hasPrefix("fake-agent: start") })

        agent.tick()  // saves the live screen
        #expect(waitForEnd(id)?.status == "done")
        #expect(b.replyLog(id: id, now: t.addingTimeInterval(5)))
        let done = try JSONDecoder().decode(LogReply.self, from: Data(try #require(posted.last?.1["json"] as? String).utf8))
        #expect(done.state == "done" && done.lines.contains { $0.hasPrefix("fake-agent: start") }, "a finished job answers too")
    }

    /// Print mode writes its result at exit, after the last capture: the log answers, not the screen.
    @Test func finishedUnattendedJobAnswersFromItsLog() throws {
        let id = "q-20261022T2100-a006"
        let f = try work.sub("Attach-a006")
        try "- [ ] Report id:\(id) agent:claude mode:unattended by:you\n".write(to: f.appendingPathComponent(QueueGrammar.fileName), atomically: true, encoding: .utf8)
        try "FAKE_SECONDS=0\n".write(to: f.appendingPathComponent("fake-agent.env"), atomically: true, encoding: .utf8)
        _ = try runner.enable(f.path)
        _ = try runner.run(id: id)
        #expect(waitForEnd(id)?.status == "done")
        usleep(300_000)
        try "STALE SCREEN\n".write(to: runner.paths.screenFile(id: id), atomically: true, encoding: .utf8)
        let b = bridge()
        #expect(b.replyLog(id: id))
        let reply = try JSONDecoder().decode(LogReply.self, from: Data(try #require(posted.last?.1["json"] as? String).utf8))
        #expect(!reply.lines.contains("STALE SCREEN") && reply.lines.contains { $0.hasPrefix("fake-agent: start") })
        let job = try #require(b.builder.build(agent.observe(), paused: false).jobs.first { $0.id == id })
        #expect(!job.log.contains("STALE SCREEN"))
    }

    @Test func exitLongAfterStopKeepsItsExitCode() throws {
        let late = "q-20261022T2100-a004", soon = "q-20261022T2100-a005"
        try start(late, title: "Late exit", seconds: 2)
        try start(soon, title: "Early exit", seconds: 2)
        let enc = JSONEncoder.iso
        try enc.encode(StopMarker(reason: "cancelled", requestedAt: Date().addingTimeInterval(-60))).write(to: runner.paths.stopMarker(id: late))
        try enc.encode(StopMarker(reason: "cancelled", requestedAt: Date())).write(to: runner.paths.stopMarker(id: soon))
        #expect(waitForEnd(late)?.status == "done", "/exit long after the stop is not cancelled")
        #expect(waitForEnd(soon)?.status == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: runner.paths.stopMarker(id: late).path))
    }
}
