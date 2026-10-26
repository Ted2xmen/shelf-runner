import Foundation
import Testing
@testable import ShelfBridgeCore

/// Log-answer `styles` (`AnsiText`, the `LogReply` budget) and the status-line cut in `now`.
@Suite struct AnsiTextTests {
    let esc = "\u{1B}"

    /// One screen of Claude Code 2.1.308 under tmux 3.6a (2026-10-23, a test job), captured
    /// with `capture-pane -p -J` and with `-p -e -J`; only the home path was replaced.
    static func screen(_ kind: String) throws -> String {
        try String(contentsOf: Fixture.dir.appendingPathComponent("screens/claude-done.\(kind).txt"), encoding: .utf8)
    }

    func line(_ p: (lines: [String], styles: [[AnsiText.Run]]), _ prefix: String) throws -> (String, [[Int]]) {
        let i = try #require(p.lines.firstIndex { $0.hasPrefix(prefix) }, "\(prefix)")
        return (p.lines[i], p.styles[i].map(\.array))
    }

    @Test func colouredLinesAreThePlainCaptureLines() throws {
        let plain = try Self.screen("plain"), ansi = try Self.screen("ansi")
        let p = AnsiText.parse(raw: ansi)
        #expect(p.lines == LogTail.allLines(plain), "what Shelf gets today for the same screen")
        #expect(p.lines == LogTail.allLines(ansi))
        #expect(p.styles.count == p.lines.count)
        #expect(p.styles.contains { !$0.isEmpty })
    }

    @Test func realScreenRuns() throws {
        let p = AnsiText.parse(raw: try Self.screen("ansi"))
        let (not, notRuns) = try line(p, "- Note:")
        #expect(notRuns.first == [2, 5, -1, -1, 1], "bold `Note:` after the trimmed bullet")
        let path = try #require(notRuns.dropFirst().first)
        #expect(Array(not.unicodeScalars)[path[0]..<(path[0] + path[1])].map(String.init).joined() == "SHELF-TEST/notes/g4.md")
        #expect(path[2] == 153)
        // `ESC[38;5;153mnotes/` ends a line; the next one opens with `ESC[39m`: default again.
        let (_, wrapped) = try line(p, "did not exist")
        #expect(wrapped.isEmpty)
        // "Worked for …" leaves 246 set at the line end; the status line under it starts in it.
        let (workedLine, worked) = try line(p, "✻ Worked for")
        #expect(worked == [[0, workedLine.unicodeScalars.count, 246, -1, 0]], "glyph, space and text in one run")
        let (_, status) = try line(p, "○ no")
        #expect(status.first?[0] == 0 && status.first?[2] == 246, "SGR state carries across lines")
        #expect(status.contains { $0[2] == 72 })
        let (_, prompt) = try line(p, "❯")
        #expect(prompt.contains { $0[4] == AnsiText.Style.dim }, "the draft is dim")
        let (_, footer) = try line(p, "/Users/test")
        #expect(footer.first?[2] == 1, "palette red")
    }

    @Test func sgrCodes() {
        func runs(_ s: String) -> [[Int]] { AnsiText.parse(raw: s).styles.first?.map(\.array) ?? [] }
        #expect(runs("\(esc)[1ma\(esc)[2mb\(esc)[22mc") == [[0, 1, -1, -1, 1], [1, 1, -1, -1, 3]])
        #expect(runs("\(esc)[3ma\(esc)[4mb\(esc)[23;24mc") == [[0, 1, -1, -1, 4], [1, 1, -1, -1, 12]])
        #expect(runs("\(esc)[7ma\(esc)[27mb") == [[0, 1, -1, -1, 16]])
        #expect(runs("\(esc)[31;42ma\(esc)[39mb\(esc)[49mc") == [[0, 1, 1, 2, 0], [1, 1, -1, 2, 0]])
        #expect(runs("\(esc)[91;103ma\(esc)[0mb") == [[0, 1, 9, 11, 0]])
        #expect(runs("\(esc)[38;5;246;48;5;17ma") == [[0, 1, 246, 17, 0]])
        let orange = 256 + (215 << 16 | 119 << 8 | 87)
        #expect(runs("\(esc)[38;2;215;119;87ma") == [[0, 1, orange, -1, 0]])
        #expect(runs("\(esc)[48;2;0;0;0;1ma") == [[0, 1, -1, 256, 1]], "params after a truecolor go on")
        #expect(runs("\(esc)[38:2::215:119:87ma\(esc)[38:5:9mb\(esc)[38:2:215:119:87mc") ==
                [[0, 1, orange, -1, 0], [1, 1, 9, -1, 0], [2, 1, orange, -1, 0]], "colon forms")
        #expect(runs("\(esc)[4:3ma\(esc)[4:0mb") == [[0, 1, -1, -1, 8]])
        #expect(runs("\(esc)[58;5;1ma") == [], "underline colour is skipped with its arguments")
        #expect(runs("\(esc)[>4;2ma\(esc)[?1mb") == [], "private CSI m is not SGR")
        #expect(runs("\(esc)[1m\(esc)[ma") == [], "empty SGR resets")
        #expect(runs("\(esc)[38;5;999ma") == [], "out of range colour ignored")
    }

    @Test func runsMergeBridgeAndCap() {
        let c = "\(esc)[38;5;246m"
        // Plain spaces between two equal styles join them; at the edges they stay outside.
        #expect(AnsiText.parse(raw: "x \(c)a\(esc)[39m  \(c)b\(esc)[39m y").styles[0].map(\.array) == [[2, 4, 246, -1, 0]])
        #expect(AnsiText.parse(raw: "\(c)a \(esc)[31mb").styles[0].map(\.array) == [[0, 1, 246, -1, 0], [2, 1, 1, -1, 0]])
        // A space with a background or inverse is visible: never bridged or dropped.
        #expect(AnsiText.parse(raw: "\(esc)[44m \(esc)[49ma\(esc)[44m \(esc)[49mb").styles[0].map(\.array) == [[1, 1, -1, 4, 0]],
                "leading space trimmed; inner one keeps its background")
        let many = (0..<30).map { "\(esc)[38;5;\($0 % 2 == 0 ? 1 : 2)mx" }.joined()
        let r = AnsiText.parse(raw: many).styles[0]
        #expect(r.count == AnsiText.maxRuns && r.last?.start == 23, "first 24 runs kept, tail plain")
    }

    /// Any mix of text, escapes and controls: `lines` is exactly the plain path, runs stay in range.
    @Test func linesEqualPlainPathOnNoise() {
        let parts = ["a", "\u{15F}", "\u{130}", "e\u{301}", "👍🏽", "🇯🇵", " ", "  ", "\u{A0}", "\t", "\n", "\r\n", "\r", "\u{08}", "─",
                     "\(esc)[1m", "\(esc)[0m", "\(esc)[38;5;153m", "\(esc)[38;2;1;2;3m", "\(esc)[48;5;4m", "\(esc)[7m", "\(esc)[m",
                     "\(esc)[10G", "\(esc)[2B", "\(esc)(B", "\(esc)]8;;https://x\(esc)\\", "\(esc)]0;t\u{07}", "\(esc)[?25l", "\u{0F}", "\u{7F}"]
        var seed: UInt64 = 0x5EED
        for _ in 0..<400 {
            var raw = ""
            for _ in 0..<60 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                raw += parts[Int(seed >> 33) % parts.count]
            }
            let p = AnsiText.parse(raw: raw)
            #expect(p.lines == LogTail.allLines(raw), "\(raw.debugDescription)")
            for (l, runs) in zip(p.lines, p.styles) {
                let n = l.unicodeScalars.count
                #expect(runs.count <= AnsiText.maxRuns)
                #expect(runs.allSatisfy { $0.len > 0 && $0.start >= 0 && $0.start + $0.len <= n && $0.style != .plain })
                #expect(zip(runs, runs.dropFirst()).allSatisfy { $0.start + $0.len <= $1.start })
            }
        }
    }
}

@Suite struct LogReplyStyleTests {
    let esc = "\u{1B}"

    func reply(_ raw: String) -> LogReply {
        let p = AnsiText.parse(raw: raw)
        return LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "x", lines: p.lines, styles: p.styles, partial: false)
    }

    func plain(_ raw: String) -> LogReply {
        LogReply.make(id: "q-20261022T1630-7f3a", state: "running", at: "x", lines: LogTail.allLines(raw), partial: false)
    }

    /// The 400 cut is by Character, as `lines` always was; runs end at the scalars it kept.
    @Test func cutClipsRunsInScalars() throws {
        let red = "\(esc)[31m"
        let combining = red + String(repeating: "a", count: 399) + "e\u{301}xyz"
        let r = reply(combining)
        #expect(r.lines == plain(combining).lines && r.truncated)
        #expect(r.lines[0].count == 400 && r.lines[0].unicodeScalars.count == 401)
        #expect(r.styles == [[[0, 401, 1, -1, 0]]])

        let emoji = String(repeating: "a", count: 398) + "\(red)👍🏽🇯🇵b"
        let e = reply(emoji)
        #expect(e.lines[0].hasSuffix("👍🏽🇯🇵") && e.lines[0].unicodeScalars.count == 402)
        #expect(e.styles == [[[398, 4, 1, -1, 0]]])

        let after = String(repeating: "a", count: 405) + "\(red)z"
        #expect(reply(after).styles == nil, "a run wholly past the cut is gone; no run left, no field")
    }

    /// `lines` fit first, exactly as without colours; then runs are blanked from the oldest line.
    @Test func budgetLinesFirstThenOldestStyles() throws {
        let raw = (0..<200).map { i in
            "\(i) " + (0..<12).map { "\(esc)[38;2;\($0);200;100mw\($0)\(esc)[0m" }.joined(separator: " ")
        }.joined(separator: "\n")
        let r = reply(raw), p = plain(raw)
        #expect(r.lines == p.lines && r.truncated == p.truncated, "colours never cost a line")
        let styles = try #require(r.styles)
        #expect(styles.count == r.lines.count)
        #expect(try r.json().utf8.count <= LogReply.maxBytes)
        #expect(styles.first == [] && styles.last?.isEmpty == false, "oldest blanked first")
        let firstKept = try #require(styles.firstIndex { !$0.isEmpty })
        #expect(styles[firstKept...].allSatisfy { !$0.isEmpty })
        let full = AnsiText.parse(raw: raw).styles.suffix(r.lines.count).map { $0.map(\.array) }
        var oneMore = r
        oneMore.styles![firstKept - 1] = full[firstKept - 1]
        #expect(try oneMore.json().utf8.count > LogReply.maxBytes, "no more lines blanked than needed")
    }

    @Test func budgetDropsTheFieldWhenEvenEmptyDoesNotFit() throws {
        let raw = (0..<200).map { "\(esc)[1m\($0)\(esc)[0m " + String(repeating: "x", count: 90) }.joined(separator: "\n")
        let r = reply(raw)
        #expect(r.lines == plain(raw).lines && r.truncated)
        #expect(try r.styles == nil && !r.json().contains("styles"))
        #expect(try plain(raw).json().utf8.count + 3 * r.lines.count + 10 > LogReply.maxBytes, "even all [] would not fit")
    }

    @Test func plainScreenHasNoField() throws {
        let r = reply("just text\nand more\n")
        #expect(try r.styles == nil && !r.json().contains("styles"))
        // An answer without the field (old runner, finished job) decodes.
        let old = #"{"at":"x","id":"q-1","lines":["a"],"state":"done","truncated":false}"#
        #expect(try JSONDecoder().decode(LogReply.self, from: Data(old.utf8)).styles == nil)
    }
}

/// The user's Claude Code status line sits between the activity line and the input box.
@Suite struct StatusLineTests {
    let rule = String(repeating: "─", count: 80)
    let footer = ["/Users/test/SHELF-TEST  Opus 5.5 (1M context)", "-- INSERT -- ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"]
    let status = ["○ no agents · cache – · [ Handoff + Clear ]",
                  "70516 tokens · current: 2.1.308 · latest: 2.1.309 ✓ Update installed · Restart to update"]

    func box(_ draft: String = "❯ ") -> [String] { [rule, draft, rule] + footer }

    @Test func statusLineBelowWorkedForIsNotNow() throws {
        let screen = LogTail.allLines(try AnsiTextTests.screen("plain"))
        let gates = "Gates: not applicable (not a TS project, only two markdown files changed)."
        // StatusBuilder hands `now` the last 12 screen lines.
        #expect(JobSummary.now(Array(screen.suffix(12))) == gates)
        #expect(JobSummary.now(screen) == gates)
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: Array(screen.suffix(12)), quietFor: 600))
        let hand = ["⏺ Wrote notes/g4.md", "  " + gates, "✻ Worked for 34s · done 10:05 AM"] + status + box("❯ close the queue line too")
        #expect(JobSummary.now(hand) == gates)
    }

    @Test func interleavedStatusLinesAreCut() throws {
        let screen = LogTail.allLines(try AnsiTextTests.screen("plain"))
        let shown = JobSummary.meaningful(screen)
        #expect(!shown.contains { $0.hasPrefix("○ no") || $0.hasPrefix("agents") || $0.contains("70516 tokens") })
        #expect(!shown.contains { $0.contains("Worked for") })
        #expect(shown.last?.hasPrefix("Gates:") == true)
    }

    @Test func statusLineWhileWorking() {
        let screen = ["⏺ Update(Sources/Paywall.swift)", "⏺ Reading Sources/Paywall.swift", "✻ Topsy-turvying… (28s · ↓ 1.1k tokens)"] + status + box()
        #expect(JobSummary.now(screen) == "Reading Sources/Paywall.swift")
        #expect(!JobSummary.meaningful(screen).contains { $0.contains("Handoff") || $0.contains("Topsy") })
        let interrupt = ["⏺ Running tests", "✶ Testing (12s · esc to interrupt)"] + status + box()
        #expect(JobSummary.now(interrupt) == "Running tests")
    }

    @Test func statusLineThenQuestionDialog() {
        let screen = ["⏺ I could not find the code.", "✻ Worked for 34s · done 10:05 AM"] + status +
            [rule, "← ☐ Site code  ✔ Submit  →", "│ How should I go on?", "❯ 1. I will give the path", "  4. Type something.",
             rule, "  5. Chat about this", "Enter to select · Esc to cancel"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: screen, quietFor: 600))
        #expect(JobSummary.now(screen) == "How should I go on?")
        // A permission box right under an activity line: the drop stops at its frame.
        let permission = ["✻ Running… (3s · esc to interrupt)", "╭────────────────────────╮", "│ Bash command           │",
                          "│ Do you want to proceed? │", "│ ❯ 1. Yes               │", "│   2. No                │", "╰────────────────────────╯"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: permission, quietFor: 600))
        #expect(JobSummary.now(permission) == "Do you want to proceed?")
        // (y/n) and the trust screen under an activity line still ask.
        let yn = ["✻ Worked for 2s", "Do you want to commit these notes? (y/n)"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: yn, quietFor: 61))
        let trust = ["✻ Worked for 2s", "Quick safety check: Is this a project you created or one you trust?", "❯ No, exit",
                     "Yes, I trust this folder", "Enter to confirm · Esc to cancel"]
        #expect(JobSummary.asking(mode: "attended", state: "running", lines: trust, quietFor: 61))
        // The user's draft in the input box still does not count.
        let draft = ["⏺ Done.", "✻ Worked for 5s · done 10:05 AM"] + status + box("❯ is this ok?")
        #expect(!JobSummary.asking(mode: "attended", state: "running", lines: draft, quietFor: 600))
        #expect(JobSummary.now(draft) == "Done.")
    }

    @Test func noActivityLineUnchanged() {
        let idle = ["⏺ Done: wrote the list.", "* a bullet without a timer", "· middle dot list item"] + box()
        #expect(JobSummary.content(idle) == Array(idle.prefix(3)), "only the input box goes")
        let noBox = ["⏺ Done.", "plain tail"]
        #expect(JobSummary.content(noBox) == noBox)
        #expect(!JobSummary.isActivity("*bold* text… here"), "a glyph needs a space after it")
        #expect(!JobSummary.isActivity("· item (5 files)"), "no timer, no ellipsis")
        #expect(JobSummary.isActivity("✽ Thinking…") && JobSummary.isActivity("  ✢ Boogieing (3s)"))
        #expect(!JobSummary.isActivity("* Waiting for CI…") && !JobSummary.isActivity("· Retrying (30s"),
                "a Markdown bullet with … or a timer is a reply")
        #expect(JobSummary.isActivity("· Thinking… (3s · esc to interrupt)") && JobSummary.isActivity("* Worked for 2s"))
        let reply = ["⏺ Plan:", "* Waiting for CI…", "  then merge the branch"] + box()
        #expect(JobSummary.now(reply) == "then merge the branch", "a bullet reply does not cut the lines under it")
        #expect(!JobSummary.isChrome("I worked for hours on this") && JobSummary.isChrome("✻ Worked for 34s"),
                "\"worked for \" is chrome only at the line start")
        #expect(JobSummary.clean("✽ Thinking") == "Thinking")
    }

    /// Known limit: without an activity line a status line still shows, and a status line that
    /// looks like one (spinner glyph, space, `…`) is the last one: only lines from it down are cut.
    /// A `*`/`·` bullet with `…` is not one any more, so it is cut with the rest.
    @Test func userStatusLineStartingWithGlyph() {
        let glyph = "* main… 3 files"
        let screen = ["⏺ Done.", "✻ Worked for 34s · done 10:05 AM", status[0], glyph] + box()
        #expect(JobSummary.now(screen) == "Done.", "a bullet with … is not an activity line")
        let spinner = ["⏺ Done.", "✻ Worked for 34s · done 10:05 AM", status[0], "✢ main… 3 files"] + box()
        #expect(JobSummary.now(spinner) == status[0], "documented limit")
        let worked = ["⏺ Done.", "✻ Worked for 34s · done 10:05 AM", glyph] + box()
        #expect(JobSummary.now(worked) == "Done.", "\"worked for \" chrome backs the cut up")
        let none = ["⏺ Done."] + status + box()
        #expect(JobSummary.now(none) == "70516 tokens · current: 2.1.308 · latest: 2.1.309 ✓ Update installed · Restart to update",
                "documented limit: no activity line, no cut")
    }
}
