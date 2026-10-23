import Foundation
import Testing
@testable import ShelfRunnerCore

@Suite struct SecurityTests {
    @Test func pathGuard() throws {
        let t = try TempDir("paths")
        let f = try t.sub("Folder")
        try FileManager.default.createDirectory(at: f.appendingPathComponent("reports"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent("out"), withDestinationURL: t.url)
        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent("inner"), withDestinationURL: f.appendingPathComponent("reports"))
        for ok in ["reports/", "reports/a.md", "new/folder/file.md", "TODO.md", "inner/x.md"] {
            #expect(PathGuard.isInside(ok, folder: f.path), "\(ok)")
        }
        for bad in ["../x", "reports/../../x", "/etc/passwd", "~/x", "", "out/x.md", "out"] {
            #expect(!PathGuard.isInside(bad, folder: f.path), "\(bad)")
        }
        #expect(PathGuard.refPath("TODO.md@a41c09e2") == "TODO.md")
    }

    @Test func gateOrder() throws {
        let key = ProtocolFixture.key, folder = ProtocolFixture.folder
        let item = try #require(QueueGrammar.parse(try String(contentsOf: ProtocolFixture.dir.appendingPathComponent("queue-lines.md"), encoding: .utf8))
            .item(id: "q-20261022T1630-7f3a"))
        var approvals = Approvals()
        #expect(AgentGate(key: nil, approvals: approvals).check(item, folder: folder) == .hold("waiting:signature"))
        #expect(AgentGate(key: ProtocolFixture.otherKey, approvals: approvals).check(item, folder: folder) == .hold("waiting:signature"))
        // The fixture folder does not exist here, so ref TODO.md resolves to its nearest existing
        // ancestor ("/"), which is outside: the path check fires after the signature passes.
        #expect(AgentGate(key: key, approvals: approvals).check(item, folder: folder) == .hold("failed:path"))
        var noRef = item; noRef.ref = nil
        let resigned = { (i: QueueItem) -> QueueItem in var j = i; j.sig = ProtocolV1.lineSig(key: key, item: j, folder: folder); return j }
        #expect(AgentGate(key: key, approvals: approvals).check(resigned(noRef), folder: folder) == .hold("needs-approval"))
        approvals.entries[item.id] = .init(decision: .run, at: "", via: "cli")
        #expect(AgentGate(key: key, approvals: approvals).check(resigned(noRef), folder: folder) == .pass)
        approvals.entries[item.id] = .init(decision: .ignore, at: "", via: "cli")
        #expect(AgentGate(key: key, approvals: approvals).check(resigned(noRef), folder: folder) == .hold("cancelled"))
    }

    @Test func pairAndApprovalsFiles() throws {
        let home = try TempDir("keys")
        let paths = Paths(home: home.url)
        let k1 = try KeyStore.pair(paths)
        #expect(KeyStore.load(paths) == k1)
        let perms = try FileManager.default.attributesOfItem(atPath: KeyStore.file(paths).path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let k2 = try KeyStore.pair(paths)
        #expect(k2 != k1 && KeyStore.load(paths) == k2)

        try Approvals.record(paths, id: "q-20261022T1700-0001", decision: .run, via: "cli")
        try Approvals.record(paths, id: "q-20261022T1700-0002", decision: .ignore, via: "notification")
        let a = Approvals.load(paths)
        #expect(a.entries["q-20261022T1700-0001"]?.decision == .run)
        #expect(a.entries["q-20261022T1700-0002"]?.via == "notification")
    }

    @Test func signedLine() throws {
        let key = ProtocolFixture.key
        let line = try QueueID.signedLine(key: key, folder: "/f", title: "  Write   release notes ", agent: .codex, mode: .unattended,
                                          ref: "TODO.md@a41c09e2", out: "reports/")
        let item = try #require(QueueGrammar.parse(line + "\n").items.first)
        #expect(item.title == "Write release notes" && item.agent == .codex && item.mode == .unattended && item.by == "you")
        #expect(ProtocolV1.verify(key: key, item: item, folder: "/f"))
        #expect(!ProtocolV1.verify(key: key, item: item, folder: "/g"))
        #expect(throws: RunnerError.self) { try QueueID.signedLine(key: key, folder: "/f", title: "x id:q-1", agent: .claude, mode: .attended) }
        #expect(throws: RunnerError.self) { try QueueID.signedLine(key: key, folder: "/f", title: "x", agent: .claude, mode: .attended, ref: "TODO.md") }
        #expect(QueueGrammar.isValidID(QueueID.make()))
    }
}
