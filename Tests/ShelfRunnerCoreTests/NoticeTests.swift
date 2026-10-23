import Foundation
import Testing
@testable import ShelfRunnerCore

/// `asking` and `failed:*` notices, and where a click goes.
@Suite struct NoticeTests {
    let A = "/w/SHELF-TEST", B = "/w/Other"
    let hours2: TimeInterval = 2 * 3600

    func rec(_ n: Int, _ status: String, folder: String? = nil, title: String? = "job", occurrence: String? = nil) -> RunRecord {
        var r = RunRecord(id: "q-20261023T1500-000\(n)", folder: folder ?? A, status: status, agent: "claude", mode: "attended", title: title)
        r.occurrence = occurrence
        return r
    }
    func recs(_ rs: RunRecord...) -> [String: RunRecord] { Dictionary(uniqueKeysWithValues: rs.map { ($0.id, $0) }) }
    func id(_ n: Int) -> String { "q-20261023T1500-000\(n)" }

    func job(_ n: Int, asking: Bool, now: String? = nil, agent: String = "claude") -> StatusV1.Job {
        StatusV1.Job(id: id(n), folder: A, ref: nil, title: "job \(n)", agent: agent, mode: "attended", state: "running",
                     started: nil, ended: nil, tmux: nil, now: now, asking: asking, log: [], out: nil)
    }

    @Test func failureOnceAfterTheFirstPass() {
        var w = NoticeWatch()
        let folders: Set = [A]
        #expect(w.failures(recs(rec(1, "running"), rec(2, "failed:1")), folders: folders, maxRuntime: hours2).isEmpty,
                "the first pass only records: a restart does not re-announce old failures")
        let n = w.failures(recs(rec(1, "failed:1"), rec(2, "failed:1")), folders: folders, maxRuntime: hours2)
        #expect(n == [Notice(id: id(1), kind: .info, title: "job", body: "Stopped with exit code 1")])
        #expect(w.failures(recs(rec(1, "failed:1"), rec(2, "failed:1")), folders: folders, maxRuntime: hours2).isEmpty, "once")
    }

    @Test func failureKinds() {
        var w = NoticeWatch()
        _ = w.failures([:], folders: [A], maxRuntime: hours2)
        let all = recs(rec(1, "failed:timeout"), rec(2, "failed:lost"), rec(3, "failed:path"), rec(4, "failed:start"),
                       rec(5, "failed:130"), rec(6, "cancelled"), rec(7, "done"), rec(8, "missed"), rec(9, "failed:odd"))
        let bodies = Dictionary(uniqueKeysWithValues: w.failures(all, folders: [A], maxRuntime: hours2).map { ($0.id, $0.body) })
        #expect(bodies == [id(1): "Stopped at the 2 h limit", id(2): "Lost while the runner restarted",
                           id(3): "Not started: ref: or out: is outside the folder", id(4): "Could not start",
                           id(5): "Stopped with exit code 130", id(9): "Stopped: odd"],
                "not cancelled, done or missed")
    }

    @Test func failureOnlyInEnabledFoldersAndNotOnReEnable() {
        var w = NoticeWatch()
        _ = w.failures(recs(rec(1, "running", folder: B), rec(2, "running")), folders: [A], maxRuntime: hours2)
        let n = w.failures(recs(rec(1, "failed:1", folder: B), rec(2, "running")), folders: [A], maxRuntime: hours2)
        #expect(n.isEmpty, "B is not enabled")
        #expect(w.failures(recs(rec(1, "failed:1", folder: B), rec(2, "running")), folders: [A, B], maxRuntime: hours2).isEmpty,
                "enabling B again is not news")
    }

    @Test func scheduledFailsAgainOnTheNextOccurrence() {
        var w = NoticeWatch()
        let o1 = "2026-10-22T09:00:00+03:00", o2 = "2026-10-23T09:00:00+03:00"
        _ = w.failures(recs(rec(1, "failed:start", occurrence: o1)), folders: [A], maxRuntime: hours2)
        #expect(w.failures(recs(rec(1, "failed:start", occurrence: o2)), folders: [A], maxRuntime: hours2).count == 1,
                "same status, new occurrence")
    }

    @Test func failureTitleFallsBackToTheLineThenTheID() {
        var w = NoticeWatch()
        _ = w.failures([:], folders: [A], maxRuntime: hours2)
        let n = w.failures(recs(rec(1, "failed:1", title: nil), rec(2, "failed:1", title: nil)), folders: [A],
                           titles: [id(1): "title on the line"], maxRuntime: hours2)
        #expect(n.map(\.title) == ["title on the line", id(2)])
    }

    @Test func askingOnTheEdgeOnly() {
        var w = NoticeWatch()
        #expect(w.questions([job(1, asking: false)]).isEmpty)
        let first = w.questions([job(1, asking: true)])
        #expect(first == [Notice(id: id(1), kind: .ask, title: "job 1", body: "Claude is asking · SHELF-TEST")])
        #expect(w.questions([job(1, asking: true)]).isEmpty, "still asking: no repeat")
        #expect(w.questions([job(1, asking: false)]).isEmpty)
        #expect(w.questions([job(1, asking: true)]).count == 1, "false, then true again")
        #expect(w.questions([]).isEmpty)
        #expect(w.questions([job(1, asking: true)]).count == 1, "gone from the status and back: asked again")
    }

    @Test func askingAfterARestartIsAnnouncedOnce() {
        var w = NoticeWatch()
        #expect(w.questions([job(1, asking: true), job(2, asking: false)]).map(\.id) == [id(1)])
        #expect(w.questions([job(1, asking: true), job(2, asking: false)]).isEmpty)
    }

    @Test func askingBodyCarriesTheQuestion() {
        #expect(NoticeText.asking(agent: "codex", folder: "/a/Apps", now: "Which file should we delete?")
                == "Codex is asking · Apps\nWhich file should we delete?")
        #expect(NoticeText.asking(agent: "claude", folder: A, now: "1. Yes") == "Claude is asking · SHELF-TEST",
                "not a question: body only")
        #expect(NoticeText.asking(agent: "claude", folder: A, now: nil) == "Claude is asking · SHELF-TEST")
        let long = String(repeating: "a", count: 130) + "?"
        let body = NoticeText.asking(agent: "claude", folder: A, now: long)
        let q = body.split(separator: "\n").last!
        #expect(q.count == NoticeText.maxQuestion && q.hasSuffix("…"))
        #expect(!body.contains("\u{2014}"), "no em dash")
    }

    @Test func askingIsModeAware() {
        let screen = ["Which file should I delete?"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: screen, quietFor: 61))
        #expect(!JobSummary.asking(mode: "unattended", state: "running", lines: screen, quietFor: 61), "print mode cannot ask")
    }

    @Test func notificationIdentifiers() {
        #expect(NoticeKind.ask.identifier(job: id(1)) == "ask:\(id(1))")
        #expect(NoticeKind.info.identifier(job: id(1)) == "info:\(id(1))")
        #expect(NoticeKind.approve.identifier(job: id(1)) == "approve:\(id(1))")
        for k in NoticeKind.allCases { #expect(NoticeKind.job(fromIdentifier: k.identifier(job: id(1))) == id(1)) }
        #expect(NoticeKind.job(fromIdentifier: id(1)) == nil, "no prefix")
        #expect(NoticeKind.job(fromIdentifier: "info:../../x") == nil, "not a job id")
    }

    @Test func clickGoesToDeskThenShelfThenNowhere() {
        let desk = URL(string: "runnerdesk://job/\(id(1))")!
        #expect(NoticeClick.decide(job: id(1), deskInstalled: true, shelfInstalled: true) == .openDesk(desk))
        #expect(NoticeClick.decide(job: id(1), deskInstalled: true, shelfInstalled: false) == .openDesk(desk))
        #expect(NoticeClick.decide(job: id(1), deskInstalled: false, shelfInstalled: true) == .openShelf)
        #expect(NoticeClick.decide(job: id(1), deskInstalled: false, shelfInstalled: false) == .nothing)
        #expect(NoticeClick.decide(job: nil, deskInstalled: true, shelfInstalled: true) == .openDesk(URL(string: "runnerdesk://")!))
        #expect(NoticeClick.deskURL(job: "../x") == URL(string: "runnerdesk://")!, "only a valid id goes in the URL")
    }
}

final class RecordingNotifier: Notifier {
    var sent: [(id: String, body: String, kind: NoticeKind)] = []
    func notify(id: String, title: String, body: String, kind: NoticeKind) { sent.append((id, body, kind)) }
}

@MainActor
@Suite struct AgentNoticeTests {
    @Test func agentAnnouncesAFailureWrapRecorded() throws {
        let home = try TempDir("nhome"), work = try TempDir("nwork")
        let paths = Paths(home: home.url)
        var config = Config()
        config.tmuxSocket = "shelf-runner-notice-unused"
        let runner = Runner(paths: paths, config: config, wrapExecutable: "/usr/bin/false", environment: [:])
        let notifier = RecordingNotifier()
        let agent = Agent(paths: paths, runner: runner, notifier: notifier)
        agent.log = { _ in }
        agent.readings = IdleReadings()
        let f = try work.sub("N")
        _ = try runner.enable(f.path)
        let old = RunRecord(id: "q-20261023T1500-0001", folder: f.path, status: "failed:2", agent: "claude", mode: "attended", title: "old")
        try runner.store.append(old)
        agent.tick()
        #expect(notifier.sent.isEmpty, "a failure from before the agent started is not news")
        // What `wrap` writes from its own process, and a cancel.
        try runner.store.append(RunRecord(id: "q-20261023T1500-0002", folder: f.path, status: "failed:1", agent: "claude",
                                          mode: "attended", title: "new"))
        try runner.store.append(RunRecord(id: "q-20261023T1500-0003", folder: f.path, status: "cancelled", agent: "claude",
                                          mode: "attended", title: "cancelled"))
        agent.tick()
        #expect(notifier.sent.map(\.id) == ["q-20261023T1500-0002"])
        #expect(notifier.sent.first?.kind == .info && notifier.sent.first?.body == "Stopped with exit code 1")
        agent.tick()
        #expect(notifier.sent.count == 1, "once")

        let job = StatusV1.Job(id: "q-20261023T1500-0004", folder: f.path, ref: nil, title: "question", agent: "claude", mode: "attended",
                               state: "running", started: nil, ended: nil, tmux: nil, now: "Shall I go on?", asking: true, log: [], out: nil)
        agent.noticeQuestions([job])
        agent.noticeQuestions([job])
        #expect(notifier.sent.count == 2 && notifier.sent.last?.kind == .ask)
        #expect(notifier.sent.last?.body == "Claude is asking · N\nShall I go on?")
    }
}
