import CryptoKit
import Foundation
import Testing
@testable import ShelfRunnerCore

/// `blocked` from unattended Claude's JSON result, and the three `ref` path escapes.
@Suite struct BlockedAndRefTests {
    // MARK: PrintResult

    @Test func denialsAreCounted() {
        let raw = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.\nTwo writes were denied.","permission_denials":[{"tool_name":"Write"},{"tool_name":"Bash"}],"session_id":"x"}"#
        #expect(PrintResult.parse(Data(raw.utf8)) == .init(text: "Done.\nTwo writes were denied.", blocked: 2))
    }

    @Test func zeroDenialsIsZeroNotNull() {
        let raw = #"{"type":"result","result":"Okay","permission_denials":[]}"# + "\n"
        #expect(PrintResult.parse(Data(raw.utf8)) == .init(text: "Okay", blocked: 0))
    }

    @Test(arguments: ["", "not json at all\n", #"{"type":"result","result":"half"#, "\"just a string\"", "[1,2]", "\u{FF}\u{FE}"])
    func malformedIsRawAndUnknown(raw: String) {
        let p = PrintResult.parse(Data(raw.utf8))
        #expect(p.blocked == nil)
        #expect(p.text == raw, "whatever came out goes to the log")
    }

    @Test func missingFieldsFallBack() {
        // Valid JSON without `result` (an error subtype): raw text to the log, denials still counted.
        let noResult = #"{"type":"result","subtype":"error_max_turns","permission_denials":[{}]}"#
        #expect(PrintResult.parse(Data(noResult.utf8)) == .init(text: noResult, blocked: 1))
        // No `permission_denials`: unknown, not zero.
        #expect(PrintResult.parse(Data(#"{"result":"ok"}"#.utf8)) == .init(text: "ok", blocked: nil))
        #expect(PrintResult.parse(Data(#"{"result":"ok","permission_denials":"x"}"#.utf8)).blocked == nil)
    }

    @Test func verboseArrayUsesTheLastResult() {
        let raw = #"[{"type":"system"},{"type":"assistant"},{"type":"result","result":"last","permission_denials":[{},{},{}]}]"#
        #expect(PrintResult.parse(Data(raw.utf8)) == .init(text: "last", blocked: 3))
    }

    @Test func onlyUnattendedClaudeApplies() {
        #expect(PrintResult.applies(agent: .claude, mode: .unattended))
        #expect(!PrintResult.applies(agent: .claude, mode: .attended))
        #expect(!PrintResult.applies(agent: .codex, mode: .unattended))
        #expect(!PrintResult.applies(agent: .codex, mode: .attended))
        #expect(!PrintResult.applies(agent: "claude", mode: "bogus"))
        // The template asks for exactly what `wrap` parses.
        let t = CLIAgentCommand(agent: .claude, executable: "claude").template(mode: .unattended)
        #expect(t.firstIndex(of: "--output-format").map { t[$0 + 1] } == PrintResult.outputFormat)
        #expect(!CLIAgentCommand(agent: .codex, executable: "codex").template(mode: .unattended).contains(PrintResult.outputFormat))
    }

    // MARK: status encoding

    @Test func blockedKeyIsAlwaysPresent() throws {
        func encoded(_ blocked: Int?) throws -> [String: Any] {
            let job = StatusV1.Job(id: "q-20261022T1300-5555", folder: "/f", ref: nil, title: "t", agent: "claude", mode: "unattended",
                                   state: "done", started: nil, ended: nil, tmux: nil, log: [], out: nil, blocked: blocked)
            return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        }
        let unknown = try encoded(nil)
        #expect(unknown.keys.contains("blocked") && unknown["blocked"] is NSNull)
        #expect(try encoded(2)["blocked"] as? Int == 2)
        #expect(try encoded(0)["blocked"] as? Int == 0)
        // An older status without the key still decodes (as unknown).
        let old = #"{"id":"q-20261022T1300-5555","folder":"/f","ref":null,"title":"t","agent":"claude","mode":"attended","state":"done","started":null,"ended":null,"tmux":null,"now":null,"asking":false,"waitingSince":null,"waitMaxMin":null,"log":[],"out":null,"attached":null,"attachError":null}"#
        #expect(try JSONDecoder().decode(StatusV1.Job.self, from: Data(old.utf8)).blocked == nil)
    }

    @Test func oldRunRecordsDecodeWithoutBlocked() throws {
        let line = #"{"agent":"claude","at":"2026-10-22T13:00:00+03:00","folder":"/f","id":"q-20261022T1300-5555","mode":"unattended","status":"done"}"#
        #expect(try JSONDecoder().decode(RunRecord.self, from: Data(line.utf8)).blocked == nil)
    }

    // MARK: ref escapes

    @Test func refEscapesDecode() {
        #expect(PathGuard.decodeRefPath("My%20Notes/TODO.md") == "My Notes/TODO.md")
        #expect(PathGuard.decodeRefPath("a%40b/%25done.md") == "a@b/%done.md")
        #expect(PathGuard.decodeRefPath("%2520.md") == "%20.md", "one pass: %25 then a literal 20")
        #expect(PathGuard.decodeRefPath("TODO.md") == "TODO.md")
        #expect(PathGuard.decodeRefPath("Notes%20\u{E9}/\u{C5}.md") == "Notes \u{E9}/\u{C5}.md")
    }

    @Test(arguments: ["%2F", "a%2e%2e/x", "%2E%2E/x", "%41.md", "100%.md", "x%2", "x%", "%%20", "%0A.md", "a%20%2Fb"])
    func otherEscapesAreInvalid(path: String) {
        #expect(PathGuard.decodeRefPath(path) == nil, "\(path)")
    }

    @Test func refPathCheckDecodesThenGuards() throws {
        let t = try TempDir("refs")
        let f = try t.sub("Folder")
        try FileManager.default.createDirectory(at: f.appendingPathComponent("My Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.appendingPathComponent("a@b"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent("Out Link"), withDestinationURL: t.url)
        for ok in ["My%20Notes/TODO.md@9ee5ced9", "TODO.md@a41c09e2", "a%40b/x.md@00000000", "%25done.md@00000000"] {
            #expect(PathGuard.refIsInside(ok, folder: f.path), "\(ok)")
        }
        for bad in ["My%20Notes/../../x.md@00000000", "%2E%2E/x.md@00000000", "Out%20Link/x.md@00000000",
                    "My%2FNotes.md@00000000", "%2Fetc/passwd@00000000", "My Notes%/TODO.md@00000000"] {
            #expect(!PathGuard.refIsInside(bad, folder: f.path), "\(bad)")
        }
    }

    /// The fixture's escaped `ref` line: grammar keeps it as written, the gate decodes it for the path check
    /// only, and its `h8` is the real digest of the Shelf item id.
    @Test func fixtureEscapedRef() throws {
        let text = try String(contentsOf: ProtocolFixture.dir.appendingPathComponent("queue-lines.md"), encoding: .utf8)
        let item = try #require(QueueGrammar.parse(text).item(id: "q-20261022T1640-94b5"))
        let r = ProtocolFixture.escapedRef
        #expect(item.ref == r.ref && r.ref.hasPrefix("My%20Notes/TODO.md@"))
        #expect(text.contains("ref:\(r.ref) "))
        #expect(PathGuard.decodeRefPath(PathGuard.refPath(try #require(item.ref))) == "My Notes/TODO.md")
        let digest = SHA256.hash(data: Data("/Users/test/SHELF-TEST/My Notes/TODO.md#edit the meeting notes#0".utf8))
        #expect(r.h8 == digest.prefix(4).map { String(format: "%02x", $0) }.joined())
        #expect(text.contains(#""h8": "\#(r.h8)""#))

        // Through the real gate in a real folder with that subfolder: signature, path, then approval.
        let t = try TempDir("fixref")
        let f = try t.sub("SHELF-TEST")
        try FileManager.default.createDirectory(at: f.appendingPathComponent("My Notes"), withIntermediateDirectories: true)
        var item2 = item
        item2.sig = ProtocolV1.lineSig(key: ProtocolFixture.key, canonical: ProtocolV1.queueCanonical(
            id: item.id, folder: f.path, title: item.title, agent: item.agent.rawValue, mode: item.mode.rawValue))
        #expect(AgentGate(key: ProtocolFixture.key, approvals: Approvals()).check(item2, folder: f.path) == .hold("needs-approval"))
        var badRef = item2
        badRef.ref = "My%2FNotes/TODO.md@\(r.h8)"
        #expect(AgentGate(key: ProtocolFixture.key, approvals: Approvals()).check(badRef, folder: f.path) == .hold("failed:path"))
    }

    /// The status echoes `ref` as the line wrote it, escapes included.
    @Test func statusEchoesEscapedRef() throws {
        let r = ProtocolFixture.escapedRef
        let job = StatusV1.Job(id: "q-20261022T1640-94b5", folder: "/f", ref: r.ref, title: "t", agent: "claude", mode: "attended",
                               state: "queued", started: nil, ended: nil, tmux: nil, log: [], out: nil)
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        #expect(o["ref"] as? String == r.ref)
    }

    /// `daily` is in the closed list of `waiting:` reasons; `SupervisorTests.dailyLimit` pins the exact `waiting:daily`.
    @Test func dailyIsInTheClosedList() {
        #expect(StatusV1.waitingReasons.contains("daily"))
    }
}
