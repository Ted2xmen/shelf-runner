import Foundation
import Testing
@testable import ShelfBridgeCore

/// `SCHEDULED.md` grammar, the series, and how the supervisor runs occurrences.
@Suite struct ScheduleGrammarTests {
    @Test func fixtureLinesParseAndVerify() throws {
        for c in ProtocolFixture.scheduledCases {
            guard case .success(let item)? = ScheduledGrammar.parseLine(c.text) else { Issue.record("\(c.id) did not parse"); continue }
            #expect(item.id == c.id && item.mode == .unattended && item.schedule != nil)
            #expect(ProtocolV2.verify(key: ProtocolFixture.key, item: item, folder: ProtocolFixture.folder), "\(c.id)")
            #expect(!ProtocolV2.verify(key: ProtocolFixture.otherKey, item: item, folder: ProtocolFixture.folder))
        }
    }

    @Test func signatureCoversTheSchedule() throws {
        let c = ProtocolFixture.scheduledCases[0]
        let moved = c.text.replacingOccurrences(of: "at:09:00", with: "at:10:00")
        guard case .success(let item)? = ScheduledGrammar.parseLine(moved) else { Issue.record("no parse"); return }
        #expect(!ProtocolV2.verify(key: ProtocolFixture.key, item: item, folder: ProtocolFixture.folder))
    }

    @Test func errorsAndNotes() {
        let base = "id:s-20261022T1640-b20d agent:codex"
        func err(_ line: String) -> QueueLineError? {
            if case .failure(let e)? = ScheduledGrammar.parseLine(line) { return e }
            return nil
        }
        #expect(err("- Job due:2026-10-26 \(base)") == .missingKey("mode"))
        #expect(err("- Job due:2026-10-26 \(base) mode:attended") == .badValue(key: "mode", value: "attended"))
        #expect(err("- Job \(base) mode:unattended") == .missingKey("due"))
        #expect(err("- Job due:2026-02-30 \(base) mode:unattended") == .badValue(key: "due", value: "2026-02-30"))
        #expect(err("- Job due:2026-10-26 at:25:00 \(base) mode:unattended") == .badValue(key: "at", value: "25:00"))
        #expect(err("- Job due:2026-10-26 at:9:00 \(base) mode:unattended") == .badValue(key: "at", value: "9:00"))
        #expect(err("- Job due:2026-10-26 every:fortnight \(base) mode:unattended") == .badValue(key: "every", value: "fortnight"))
        #expect(err("- Job due:2026-10-26 id:q-20261022T1640-b20d agent:codex mode:unattended") == .badValue(key: "id", value: "q-20261022T1640-b20d"))
        #expect(ScheduledGrammar.parseLine("- A note, no keys: just text") == nil)
        #expect(ScheduledGrammar.parseLine("- [ ] Boxed due:2026-10-26 \(base) mode:unattended") == nil, "boxed lines belong to the queue")
        #expect(ScheduledGrammar.parseLine("# Heading") == nil)
        let file = ScheduledGrammar.parse("- A due:2026-10-26 \(base) mode:unattended\n- B due:2026-10-27 \(base) mode:unattended\n- C half")
        #expect(file.items.count == 1 && file.invalid.first?.error == .duplicateID("s-20261022T1640-b20d", firstLine: 1))
    }
}

@Suite struct ScheduleSeriesTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }
    func t(_ s: String) -> Date { ISO.parse(s)! }

    @Test func monthEndClampIsNeverUndone() {
        let s = Schedule(due: "2026-01-31", at: "09:00", every: .month)
        let (last, next) = s.around(t("2026-04-01T00:00:00+03:00"), calendar: cal)
        #expect(last == t("2026-03-28T09:00:00+03:00"), "Jan 31, Feb 28, Mar 28 (not 31)")
        #expect(next == t("2026-04-28T09:00:00+03:00"))
    }

    @Test func weeklyJumpsAndKeepsItsWeekday() {
        let s = Schedule(due: "2026-10-26", at: "09:00", every: .week)
        #expect(s.around(t("2026-10-26T08:59:00+03:00"), calendar: cal) == (nil, t("2026-10-26T09:00:00+03:00")))
        #expect(s.around(t("2026-10-26T09:00:00+03:00"), calendar: cal).last == t("2026-10-26T09:00:00+03:00"), "at the minute: due")
        let far = s.around(t("2031-06-04T12:00:00+03:00"), calendar: cal)
        #expect(far.last == t("2031-06-02T09:00:00+03:00") && far.next == t("2031-06-09T09:00:00+03:00"))
    }

    @Test func oneOffAndDefaultTime() {
        let s = Schedule(due: "2026-10-30", at: nil, every: nil)
        #expect(s.around(t("2026-10-29T12:00:00+03:00"), calendar: cal) == (nil, t("2026-10-30T00:00:00+03:00")))
        #expect(s.around(t("2026-11-02T12:00:00+03:00"), calendar: cal) == (t("2026-10-30T00:00:00+03:00"), nil))
    }
}

@Suite struct ScheduleSupervisorTests {
    let now = ISO.parse("2026-10-26T09:10:00+03:00")!
    let A = "/w/A"
    let id = "s-20261022T1640-b20d"
    let at0900 = "2026-10-26T09:00:00+03:00"

    func line(due: String = "2026-10-26", at: String = "09:00", every: String = "week") -> QueueFile {
        ScheduledGrammar.parse("- Report due:\(due) at:\(at) every:\(every) id:\(id) agent:codex mode:unattended\n")
    }
    func rec(_ status: String, occurrence: String? = nil, atMinAgo: Double = 600) -> RunRecord {
        var r = RunRecord(id: id, folder: A, status: status, agent: "codex", mode: "unattended",
                          at: Clock.iso(now.addingTimeInterval(-atMinAgo * 60)))
        r.occurrence = occurrence
        return r
    }
    func plan(_ file: QueueFile, _ records: [RunRecord] = [], gate: Supervisor.GateResult = .pass, now: Date? = nil) -> [Action] {
        var s = Snapshot(enabledFolders: [A], queues: [:], records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
                         now: now ?? self.now)
        s.schedules = [A: file]
        return Supervisor(policy: Policy(), gate: { _, _, _ in gate }).plan(s)
    }
    var occ: String { Clock.iso(ISO.parse(at0900)!) }

    @Test func approvalIsAskedWhenTheLineAppears() {
        #expect(plan(line(due: "2026-11-02"), gate: .hold("needs-approval")) == [.setStatus(id: id, status: "needs-approval")])
        #expect(plan(line(due: "2026-11-02"), [rec("needs-approval")], gate: .hold("needs-approval")).isEmpty)
    }

    @Test func approvedAndNotDueIsScheduled() {
        #expect(plan(line(due: "2026-11-02"), [rec("needs-approval")]) == [.setStatus(id: id, status: JobState.scheduled)])
        #expect(plan(line(due: "2026-11-02"), [rec(JobState.scheduled)]).isEmpty)
    }

    @Test func dueOccurrenceStartsOnceWithItsInstant() {
        let a = plan(line(), [rec(JobState.scheduled)])
        guard case .start(let item, _, let o)? = a.first, a.count == 1 else { Issue.record("\(a)"); return }
        #expect(item.id == id && o == occ)
        #expect(plan(line(), [rec("done", occurrence: occ)]).isEmpty, "this occurrence already ran")
        #expect(plan(line(), [rec("running", occurrence: occ)]).isEmpty)
    }

    @Test func waitingKeepsTheOccurrence() {
        var s = Snapshot(enabledFolders: [A], queues: [:], records: [id: rec(JobState.scheduled)], now: now)
        s.schedules = [A: line()]
        s.paused = true
        #expect(Supervisor(policy: Policy()).plan(s) == [.setStatus(id: id, status: "waiting:paused", occurrence: occ)])
        s.paused = false
        s.records = [id: rec("waiting:paused", occurrence: occ)]
        guard case .start(_, _, let o)? = Supervisor(policy: Policy()).plan(s).first else { Issue.record("no start"); return }
        #expect(o == occ)
    }

    @Test func lateOccurrenceIsMissedWithANotification() {
        let late = ISO.parse("2026-10-26T10:30:00+03:00")!
        let a = plan(line(), [rec("done", occurrence: "2026-10-19T09:00:00+03:00")], now: late)
        #expect(a.first == .setStatus(id: id, status: "missed", occurrence: occ))
        guard case .notify? = a.last, a.count == 2 else { Issue.record("\(a)"); return }
        #expect(plan(line(), [rec("missed", occurrence: occ)], now: late).isEmpty)
        // Known since before 09:00 and approved: missed too.
        #expect(plan(line(), [rec(JobState.scheduled, atMinAgo: 24 * 60)], now: late).first == .setStatus(id: id, status: "missed", occurrence: occ))
    }

    @Test func aLineWrittenAfterItsDueTimeWaitsForTheNext() {
        let late = ISO.parse("2026-10-26T12:00:00+03:00")!
        #expect(plan(line(), [], now: late) == [.setStatus(id: id, status: JobState.scheduled)])
        #expect(plan(line(), [rec(JobState.scheduled, atMinAgo: 1)], now: late).isEmpty, "no missed for a time before the line existed")
    }

    @Test func aFinishedOccurrenceNeverRunsAgainAfterAGateFlap() {
        for final in ["done", "failed:1", "missed", "cancelled"] {
            #expect(plan(line(), [rec(final, occurrence: occ)], gate: .hold("waiting:signature")).isEmpty, "\(final)")
            #expect(plan(line(), [rec(final, occurrence: occ)]).isEmpty, "\(final)")
        }
        // A wait that has not started yet does go through the gate and then runs.
        #expect(plan(line(), [rec("waiting:slot", occurrence: occ)], gate: .hold("waiting:signature"))
                == [.setStatus(id: id, status: "waiting:signature")])
    }

    @Test func sameOccurrenceAcrossATimeZoneChange() {
        // Ran at 09:00 in Istanbul; the Mac is now in London where 09:00 is a later instant.
        let london = TimeZone(identifier: "Europe/London")!
        #expect(Schedule.isSame("2026-10-26T09:00:00+03:00", ISO.parse("2026-10-26T09:00:00+00:00"), in: london))
        #expect(!Schedule.isSame("2026-10-26T09:00:00+03:00", ISO.parse("2026-10-26T12:00:00+00:00"), in: london))
        #expect(!Schedule.isSame("2026-10-19T09:00:00+03:00", ISO.parse("2026-10-26T09:00:00+03:00")))
        #expect(!Schedule.isSame(nil, ISO.parse("2026-10-26T09:00:00+03:00")))
    }

    @Test func removedLineCancelsAPendingOccurrence() {
        var s = Snapshot(enabledFolders: [A], queues: [:], records: [id: rec("waiting:slot", occurrence: occ)], now: now)
        s.schedules = [A: ScheduledGrammar.parse("")]
        #expect(Supervisor(policy: Policy()).plan(s) == [.setStatus(id: id, status: "cancelled")])
    }
}

@Suite struct ScheduleConfigTests {
    @Test func missedAfterAndModels() throws {
        let c = try Config.parse("[bridge]\nmissed_after_minutes = 15\n[unattended]\nclaude_model = \"opus\"\ncodex_model = \"gpt-5.5\"\n")
        #expect(c.policy.missedAfter == 900)
        #expect(c.unattendedModels == [.claude: "opus", .codex: "gpt-5.5"])
        #expect(c.unknownKeys.isEmpty)
        #expect(throws: TOMLError.self) { try Config.parse("[unattended]\ncodex_model = \"--yolo\"") }
        #expect(throws: TOMLError.self) { try Config.parse("[unattended]\nclaude_model = \"opus --tools Bash\"") }
    }

    @Test func modelGoesOnlyIntoUnattendedTemplates() throws {
        let claude = CLIAgentCommand(agent: .claude, executable: "claude", model: "opus")
        #expect(Array(claude.template(mode: .unattended).prefix(4)) == ["claude", "-p", "--model", "opus"])
        #expect(claude.template(mode: .attended) == ["claude"])
        let codex = CLIAgentCommand(agent: .codex, executable: "codex", model: "gpt-5.5")
        #expect(Array(codex.template(mode: .unattended).prefix(4)) == ["codex", "exec", "-m", "gpt-5.5"])
        try PermissionGuard.check(codex.template(mode: .unattended))
    }
}

@MainActor
@Suite struct ScheduleRecordTests {
    @Test func aNewOccurrenceDropsTheLastRunsFields() throws {
        let home = try TempDir("occ"), work = try TempDir("occw")
        let paths = Paths(home: home.url)
        let runner = Runner(paths: paths, config: Config(), wrapExecutable: "/usr/bin/false", environment: [:])
        let agent = Agent(paths: paths, runner: runner, notifier: StderrNotifier())
        agent.log = { _ in }
        agent.readings = IdleReadings()
        let f = try work.sub("O")
        _ = try runner.enable(f.path)
        let id = "s-20261022T1640-0cc1"
        var old = RunRecord(id: id, folder: f.path, status: "done", agent: "codex", mode: "unattended",
                            startedAt: "2026-10-19T09:00:01+03:00", endedAt: "2026-10-19T09:05:00+03:00",
                            tmuxSession: "shelf-O", tmuxWindow: "@3", logPath: "/x.log", exitCode: 0)
        old.occurrence = "2026-10-19T09:00:00+03:00"
        try runner.store.append(old)
        agent.append(id: id, status: "missed", agent.observe(), now: Date(), occurrence: "2026-10-26T09:00:00+03:00")
        let r = try #require(runner.store.latest(id: id))
        #expect(r.status == "missed" && r.occurrence == "2026-10-26T09:00:00+03:00")
        #expect(r.startedAt == nil && r.endedAt == nil && r.exitCode == nil && r.tmuxWindow == nil && r.logPath == nil)
    }
}

