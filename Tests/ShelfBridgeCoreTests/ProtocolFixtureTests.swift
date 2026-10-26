import CryptoKit
import Foundation
import Testing
@testable import ShelfBridgeCore

/// `fixtures/protocol/v2/` is generated from this file and copied by Shelf.
/// `REGEN_PROTOCOL_FIXTURES=1 swift test --filter ProtocolFixture` rewrites it; otherwise the
/// files must match byte for byte.
enum ProtocolFixture {
    static let dir = Fixture.packageRoot.appendingPathComponent("fixtures/protocol/v2")
    /// Test key: bytes 0x00...0x1f. Never a real pairing key.
    static let key = Data((0..<32).map { UInt8($0) })
    static let otherKey = Data((0..<32).map { UInt8(255 - $0) })
    static let folder = "/Users/test/SHELF-TEST"

    struct LineCase {
        var text: String          // the line as written, `sig:` filled in
        var id: String
        var canonical: String
        var sig: String?          // nil = no sig on the line
        var valid: Bool
        var note: String
    }

    /// `title` is the canonical title; `body` places keys around it as a writer might.
    static func queueCase(_ id: String, body: (String) -> String, title: String, agent: String, mode: String,
                          checked: Bool = false, note: String, signWith: Data? = key, signFolder: String = folder,
                          signTitle: String? = nil) -> LineCase {
        let canonical = ProtocolV2.queueCanonical(id: id, folder: folder, title: title, agent: agent, mode: mode)
        let sig = signWith.map {
            ProtocolV2.lineSig(key: $0, canonical: ProtocolV2.queueCanonical(id: id, folder: signFolder, title: signTitle ?? title,
                                                                           agent: agent, mode: mode))
        }
        let text = "- [\(checked ? "x" : " ")] " + body(sig.map { " sig:\($0)" } ?? "")
        let valid = signWith == key && signFolder == folder && signTitle == nil
        return LineCase(text: text, id: id, canonical: canonical, sig: sig, valid: valid, note: note)
    }

    static let nfdTitle = "Review the caf\u{E9} menu".decomposedStringWithCanonicalMapping

    /// A `ref` with an escaped path. `h8` is real: SHA-256 over the Shelf
    /// `ItemID.description` of the TODO item, `<realpath>#<folded key>#<occurrence>`.
    struct RefCase { var ref: String; var path: String; var itemID: String; var h8: String }
    static var escapedRef: RefCase {
        let path = "My Notes/TODO.md"
        let itemID = "\(folder)/\(path)#edit the meeting notes#0"
        let h8 = ProtocolV2.hex(Data(SHA256.hash(data: Data(itemID.utf8)))).prefix(8).description
        return RefCase(ref: "My%20Notes/TODO.md@\(h8)", path: path, itemID: itemID, h8: h8)
    }

    static var queueCases: [LineCase] {
        [
            queueCase("q-20261022T1630-7f3a", body: { "Write release notes for Pantheon 1.4 id:q-20261022T1630-7f3a agent:claude mode:attended ref:TODO.md@a41c09e2 by:you\($0)" },
                      title: "Write release notes for Pantheon 1.4", agent: "claude", mode: "attended", note: "the form Shelf writes"),
            queueCase("q-20261022T1631-0b2c", body: { "Build the weekly metrics report id:q-20261022T1631-0b2c agent:codex mode:unattended out:reports/ by:you\($0)" },
                      title: "Build the weekly metrics report", agent: "codex", mode: "unattended", note: "codex, unattended, out:"),
            queueCase("q-20261022T1632-1c3d", body: { "Prepare id:q-20261022T1632-1c3d   agent:claude  the report \tand send it by:you\($0)" },
                      title: "Prepare the report and send it", agent: "claude", mode: "attended",
                      note: "a key in the middle; runs of spaces and tabs become one space; no mode:, attended in the canonical text"),
            queueCase("q-20261022T1633-2d4e", body: { "Check the release note:important id:q-20261022T1633-2d4e agent:claude mode:attended by:you\($0)" },
                      title: "Check the release note:important", agent: "claude", mode: "attended",
                      note: "note: is not in the closed key list, so it stays in the title"),
            queueCase("q-20261022T1634-3e5f", body: { "\(nfdTitle) id:q-20261022T1634-3e5f agent:claude mode:attended by:you\($0)" },
                      title: "Review the caf\u{E9} menu", agent: "claude", mode: "attended",
                      note: "the title is NFD in the file (e + U+0301); the canonical text is NFC"),
            queueCase("q-20261022T1635-4f60", body: { "Finished job id:q-20261022T1635-4f60 agent:codex mode:attended by:you\($0)" },
                      title: "Finished job", agent: "codex", mode: "attended", checked: true,
                      note: "the tick is not signed; a checked line is valid but never runs"),
            queueCase("q-20261022T1636-5071", body: { "Write release notes for Pantheon 1.5 id:q-20261022T1636-5071 agent:claude mode:attended by:you\($0)" },
                      title: "Write release notes for Pantheon 1.5", agent: "claude", mode: "attended",
                      note: "INVALID: signed for another title (1.4)", signTitle: "Write release notes for Pantheon 1.4"),
            queueCase("q-20261022T1637-6182", body: { "Unsigned job id:q-20261022T1637-6182 agent:claude mode:attended by:you\($0)" },
                      title: "Unsigned job", agent: "claude", mode: "attended", note: "INVALID: no sig:", signWith: nil),
            queueCase("q-20261022T1638-7293", body: { "Job from another folder id:q-20261022T1638-7293 agent:claude mode:attended by:you\($0)" },
                      title: "Job from another folder", agent: "claude", mode: "attended",
                      note: "INVALID: signed for /Users/test/OTHER", signFolder: "/Users/test/OTHER"),
            queueCase("q-20261022T1639-83a4", body: { "Signed with another key id:q-20261022T1639-83a4 agent:claude mode:attended by:you\($0)" },
                      title: "Signed with another key", agent: "claude", mode: "attended",
                      note: "INVALID: signed with another key", signWith: otherKey),
            queueCase("q-20261022T1640-94b5", body: { "Edit the meeting notes id:q-20261022T1640-94b5 agent:claude mode:attended ref:\(escapedRef.ref) by:you\($0)" },
                      title: "Edit the meeting notes", agent: "claude", mode: "attended",
                      note: "the space in the ref path is %20; Bridge decodes it only for the path check (My Notes/TODO.md) and echoes it unchanged in the status"),
        ]
    }

    struct ScheduledCase { var text: String; var id: String; var canonical: String; var sig: String; var note: String }

    static var scheduledCases: [ScheduledCase] {
        func make(_ id: String, title: String, agent: String, due: String, at: String?, every: String?,
                  body: (String) -> String, note: String) -> ScheduledCase {
            let c = ProtocolV2.scheduledCanonical(id: id, folder: folder, title: title, agent: agent, mode: "unattended",
                                                  due: due, at: at, every: every)
            let sig = ProtocolV2.lineSig(key: key, canonical: c)
            return ScheduledCase(text: "- " + body(" sig:\(sig)"), id: id, canonical: c, sig: sig, note: note)
        }
        return [
            make("s-20261022T1640-b20d", title: "Build the weekly metrics report", agent: "codex", due: "2026-10-26", at: "09:00", every: "week",
                 body: { "Build the weekly metrics report due:2026-10-26 every:week at:09:00 id:s-20261022T1640-b20d agent:codex mode:unattended out:reports/ by:you\($0)" },
                 note: "full line"),
            make("s-20261022T1641-c31e", title: "Write the monthly summary", agent: "claude", due: "2026-11-01", at: nil, every: "month",
                 body: { "Write the monthly summary due:2026-11-01 every:month id:s-20261022T1641-c31e agent:claude mode:unattended by:you\($0)" },
                 note: "no at:, an empty line in the canonical text"),
            make("s-20261022T1642-d42f", title: "Check the backup", agent: "codex", due: "2026-10-30", at: "18:30", every: nil,
                 body: { "Check the backup due:2026-10-30 at:18:30 id:s-20261022T1642-d42f agent:codex mode:unattended by:you\($0)" },
                 note: "no every: (runs once), an empty last line in the canonical text"),
        ]
    }

    static let commandTS = 1_792_675_800  // 2026-10-22T16:30:00+03:00
    static var commandCases: [(ProtocolV2.Verb, String?)] {
        [(.run, "q-20261022T1630-7f3a"), (.ignore, "q-20261022T1630-7f3a"), (.stop, "q-20261022T1630-7f3a"),
         (.requeue, "q-20261022T1630-7f3a"), (.runnow, "s-20261022T1640-b20d"), (.pause, nil), (.resume, nil),
         (.log, "q-20261022T1630-7f3a"), (.attach, "q-20261022T1630-7f3a")]
    }

    // MARK: rendering

    static func frontmatter(_ title: String, _ description: String) -> String {
        """
        ---
        title: \(title)
        description: \(description)
        created_by: claude-code
        created: 2026-10-22T19:00:00+03:00
        updated_by: claude-code
        updated: 2026-10-22T22:40:00+03:00
        ---

        """
    }

    static func jsonString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let a = String(decoding: d, as: UTF8.self)
        return String(a.dropFirst().dropLast())
    }

    static func queueLinesMarkdown() -> String {
        var s = frontmatter("Protocol v2 · signed queue lines",
                            "Line signature fixture: a fixed test key, lines, and the expected canonical text and signatures. Generated by Tests/ShelfBridgeCoreTests/ProtocolFixtureTests.swift.")
        s += """
        # Protocol v2 · signed queue lines

        The test key is in `key.json` (0x00..0x1f, not a real key). The folder's real path: `\(folder)`.
        See `README.md` for the rules. The machine-readable expectations are in the `json` block at the end.

        ## Queue lines (AGENT-QUEUE.md format)


        """
        for c in queueCases { s += c.text + "\n" }
        s += "\n## Scheduled lines (SCHEDULED.md format)\n\n"
        for c in scheduledCases { s += c.text + "\n" }
        s += "\n## Expectations\n\n```json\n{\n  \"folder\": \(jsonString(folder)),\n  \"queue\": [\n"
        s += queueCases.map { c in
            "    {\"id\": \(jsonString(c.id)), \"canonical\": \(jsonString(c.canonical)), \"sig\": \(c.sig.map(jsonString) ?? "null"), \"valid\": \(c.valid), \"note\": \(jsonString(c.note))}"
        }.joined(separator: ",\n")
        s += "\n  ],\n  \"scheduled\": [\n"
        s += scheduledCases.map { c in
            "    {\"id\": \(jsonString(c.id)), \"canonical\": \(jsonString(c.canonical)), \"sig\": \(jsonString(c.sig)), \"valid\": true, \"note\": \(jsonString(c.note))}"
        }.joined(separator: ",\n")
        let r = escapedRef
        s += "\n  ],\n  \"refs\": [\n"
        s += "    {\"ref\": \(jsonString(r.ref)), \"path\": \(jsonString(r.path)), \"itemID\": \(jsonString(r.itemID)), \"h8\": \(jsonString(r.h8)), \"note\": \(jsonString("h8 = first 8 hex of SHA-256(UTF-8 itemID); path unescaped, ref escaped"))}"
        s += "\n  ]\n}\n```\n"
        return s
    }

    static func keyJSON() -> String {
        """
        {
          "keyHex": "\(ProtocolV2.hex(key))",
          "keyId": "\(ProtocolV2.keyId(key))",
          "pairCode": "\(PairCode.encode(key))",
          "note": "Test key. Real pairing (shelf-bridge pair) makes 32 random bytes."
        }

        """
    }

    static func commandsJSON() -> String {
        let rows = commandCases.map { verb, id -> String in
            let msg = "cmd|\(verb.rawValue)|\(id ?? "-")|\(commandTS)"
            return "    {\"verb\": \"\(verb.rawValue)\", \"id\": \(id.map { "\"\($0)\"" } ?? "null"), \"ts\": \(commandTS), \"message\": \(jsonString(msg)), \"sig\": \"\(ProtocolV2.commandSig(key: key, verb: verb, id: id, ts: commandTS))\", \"name\": \"\(ProtocolV2.commandName(key: key, verb: verb, id: id, ts: commandTS))\"}"
        }
        return "{\n  \"keyHex\": \"\(ProtocolV2.hex(key))\",\n  \"object\": \"\(ProtocolV2.shelfObject)\",\n  \"commands\": [\n" + rows.joined(separator: ",\n") + "\n  ]\n}\n"
    }

    // MARK: status samples

    static let mac = StatusV2.Mac(memory: "warn", diskFreeGB: 48.2, battery: "battery:64", thermal: "nominal")
    static let limits = [
        StatusV2.Limit(agent: "claude", source: "statusline", at: "2026-10-22T16:28:40+03:00", fiveHour: 34, week: 61,
                       resetsFiveHour: "2026-10-22T19:00:00+03:00", resetsWeek: "2026-10-27T10:00:00+03:00"),
        StatusV2.Limit(agent: "codex", source: "session", at: "2026-10-22T16:20:02+03:00", fiveHour: nil, week: 6,
                       resetsFiveHour: nil, resetsWeek: "2026-11-21T12:10:36+03:00"),
    ]
    static let folders = ["/Users/test/SHELF-TEST", "/Users/test/Pantheon"]

    static func job(_ id: String, _ title: String, state: String, agent: String = "claude", mode: String = "attended",
                    folder: String = folder, started: String? = nil, ended: String? = nil, log: [String] = [],
                    ref: String? = nil, out: String? = nil, asking: Bool = false, waitingSince: String? = nil,
                    attached: String? = nil, attachError: String? = nil, blocked: Int? = nil) -> StatusV2.Job {
        let session = Tmux.sessionName(folder: folder)
        let reason = state.hasPrefix("waiting:") ? String(state.dropFirst(8)) : nil
        return StatusV2.Job(id: id, folder: folder, ref: ref, title: title, agent: agent, mode: mode, state: state,
                            started: started, ended: ended, tmux: started == nil ? nil : "\(session):\(id)",
                            now: JobSummary.now(log), asking: asking,
                            waitingSince: reason == nil ? nil : waitingSince, waitMaxMin: reason.flatMap { StatusV2.waitMaxMin(reason: $0) },
                            log: log, out: out, attached: attached, attachError: attachError, blocked: blocked)
    }

    static var busyJobs: [StatusV2.Job] {
        [
            job("q-20261022T1630-7f3a", "Write release notes for Pantheon 1.4", state: "running", started: "2026-10-22T16:27:05+03:00",
                log: ["Reading CHANGELOG.md", "Drafting notes for 1.4", "Wrote docs/release-1.4.md"], ref: "TODO.md@a41c09e2",
                attached: "2026-10-22T16:30:58+03:00"),
            job("q-20261022T1610-0a0b", "Review the payment screen", state: "stalled", folder: "/Users/test/Pantheon",
                started: "2026-10-22T16:10:12+03:00", log: ["Editing Sources/Paywall.swift", "╭──────────────╮",
                                                            "│ Do you want to allow edits to Paywall.swift? (y/n)"],
                asking: true, attachError: "no-session"),
            job("q-20261022T1633-2d4e", "Check the release note:important", state: "needs-approval"),
            job("q-20261022T1631-0b2c", "Build the weekly metrics report", state: "waiting:memory", agent: "codex", mode: "unattended",
                out: "reports/", waitingSince: "2026-10-22T16:25:00+03:00"),
            job("q-20261022T1632-1c3d", "Prepare the report and send it", state: "waiting:slot", waitingSince: "2026-10-22T16:29:40+03:00"),
            job("q-20261022T1612-3c3c", "Concurrency example", state: "waiting:folder", folder: "/Users/test/Pantheon",
                waitingSince: "2026-10-22T16:20:00+03:00"),
            job("q-20261022T1625-4d4d", "Job waiting for a limit", state: "waiting:limit", agent: "codex",
                waitingSince: "2026-10-22T16:25:05+03:00"),
            job("q-20261022T1626-5e5e", "Job in a paused queue", state: "waiting:paused", folder: "/Users/test/Pantheon",
                waitingSince: "2026-10-22T16:26:00+03:00"),
            job("q-20261022T1405-1111", "Update the README", state: "done", started: "2026-10-22T14:05:00+03:00",
                ended: "2026-10-22T14:19:41+03:00", log: ["Updated README.md"]),
            job("q-20261022T1300-5555", "Summarize the contract draft", state: "done", mode: "unattended",
                started: "2026-10-22T13:00:04+03:00", ended: "2026-10-22T13:03:52+03:00",
                log: ["Wrote notes/contract-summary.md", "Could not write ../Archive/summary.md: permission denied"], blocked: 2),
            job("q-20261022T1200-2222", "Fix the tests", state: "failed:1", agent: "codex", started: "2026-10-22T12:00:03+03:00",
                ended: "2026-10-22T12:02:10+03:00", log: ["error: 3 tests failed"]),
            job("q-20261022T1100-3333", "Delete the old draft", state: "cancelled", started: "2026-10-22T11:00:00+03:00",
                ended: "2026-10-22T11:01:12+03:00"),
            job("q-20261021T0900-4444", "Long refactor", state: "failed:timeout", started: "2026-10-21T21:00:00+03:00",
                ended: "2026-10-21T23:00:00+03:00", log: ["still working on module 7 of 12"]),
        ]
    }

    static let scheduled = [StatusV2.Scheduled(id: "s-20261022T1640-b20d", title: "Build the weekly metrics report",
                                               agent: "codex", next: "2026-10-26T09:00:00+03:00")]

    static var statusFiles: [(String, StatusV2)] {
        let keyId = ProtocolV2.keyId(key)
        let busy = StatusV2(bridge: "0.3.0", seen: "2026-10-22T16:31:05+03:00", keyId: keyId, paused: false,
                            slots: .init(max: 2, perFolder: 1, running: 2), mac: mac,
                            limits: limits, folders: folders, jobs: busyJobs, scheduled: scheduled)
        let idle = StatusV2(bridge: "0.3.0", seen: "2026-10-22T16:31:05+03:00", keyId: keyId, paused: false,
                            slots: .init(max: 2, perFolder: 1, running: 0), mac: .init(memory: "normal", diskFreeGB: 212.7, battery: "charging", thermal: "nominal"),
                            limits: [], folders: folders, jobs: [busyJobs[5]], scheduled: scheduled)
        var stale = busy
        stale.seen = "2026-10-22T09:12:44+03:00"
        let unpaired = StatusV2(bridge: "0.3.0", seen: "2026-10-22T16:31:05+03:00", keyId: nil, paused: false,
                                slots: .init(max: 2, perFolder: 1, running: 0), mac: .init(memory: "normal", diskFreeGB: nil, battery: nil, thermal: "fair"), limits: [],
                                folders: ["/Users/test/SHELF-TEST"],
                                jobs: [job("q-20261022T1630-7f3a", "Write release notes for Pantheon 1.4", state: "waiting:signature",
                                           ref: "TODO.md@a41c09e2", waitingSince: "2026-10-22T16:30:00+03:00")],
                                scheduled: [])
        return [("status-busy.json", busy), ("status-idle.json", idle), ("status-offline-stale.json", stale), ("status-unpaired.json", unpaired)]
    }

    // MARK: log answer

    /// A raw pane log as tmux `pipe-pane` writes it: colours, `ESC ( B`, column moves, a CR progress line.
    static let rawLog = [
        "\u{1B}[1mReading\u{1B}[22m CHANGELOG.md\r\n",
        "Drafting\u{1B}[10Gnotes\u{1B}[16Gfor\u{1B}[20G1.4\u{1B}(B\u{1B}[m\r\n",
        "10%\r55%\r100% docs/release-1.4.md\r\n",
        "\u{1B}]0;✳ Claude Code\u{07}⏺ Wrote docs/release-1.4.md\r\n",
        "\u{1B}[38;5;246mDo you want to commit these notes? (y/n)\u{1B}[39m\r\n",
    ].joined()

    /// A finished job answers from its log: plain, no `styles` (the old form, still valid).
    static var logReplyPlain: LogReply {
        LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "2026-10-22T16:31:07+03:00", text: rawLog, partial: false)
    }

    /// The same screen as tmux `capture-pane -p -e -J` prints it for a live window: bold,
    /// 16 and 256 colours, truecolor, underline, inverse; the dim truecolor of line 2 carries into
    /// line 3 (tmux does not reset at a line end).
    static let captureRaw = [
        "\u{1B}[1mReading\u{1B}[22m \u{1B}[38;5;153mCHANGELOG.md\u{1B}[39m\n",
        "\u{1B}[2mDrafting notes for \u{1B}[38;2;215;119;87m1.4\n",
        "100%\u{1B}[0m \u{1B}[32mdocs/release-1.4.md\u{1B}[39m\n",
        "\u{1B}[38;5;246m⏺\u{1B}[39m Wrote \u{1B}[4mdocs/release-1.4.md\u{1B}[24m\n",
        "\u{1B}[38;5;220mDo you want to commit these notes?\u{1B}[39m \u{1B}[7m(y/n)\u{1B}[0m\n",
    ].joined()

    static var logReply: LogReply {
        let p = AnsiText.parse(raw: captureRaw)
        return LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "2026-10-22T16:31:07+03:00",
                             lines: p.lines, styles: p.styles, partial: false)
    }

    /// The notification's `userInfo` as it goes on the wire: `json` is one string.
    static func logReplyJSON(_ logReply: LogReply) -> String {
        """
        {
          "name": "\(ProtocolV2.logName)",
          "userInfo": {
            "v": 2,
            "id": "\(logReply.id)",
            "json": \(jsonString(try! logReply.json()))
          },
          "decoded": \(try! logReply.json(pretty: true).replacingOccurrences(of: "\n", with: "\n  "))
        }

        """
    }

    static func readme() -> String {
        frontmatter("Protocol v2 fixtures", "Test files shared by shelf-bridge and Shelf, how they are made, and the rules of protocol v2 they pin down.") + """
        # Protocol v2 fixtures

        shelf-bridge generates these files; Shelf copies them byte for byte. Do not edit them by hand:
        `REGEN_PROTOCOL_FIXTURES=1 swift test --filter ProtocolFixture` rewrites them, and a normal test
        run checks that they match the code byte for byte.

        | File | Contents |
        |---|---|
        | `key.json` | Test key (0x00..0x1f), `keyId`, `SB1-` pairing code |
        | `queue-lines.md` | Queue and scheduled lines, canonical text, expected `sig`, valid or not; an escaped `ref` and its real `h8` (`refs`) |
        | `commands.json` | Command names and their 16-hex signatures, a fixed `ts`; the `object` they are posted with |
        | `status-busy.json` | Paired, `slots` full (2/2), every job state and most waiting reasons once, an `asking` job, an unattended Claude job that ended with `blocked: 2`, two limits, one scheduled line |
        | `status-idle.json` | Paired, nothing running, no limits (stale or unreadable), charging |
        | `status-offline-stale.json` | Same as `status-busy`, `seen` 7 hours old: Shelf draws "Runner offline" and "unknown" |
        | `status-unpaired.json` | `keyId: null`, an unsigned line in `waiting:signature`, unknown disk and battery as `null` |
        | `log-reply.json` | The `dev.ted2xmen.shelf-bridge.log` answer for a live window: `userInfo` (with `json` as one string) and its decoded form; `lines` and coloured `styles` from `capture-pane -e` text (rule 17) |
        | `log-reply-plain.json` | The same lines without `styles` (a finished job, an older Bridge): colour, `ESC ( B`, column moves and a `\\r` progress line cleaned from the raw log |

        ## Rules

        1. **Canonical title:** split the line on whitespace, drop the `key:value` words of the closed key list, join the rest with one space, then convert to NFC. An `x:y` word whose key is not in the closed list stays in the title.
        2. **Without `mode:`** the canonical text has `attended` (the default). The tick (`[x]`) is not signed.
        3. **The folder's real path:** `realpath(3)` (what Shelf uses for roots and ids; the `/private/var/...` form).
        4. **On a scheduled line** a missing `at:` or `every:` is an empty string in the canonical text; it always has 9 lines.
        5. **Pairing code:** `SB1-` + RFC 4648 base32 (A-Z, 2-7), upper case, no padding; 32 bytes = 52 characters. The reader ignores case, spaces and dashes.
        6. **`keyId`** comes from SHA-256 of the raw 32 bytes. Signatures and digests are lower-case hex.
        7. **`mac.battery`:** `charging` while on AC (desktops included); `null` when the battery cannot be read.
        8. **`waiting:` reasons**, a closed list: `memory`, `disk`, `battery`, `thermal`, `limit`, `slot`, `folder`, `paused`, `daily` (the daily job limit is reached; the state is exactly `waiting:daily`) + `signature` (no signature, or it does not match; Bridge neither runs the line nor asks for approval). `waitMaxMin` is 90 for `limit` only, `null` for the others. `failed:timeout` is a job over the maximum run time, `failed:lost` a job Bridge lost track of.
        9. **`object`:** Shelf posts commands and `ping` with `object: \"dev.ted2xmen.shelf\"`; Bridge listens with `name: nil` and this `object` (macOS does not deliver to a fully unfiltered observer).
        10. **`ref`** is read from the line and sent back unchanged; Bridge never computes it. The path has only three escapes: space `%20`, `@` `%40`, `%` `%25`. The runner decodes them in one pass, only for its inside-the-folder path check (`%2520` is the text `%20`); any other `%` makes the line `failed:path`, and `..` and symlink escapes are still refused. Example: `ref:My%20Notes/TODO.md@…` in `queue-lines.md`, with its `itemID` and `h8` in the `refs` block.
        11. **`now`:** the log's last meaningful line (one with a letter or digit), frame and prompt characters (`│ ╭ ❯ › > $ ⏺ ✻ …`) trimmed from both ends, at most 120 characters. **`asking`:** attended, running or stalled, no output for 60 s, and the last line ends with `?` or is an approval prompt (`(y/n)`, `Do you want`, `Allow`, `❯ 1.` …).
        12. **A command `id`** is a queue (`q-`) or scheduled (`s-`) id; `-` for `pause` / `resume`.
        13. **`log`:** a live job's lines are the screen text from tmux `capture-pane` (what the user sees in Terminal, with TUI redraws applied); a finished job answers with its last saved screen, or else its cleaned log file. Empty lines are dropped. `truncated`: older lines were left out, or a line was cut at 400 characters. The 16 KB limit is for the whole `json` string; when it does not fit, the oldest lines go first. An unknown job gets no answer.
        14. **`attach`:** the `.command` file first selects the job's window (`select-window -t '=<session>:<job id>'`), then attaches to the session; paths are single-quoted and there is no task text. `attached` and `attachError` stay in the status while the job is active; when it ends, both and the file are removed. If Terminal cannot be opened, neither field is written (Shelf's 3 s fallback takes over).
        15. **`asking` and `now`** for a live job come from the screen text. `asking` looks at the last 6 lines (Claude Code's folder-trust and choice screens end in their options: `Enter to confirm`, `Enter to select`, `Esc to cancel`, `❯ 1.` …). `now` skips footer lines (`shift+tab to cycle`, `? for shortcuts` …).
        16. **`blocked`:** the key is on every job. An unattended Claude job runs with `--output-format json`; when it ends, the number of `permission_denials` in the JSON becomes `blocked` (0 included), the `result` text goes to the log file, and the raw JSON stays in `~/Library/Logs/shelf-bridge/<id>.result.json`. `null` for attended jobs, Codex, running or waiting jobs, and when the JSON cannot be read. A denial does not change the state: exit 0 is `done`.
        17. **`styles`:** optional; only in the answer for a live window (`capture-pane -e`). Same count and order as `lines`, one `[start,len,fg,bg,flags]` array per run, `[]` for a line without colour; no key when no line has a run. `start`/`len` count Unicode scalars of the line in `lines` (the 400 cut counts characters (graphemes) as in `lines`; runs are clipped to the scalars the cut leaves). `fg`/`bg`: `-1` default, `0…255` palette, `≥256` truecolor `256 + (r<<16 | g<<8 | b)`; `flags`: 1 bold, 2 dim, 4 italic, 8 underline, 16 inverse. Runs are in increasing order, never overlap, at most 24 per line (the rest are dropped and the text stays plain). Spaces that look uncoloured (no background, underline or inverse) join a run when both sides have the same style, and stay outside it otherwise. `lines` and `truncated` are computed as if there were no `styles`; then, over 16 KB, the oldest lines' runs become `[]`, and if it still does not fit the key is dropped.

        """
    }

    static var files: [(String, String)] {
        var out: [(String, String)] = [("README.md", readme()), ("key.json", keyJSON()), ("queue-lines.md", queueLinesMarkdown()),
                                       ("commands.json", commandsJSON()), ("log-reply.json", logReplyJSON(logReply)),
                                       ("log-reply-plain.json", logReplyJSON(logReplyPlain))]
        for (name, s) in statusFiles { out.append((name, try! s.json(pretty: true) + "\n")) }
        return out
    }
}

@Suite struct ProtocolFixtureTests {
    @Test func fixturesMatchGenerator() throws {
        let regen = ProcessInfo.processInfo.environment["REGEN_PROTOCOL_FIXTURES"] == "1"
        if regen { try FileManager.default.createDirectory(at: ProtocolFixture.dir, withIntermediateDirectories: true) }
        for (name, content) in ProtocolFixture.files {
            let url = ProtocolFixture.dir.appendingPathComponent(name)
            if regen { try content.write(to: url, atomically: true, encoding: .utf8) }
            #expect(try String(contentsOf: url, encoding: .utf8) == content, "\(name) is stale: REGEN_PROTOCOL_FIXTURES=1")
        }
    }

    /// The fixture lines go through the real grammar and verifier, not the generator's own path.
    @Test func queueLinesVerifyThroughGrammar() throws {
        let text = try String(contentsOf: ProtocolFixture.dir.appendingPathComponent("queue-lines.md"), encoding: .utf8)
        let q = QueueGrammar.parse(text)
        #expect(q.invalid.isEmpty)
        #expect(q.items.count == ProtocolFixture.queueCases.count)
        for c in ProtocolFixture.queueCases {
            let item = try #require(q.item(id: c.id))
            #expect(ProtocolV2.queueCanonical(id: item.id, folder: ProtocolFixture.folder, title: item.title,
                                              agent: item.agent.rawValue, mode: item.mode.rawValue) == c.canonical, "\(c.id)")
            #expect(ProtocolV2.verify(key: ProtocolFixture.key, item: item, folder: ProtocolFixture.folder) == c.valid, "\(c.id): \(c.note)")
        }
        // String comparison is canonical-equivalence, so check the scalar: U+0301 COMBINING ACUTE ACCENT.
        #expect(text.unicodeScalars.contains("\u{0301}"), "the NFD line must stay NFD on disk")
    }

    @Test func statusFixturesRoundTrip() throws {
        for (name, expected) in ProtocolFixture.statusFiles {
            let data = try Data(contentsOf: ProtocolFixture.dir.appendingPathComponent(name))
            let decoded = try JSONDecoder().decode(StatusV2.self, from: data)
            #expect(decoded == expected, "\(name)")
            #expect(try decoded.json().utf8.count < StatusV2.maxBytes)
            #expect(decoded.jobs.allSatisfy { $0.log.count <= 3 && $0.log.allSatisfy { $0.count <= 200 } })
        }
        let unpaired = try String(contentsOf: ProtocolFixture.dir.appendingPathComponent("status-unpaired.json"), encoding: .utf8)
        #expect(unpaired.contains("\"keyId\" : null"), "unknown values are explicit nulls")
        #expect(unpaired.contains("\"diskFreeGB\" : null"))
    }

    @Test func logReplyFixtureDecodes() throws {
        let data = try Data(contentsOf: ProtocolFixture.dir.appendingPathComponent("log-reply.json"))
        let o = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let info = try #require(o["userInfo"] as? [String: Any])
        let reply = try JSONDecoder().decode(LogReply.self, from: Data(try #require(info["json"] as? String).utf8))
        #expect(reply == ProtocolFixture.logReply)
        let lines = ["Reading CHANGELOG.md", "Drafting notes for 1.4", "100% docs/release-1.4.md",
                     "⏺ Wrote docs/release-1.4.md", "Do you want to commit these notes? (y/n)"]
        #expect(reply.lines == lines)
        let orange = 256 + (215 << 16 | 119 << 8 | 87)
        #expect(reply.styles == [[[0, 7, -1, -1, 1], [8, 12, 153, -1, 0]],
                                 [[0, 18, -1, -1, 2], [19, 3, orange, -1, 2]],
                                 [[0, 4, orange, -1, 2], [5, 19, 2, -1, 0]],
                                 [[0, 1, 246, -1, 0], [8, 19, -1, -1, 8]],
                                 [[0, 34, 220, -1, 0], [35, 5, -1, -1, 16]]])

        // The old form: no `styles` key at all, same lines.
        let old = try Data(contentsOf: ProtocolFixture.dir.appendingPathComponent("log-reply-plain.json"))
        let oldInfo = try #require((try JSONSerialization.jsonObject(with: old) as? [String: Any])?["userInfo"] as? [String: Any])
        let oldJSON = try #require(oldInfo["json"] as? String)
        #expect(!oldJSON.contains("styles"))
        let plain = try JSONDecoder().decode(LogReply.self, from: Data(oldJSON.utf8))
        #expect(plain == ProtocolFixture.logReplyPlain && plain.styles == nil && plain.lines == lines)
    }

    @Test func pairCodeRoundTrip() throws {
        let code = PairCode.encode(ProtocolFixture.key)
        #expect(code.hasPrefix("SB1-") && code.count == 4 + 52)
        #expect(PairCode.decode(code) == ProtocolFixture.key)
        let sloppy = code.lowercased().enumerated().map { $0.offset % 6 == 5 ? "\($0.element) " : "\($0.element)" }.joined()
        #expect(PairCode.decode(sloppy) == ProtocolFixture.key)
        #expect(PairCode.decode("SR2-" + code.dropFirst(4)) == nil)
        #expect(PairCode.decode(String(code.dropLast())) == nil)
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        #expect(PairCode.decode(PairCode.encode(random)) == random)
    }

    @Test func commandGate() throws {
        var gate = CommandGate(key: ProtocolFixture.key)
        let ts = ProtocolFixture.commandTS
        let name = ProtocolV2.commandName(key: ProtocolFixture.key, verb: .run, id: "q-20261022T1630-7f3a", ts: ts)
        #expect(gate.accept(name, now: ts + 5) == .success(.init(verb: .run, id: "q-20261022T1630-7f3a", ts: ts, sig: String(name.suffix(16)))))
        #expect(gate.accept(name, now: ts + 6) == .failure(.replay))
        #expect(gate.accept(ProtocolV2.commandName(key: ProtocolFixture.key, verb: .stop, id: "q-20261022T1630-7f3a", ts: ts), now: ts + 61) == .failure(.stale))
        #expect(gate.accept(ProtocolV2.commandName(key: ProtocolFixture.otherKey, verb: .stop, id: "q-20261022T1630-7f3a", ts: ts), now: ts) == .failure(.badSignature))
        let pause = ProtocolV2.commandName(key: ProtocolFixture.key, verb: .pause, id: nil, ts: ts)
        #expect(pause.contains(".pause.-."))
        #expect(gate.accept(pause, now: ts) == .success(.init(verb: .pause, id: nil, ts: ts, sig: String(pause.suffix(16)))))
        #expect(gate.accept("dev.ted2xmen.shelf-bridge.cmd.pause.q-20261022T1630-7f3a.\(ts).0123456789abcdef", now: ts) == .failure(.malformed))
        #expect(gate.accept("dev.ted2xmen.shelf-bridge.cmd.run.../etc.\(ts).0123456789abcdef", now: ts) == .failure(.malformed))
        #expect(gate.accept("dev.ted2xmen.shelf-bridge.cmd.explode.-.\(ts).0123456789abcdef", now: ts) == .failure(.malformed))
    }
}
