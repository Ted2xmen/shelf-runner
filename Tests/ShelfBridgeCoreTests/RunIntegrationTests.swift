import Foundation
import Testing
@testable import ShelfBridgeCore

/// A hand-written line starts in tmux via `run <id>` and ends `done` or `failed:<code>`.
/// Uses the real tmux on a private socket, the real `wrap`, and the fake agent.
@Suite(.serialized, .enabled(if: Fixture.tmux != nil && Fixture.builtRunner != nil))
final class RunIntegrationTests {
    let home: TempDir
    let work: TempDir
    let socket = "shelf-bridge-test-\(UUID().uuidString.prefix(8))"
    let runner: Runner

    init() throws {
        home = try TempDir("home")
        work = try TempDir("work")
        var config = Config()
        config.agentPaths = [.claude: Fixture.fakeAgent, .codex: Fixture.fakeAgent]
        config.tmuxPath = Fixture.tmux
        config.tmuxSocket = socket
        runner = Runner(paths: Paths(home: home.url), config: config, wrapExecutable: Fixture.builtRunner!,
                        environment: ["SHELF_BRIDGE_HOME": home.path, "PATH": "/usr/bin:/bin"])
    }

    deinit {
        if let t = Fixture.tmux { _ = try? Exec.run(t, ["-L", socket, "kill-server"]) }
    }

    func folder(_ name: String, queue: String, fake: String = "") throws -> URL {
        let f = try work.sub(name)
        try queue.write(to: f.appendingPathComponent(QueueGrammar.fileName), atomically: true, encoding: .utf8)
        try fake.write(to: f.appendingPathComponent("fake-agent.env"), atomically: true, encoding: .utf8)
        _ = try runner.enable(f.path)
        return f
    }

    func waitForEnd(_ id: String, timeout: TimeInterval = 20) -> RunRecord? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = runner.store.latest(id: id), r.status != "running" { return r }
            usleep(100_000)
        }
        return runner.store.latest(id: id)
    }

    @Test func doneWithLogAndNoShell() throws {
        let id = "q-20261022T1600-0a01"
        let f = try folder("Okay", queue: "- [ ] Write a note $(touch PWNED) `touch PWNED2`; echo x id:\(id) agent:claude by:you\n")
        let started = try runner.run(id: id)
        #expect(started.record.status == "running")
        #expect(started.record.tmuxSession == "shelf-Okay")
        #expect(started.attach == "tmux -L \(socket) attach -t shelf-Okay")

        let r = try #require(waitForEnd(id))
        #expect(r.status == "done")
        #expect(r.exitCode == 0)
        #expect(r.startedAt != nil && r.endedAt != nil)
        #expect(r.folder == f.path)

        #expect(!FileManager.default.fileExists(atPath: f.appendingPathComponent("PWNED").path))
        #expect(!FileManager.default.fileExists(atPath: f.appendingPathComponent("PWNED2").path))
        usleep(300_000)
        let log = try String(contentsOf: runner.paths.logFile(id: id), encoding: .utf8)
        #expect(log.contains("fake-agent: start pwd=\(f.path)"))
        #expect(log.contains("arg=[\(Prompt.preamble)"))
        #expect(log.contains("Write a note $(touch PWNED) `touch PWNED2`; echo x"))
        #expect(!FileManager.default.fileExists(atPath: runner.paths.startSignal(id: id).path))
    }

    /// An unattended job ends in print mode with the restricted template and no bypass flag.
    @Test(arguments: QueueItem.Agent.allCases)
    func unattendedRunsInPrintMode(agent: QueueItem.Agent) throws {
        let id = agent == .claude ? "q-20261022T1600-0c01" : "q-20261022T1600-0c02"
        _ = try folder("Unattended-\(agent.rawValue)", queue: "- [ ] Write a report id:\(id) agent:\(agent.rawValue) mode:unattended\n")
        let started = try runner.run(id: id)
        #expect(started.record.mode == "unattended")
        let r = try #require(waitForEnd(id))
        #expect(r.status == "done")
        usleep(300_000)
        let log = try String(contentsOf: runner.paths.logFile(id: id), encoding: .utf8)
        let args = log.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("arg=[") }.map(String.init)
        let template = CLIAgentCommand(agent: agent, executable: Fixture.fakeAgent).template(mode: .unattended).dropFirst()
        #expect(Array(args.prefix(template.count)) == template.map { "arg=[\($0)]" })
        #expect(log.contains(Prompt.unattendedNote))
        for flag in PermissionGuardTests.knownBypassFlags { #expect(!log.lowercased().contains("arg=[\(flag.lowercased())")) }
        // The fake prints its argv, not JSON: Claude's output is malformed, logged raw, `blocked` unknown.
        #expect(r.blocked == nil)
        #expect(FileManager.default.fileExists(atPath: runner.paths.resultFile(id: id).path) == (agent == .claude))
    }

    /// Unattended Claude's JSON result. The log gets the `result` text (pane stderr stays), the raw
    /// JSON is kept, `blocked` is the denial count, and a denial leaves exit 0 `done`.
    @Test(arguments: [(2, "q-20261022T1600-0d01"), (0, "q-20261022T1600-0d02")])
    func unattendedClaudeResult(denials: Int, id: String) throws {
        let list = Array(repeating: #"{"tool_name":"Write","tool_use_id":"t","tool_input":{}}"#, count: denials).joined(separator: ",")
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"Summary written\nCould not write outside the folder","permission_denials":["# + list + "]}"
        _ = try folder("Result-\(denials)", queue: "- [ ] Summarize id:\(id) agent:claude mode:unattended\n", fake: "FAKE_JSON='\(json)'\n")
        _ = try runner.run(id: id)
        let r = try #require(waitForEnd(id))
        #expect(r.status == "done" && r.exitCode == 0)
        #expect(r.blocked == denials)
        usleep(300_000)
        let log = try String(contentsOf: runner.paths.logFile(id: id), encoding: .utf8)
        #expect(log.contains("Summary written\nCould not write outside the folder\n"))
        #expect(log.contains("fake-agent: start"))
        #expect(!log.contains("permission_denials"), "the log carries the text, not the JSON")
        let raw = try String(contentsOf: runner.paths.resultFile(id: id), encoding: .utf8)
        #expect(raw == json + "\n")
    }

    /// Attended Claude keeps the tty for stdout and has no `blocked`.
    @Test func attendedClaudeHasNoResultFile() throws {
        let id = "q-20261022T1600-0d03"
        _ = try folder("Attended", queue: "- [ ] Write id:\(id) agent:claude\n", fake: "FAKE_JSON='{\"permission_denials\":[1]}'\n")
        _ = try runner.run(id: id)
        let r = try #require(waitForEnd(id))
        #expect(r.status == "done" && r.blocked == nil)
        #expect(!FileManager.default.fileExists(atPath: runner.paths.resultFile(id: id).path))
        usleep(300_000)
        #expect(try String(contentsOf: runner.paths.logFile(id: id), encoding: .utf8).contains("permission_denials"))
    }

    @Test func failedExitCode() throws {
        let id = "q-20261022T1600-0a02"
        _ = try folder("Fails", queue: "- [ ] Break id:\(id) agent:codex\n", fake: "FAKE_EXIT=3\n")
        _ = try runner.run(id: id)
        let r = try #require(waitForEnd(id))
        #expect(r.status == "failed:3")
        #expect(r.exitCode == 3)
    }

    @Test func alreadyRunningThenInterrupted() throws {
        let id = "q-20261022T1600-0a03"
        _ = try folder("Long", queue: "- [ ] Long job id:\(id) agent:claude\n", fake: "FAKE_SECONDS=30\n")
        let s = try runner.run(id: id)
        #expect(throws: RunnerError.alreadyRunning(id, session: "shelf-Long")) { try runner.run(id: id) }
        usleep(500_000)
        let pane = try Exec.run(Fixture.tmux!, ["-L", socket, "list-panes", "-t", s.record.tmuxWindow!, "-F", "#{pane_id}"])
        try runner.tmux().interrupt(pane: pane.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let r = try #require(waitForEnd(id))
        #expect(r.status == "failed:130")
    }

    @Test func refusals() throws {
        _ = try folder("Rejected", queue: """
        - [x] Checked id:q-20261022T1600-0b01 agent:claude
        - [ ] Broken id:q-20261022T1600-0b03 agent:gpt

        """)
        #expect(throws: RunnerError.alreadyChecked("q-20261022T1600-0b01")) { try runner.run(id: "q-20261022T1600-0b01") }
        #expect(throws: RunnerError.invalidLine(id: "q-20261022T1600-0b03", line: 2, reason: "agent: invalid value 'gpt'")) {
            try runner.run(id: "q-20261022T1600-0b03")
        }
        #expect(throws: RunnerError.idNotFound("q-20261022T1600-0b09")) { try runner.run(id: "q-20261022T1600-0b09") }
        #expect(throws: RunnerError.usage("invalid id: ../x")) { try runner.run(id: "../x") }
        #expect(runner.store.latest().isEmpty, "nothing started")
    }

    @Test func disabledFolderIsIgnored() throws {
        let id = "q-20261022T1600-0c01"
        let f = try folder("Closed", queue: "- [ ] Job id:\(id) agent:claude\n")
        _ = try runner.disable(f.path)
        #expect(throws: RunnerError.idNotFound(id)) { try runner.run(id: id) }
    }

    @Test func runnerNeverWritesTheQueue() throws {
        let id = "q-20261022T1600-0d01"
        let queue = "- [ ] Do not touch id:\(id) agent:claude\n"
        let f = try folder("ReadOnly", queue: queue)
        let before = try FileManager.default.attributesOfItem(atPath: f.appendingPathComponent(QueueGrammar.fileName).path)
        _ = try runner.run(id: id)
        _ = waitForEnd(id)
        let after = try FileManager.default.attributesOfItem(atPath: f.appendingPathComponent(QueueGrammar.fileName).path)
        #expect(try String(contentsOf: f.appendingPathComponent(QueueGrammar.fileName), encoding: .utf8) == queue)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }
}

@Suite struct TmuxNamingTests {
    @Test func sessionNames() {
        #expect(Tmux.sessionName(folder: "/a/Pantheon") == "shelf-Pantheon")
        #expect(Tmux.sessionName(folder: "/a/my.app: v2") == "shelf-my_app__v2")
        #expect(Tmux.sessionName(folder: "/a/R\u{E9}sum\u{E9}") == "shelf-R_sum_", "non-ASCII letters become _")
    }

    @Test func wrapArgsRoundTrip() throws {
        let o = try Wrap.parse(["--id", "q-20261022T1600-0a01", "--folder", "/f", "--agent", "claude", "--mode", "attended",
                                "--", "/bin/claude", "-- not a flag"])
        #expect(o.argv == ["/bin/claude", "-- not a flag"])
        #expect(throws: RunnerError.self) { try Wrap.parse(["--id", "bad", "--folder", "/f", "--agent", "a", "--mode", "m", "--", "x"]) }
        #expect(throws: RunnerError.self) { try Wrap.parse(["--id", "q-20261022T1600-0a01"]) }
    }
}

/// Window ids restart at @0 with each tmux server: identity is id + name.
@Suite(.enabled(if: Fixture.tmux != nil))
struct TmuxIdentityTests {
    @Test func reusedWindowIdIsNotTheSameJob() throws {
        let tmux = Tmux(executable: Fixture.tmux!, socket: "shelf-bridge-ident-\(UUID().uuidString.prefix(8))")
        defer { _ = try? tmux.tmux(["kill-server"]) }
        let a = try tmux.openWindow(session: "shelf-A", windowName: "q-20261022T1900-000a", cwd: "/tmp", environment: [:],
                                    command: ["/bin/sleep", "3"])
        #expect(tmux.windowAlive(a.windowID, name: "q-20261022T1900-000a"))
        usleep(3_800_000)  // the only window exits: the server goes away
        #expect(!tmux.windowAlive(a.windowID, name: "q-20261022T1900-000a"))
        let b = try tmux.openWindow(session: "shelf-B", windowName: "q-20261022T1900-000b", cwd: "/tmp", environment: [:],
                                    command: ["/bin/sleep", "5"])
        #expect(b.windowID == a.windowID, "fresh server reuses the id")
        #expect(!tmux.windowAlive(b.windowID, name: "q-20261022T1900-000a"), "but not the job")
        #expect(tmux.windowAlive(b.windowID, name: "q-20261022T1900-000b"))
    }
}
