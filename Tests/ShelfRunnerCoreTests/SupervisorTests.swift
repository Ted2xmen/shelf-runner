import Foundation
import Testing
@testable import ShelfRunnerCore

@Suite struct SupervisorTests {
    let now = ISO.parse("2026-10-22T16:00:00+03:00")!
    let A = "/w/A", B = "/w/B"

    func q(_ lines: String) -> QueueFile { QueueGrammar.parse(lines) }
    func line(_ n: Int, checked: Bool = false, mode: String = "attended") -> String {
        "- [\(checked ? "x" : " ")] job \(n) id:q-20261022T1500-000\(n) agent:claude mode:\(mode)\n"
    }
    func rec(_ n: Int, _ status: String, folder: String? = nil, startedMinAgo: Double = 1) -> RunRecord {
        RunRecord(id: "q-20261022T1500-000\(n)", folder: folder ?? A, status: status, agent: "claude", mode: "attended",
                  startedAt: Clock.iso(now.addingTimeInterval(-startedMinAgo * 60)), tmuxWindow: "@\(n)")
    }
    func snap(queues: [String: QueueFile?], records: [RunRecord] = [], markers: [String: StopMarker] = [:],
              obs: [String: JobObservation] = [:], folders: [String]? = nil) -> Snapshot {
        Snapshot(enabledFolders: folders ?? queues.keys.sorted(), queues: queues,
                 records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), markers: markers, observations: obs, now: now)
    }
    func id(_ n: Int) -> String { "q-20261022T1500-000\(n)" }
    var sup: Supervisor { Supervisor(policy: Policy()) }

    @Test func newLineStarts() {
        let a = sup.plan(snap(queues: [A: q(line(1))]))
        #expect(a.count == 1)
        guard case .start(let item, let folder, _) = a.first else { Issue.record("no start"); return }
        #expect(item.id == id(1) && folder == A)
    }

    @Test func concurrencyLimits() {
        let a = sup.plan(snap(queues: [A: q(line(1) + line(2)), B: q(line(3) + line(4))]))
        let starts = a.compactMap { if case .start(let i, _, _) = $0 { return i.id } else { return nil } }
        #expect(starts == [id(1), id(3)], "one per folder, two on the machine")
        #expect(a.contains(.setStatus(id: id(2), status: "waiting:folder")))
        #expect(a.contains(.setStatus(id: id(4), status: "waiting:slot")), "machine full wins over folder busy")

        var p = Policy(); p.maxParallel = 1
        let b = Supervisor(policy: p).plan(snap(queues: [A: q(line(1)), B: q(line(3))], records: [rec(1, "running")],
                                                obs: [id(1): .init(windowAlive: true, logModified: now)]))
        #expect(b == [.setStatus(id: id(3), status: "waiting:slot")])
    }

    @Test func holdIsWrittenOnce() {
        var s = snap(queues: [A: q(line(1))])
        s.paused = true
        #expect(sup.plan(s) == [.setStatus(id: id(1), status: "waiting:paused")])
        var r = rec(1, "waiting:paused"); r.startedAt = nil
        s.records = [id(1): r]
        #expect(sup.plan(s).isEmpty)
    }

    @Test func unattendedStartsAndIsNeverStalled() {
        guard case .start(let item, _, _) = sup.plan(snap(queues: [A: q(line(1, mode: "unattended"))])).first else {
            Issue.record("unattended line did not start"); return
        }
        #expect(item.mode == .unattended)
        var r = rec(1, "running", startedMinAgo: 30); r.mode = "unattended"
        let quiet = [id(1): JobObservation(windowAlive: true, logModified: now.addingTimeInterval(-20 * 60))]
        #expect(sup.plan(snap(queues: [A: q(line(1, mode: "unattended"))], records: [r], obs: quiet)).isEmpty,
                "print mode is silent until it ends")
    }

    @Test func finishedJobsAreNotRestarted() {
        for status in ["done", "failed:1", "cancelled", "failed:timeout"] {
            #expect(sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, status)])).isEmpty, "\(status)")
        }
    }

    @Test func removedOrTickedLineCancels() {
        let alive = [id(1): JobObservation(windowAlive: true, logModified: now)]
        #expect(sup.plan(snap(queues: [A: q("")], records: [rec(1, "running")], obs: alive))
                == [.interrupt(id: id(1), window: "@1", reason: "cancelled")])
        #expect(sup.plan(snap(queues: [A: q(line(1, checked: true))], records: [rec(1, "stalled")], obs: alive))
                == [.interrupt(id: id(1), window: "@1", reason: "cancelled")])
        #expect(sup.plan(snap(queues: [A: q("")], records: [rec(1, "needs-approval")]))
                == [.setStatus(id: id(1), status: "cancelled")])
    }

    @Test func unreadableQueueOrDisabledFolderCancelsNothing() {
        let alive = [id(1): JobObservation(windowAlive: true, logModified: now)]
        let unreadable: [String: QueueFile?] = [A: nil]
        #expect(sup.plan(snap(queues: unreadable, records: [rec(1, "running")], obs: alive)).isEmpty)
        #expect(sup.plan(snap(queues: [B: q("")], records: [rec(1, "running")], obs: alive)).isEmpty, "A is not enabled")
    }

    @Test func graceThenKill() {
        let alive = [id(1): JobObservation(windowAlive: true, logModified: now)]
        let fresh = StopMarker(reason: "cancelled", requestedAt: now.addingTimeInterval(-30))
        let old = StopMarker(reason: "cancelled", requestedAt: now.addingTimeInterval(-61))
        #expect(sup.plan(snap(queues: [A: q("")], records: [rec(1, "running")], markers: [id(1): fresh], obs: alive)).isEmpty)
        #expect(sup.plan(snap(queues: [A: q("")], records: [rec(1, "running")], markers: [id(1): old], obs: alive))
                == [.kill(id: id(1), window: "@1", reason: "cancelled")])
    }

    @Test func timeout() {
        let a = sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, "running", startedMinAgo: 121)],
                              obs: [id(1): .init(windowAlive: true, logModified: now)]))
        #expect(a == [.interrupt(id: id(1), window: "@1", reason: "failed:timeout")],
                "no notice here: it comes once `failed:timeout` is recorded")
    }

    @Test func stalledAndBack() {
        let quiet = [id(1): JobObservation(windowAlive: true, logModified: now.addingTimeInterval(-7 * 60))]
        let loud = [id(1): JobObservation(windowAlive: true, logModified: now.addingTimeInterval(-5))]
        #expect(sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, "running", startedMinAgo: 10)], obs: quiet))
                == [.setStatus(id: id(1), status: "stalled")])
        #expect(sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, "stalled", startedMinAgo: 10)], obs: loud))
                == [.setStatus(id: id(1), status: "running")])
        #expect(sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, "running", startedMinAgo: 3)], obs: [:])).isEmpty,
                "no log yet: quiet is measured from the start")
    }

    @Test func deadWindow() {
        let dead = [id(1): JobObservation(windowAlive: false, logModified: nil)]
        #expect(sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, "running")], obs: dead))
                == [.setStatus(id: id(1), status: "failed:lost")])
        let m = StopMarker(reason: "failed:timeout", requestedAt: now)
        #expect(sup.plan(snap(queues: [A: q(line(1))], records: [rec(1, "running")], markers: [id(1): m], obs: dead))
                == [.setStatus(id: id(1), status: "failed:timeout")])
    }

    @Test func dailyLimit() {
        var p = Policy(); p.dailyJobs = 1; p.maxParallel = 5
        let a = Supervisor(policy: p).plan(snap(queues: [A: q(line(2)), B: q(line(3))], records: [rec(1, "done", folder: B)]))
        #expect(a == [.setStatus(id: id(2), status: "waiting:daily"), .setStatus(id: id(3), status: "waiting:daily")])
    }

    @Test func gateHolds() {
        let s = Supervisor(policy: Policy(), gate: { item, _, _ in item.id.hasSuffix("1") ? .hold("needs-approval") : .pass })
        let a = s.plan(snap(queues: [A: q(line(1)), B: q(line(2))]))
        #expect(a.first == .setStatus(id: id(1), status: "needs-approval"))
        #expect(a.count == 2)
    }

    // MARK: resources

    func mac(memory: String = "normal", disk: Double = 100, battery: String = "charging", thermal: String = "nominal") -> StatusV1.Mac {
        .init(memory: memory, diskFreeGB: disk, battery: battery, thermal: thermal)
    }
    func limit(_ agent: String, _ fiveHour: Double) -> StatusV1.Limit {
        .init(agent: agent, source: "statusline", at: Clock.iso(now), fiveHour: fiveHour, week: 10, resetsFiveHour: nil, resetsWeek: nil)
    }
    func planned(_ res: Resources, queues: [String: QueueFile?]? = nil, records: [RunRecord] = [], obs: [String: JobObservation] = [:]) -> [Action] {
        var s = snap(queues: queues ?? [A: q(line(1))], records: records, obs: obs)
        s.resources = res
        return sup.plan(s)
    }
    var busy: (records: [RunRecord], obs: [String: JobObservation]) {
        ([rec(9, "running", folder: B)], [id(9): .init(windowAlive: true, logModified: now)])
    }

    @Test func calmMachineAndUnknownReadingsStart() {
        #expect(planned(Resources(mac: mac())).count == 1)
        #expect(planned(Resources(mac: .init(memory: nil, diskFreeGB: nil, battery: nil, thermal: nil))).count == 1)
        #expect(planned(Resources()).count == 1)
    }

    @Test func memoryWarnLetsOneJobRunCriticalNone() {
        guard case .start = planned(Resources(mac: mac(memory: "warn"))).first else { Issue.record("idle machine starts on warn"); return }
        let queues: [String: QueueFile?] = [A: q(line(1)), B: q(line(9))]
        #expect(planned(Resources(mac: mac(memory: "warn")), queues: queues, records: busy.records, obs: busy.obs)
                == [.setStatus(id: id(1), status: "waiting:memory")])
        #expect(planned(Resources(mac: mac(memory: "critical"))) == [.setStatus(id: id(1), status: "waiting:memory")])
    }

    @Test func diskUsesTheLowerOfStartupAndFolderVolume() {
        #expect(planned(Resources(mac: mac(disk: 4.9))) == [.setStatus(id: id(1), status: "waiting:disk")])
        #expect(planned(Resources(mac: mac(), folderDiskGB: [A: 3])) == [.setStatus(id: id(1), status: "waiting:disk")])
        guard case .start = planned(Resources(mac: mac(disk: 8))).first else { Issue.record("under 10 GB, idle: starts"); return }
        let queues: [String: QueueFile?] = [A: q(line(1)), B: q(line(9))]
        #expect(planned(Resources(mac: mac(disk: 8)), queues: queues, records: busy.records, obs: busy.obs)
                == [.setStatus(id: id(1), status: "waiting:disk")])
    }

    @Test func batteryAndHeat() {
        #expect(planned(Resources(mac: mac(battery: "battery:19"))) == [.setStatus(id: id(1), status: "waiting:battery")])
        #expect(planned(Resources(mac: mac(battery: "lowpower"))) == [.setStatus(id: id(1), status: "waiting:battery")])
        #expect(planned(Resources(mac: mac(battery: "battery:20"))).count == 1)
        #expect(planned(Resources(mac: mac(thermal: "serious"))) == [.setStatus(id: id(1), status: "waiting:thermal")])
        #expect(planned(Resources(mac: mac(thermal: "fair"))).count == 1)
    }

    @Test func limitHoldsOnlyItsOwnAgent() {
        #expect(planned(Resources(mac: mac(), limits: [limit("claude", 90)])) == [.setStatus(id: id(1), status: "waiting:limit")])
        #expect(planned(Resources(mac: mac(), limits: [limit("codex", 99), limit("claude", 89)])).count == 1)
    }

    @Test func limitCeilingStartsWithANotification() {
        func waiting(_ minAgo: Double) -> RunRecord {
            var r = rec(1, "waiting:limit"); r.startedAt = nil
            r.waitingSince = Clock.iso(now.addingTimeInterval(-minAgo * 60)); return r
        }
        let res = Resources(mac: mac(), limits: [limit("claude", 97)])
        #expect(planned(res, records: [waiting(89)]).isEmpty, "still waiting, written once")
        let a = planned(res, records: [waiting(90)])
        #expect(a.count == 2)
        guard case .notify(let nid, _, _) = a.first, case .start(let item, _, _) = a.last else { Issue.record("\(a)"); return }
        #expect(nid == id(1) && item.id == id(1))
        // Other reasons have no ceiling.
        var heat = waiting(600); heat.status = "waiting:thermal"
        #expect(planned(Resources(mac: mac(thermal: "critical")), records: [heat]).isEmpty)
    }

    @Test func slotWinsOverResources() {
        var p = Policy(); p.maxParallel = 1
        var s = snap(queues: [A: q(line(1)), B: q(line(9))], records: busy.records, obs: busy.obs)
        s.resources = Resources(mac: mac(memory: "critical"))
        #expect(Supervisor(policy: p).plan(s) == [.setStatus(id: id(1), status: "waiting:slot")])
    }
}
