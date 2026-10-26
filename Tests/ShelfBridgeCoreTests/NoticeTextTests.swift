import Foundation
import Testing
@testable import ShelfBridgeCore

struct NoticeTextTests {
    @Test func titleIsTheTaskAndStaysOneLine() {
        #expect(NoticeText.title("  Write the test note ") == "Write the test note")
        let long = String(repeating: "a", count: 80)
        let t = NoticeText.title(long)
        #expect(t.count == NoticeText.maxTitle)
        #expect(t.hasSuffix("…"))
        #expect(!t.contains("shelf-bridge"))
    }

    @Test func approvalBodyIsShort() {
        #expect(NoticeText.approval(agent: "claude", folder: "/Users/x/Documents/SHELF-TEST", unattended: false, schedule: nil)
                == "Claude · SHELF-TEST")
        #expect(NoticeText.approval(agent: "codex", folder: "/a/Apps", unattended: true, schedule: "2026-10-26 09:00 every:week")
                == "Codex · Apps · unattended · 2026-10-26 09:00 every:week")
    }

    @Test func otherBodies() {
        #expect(NoticeText.timedOut(after: "2 h") == "Stopped at the 2 h limit")
        #expect(NoticeText.limitWaitOver(after: "90 min") == "Started after a 90 min limit wait")
        let at = ISO.parse("2026-10-23T09:00:00+03:00")!
        let body = NoticeText.missed(at, timeZone: TimeZone(identifier: "Europe/Istanbul")!)
        #expect(body == "Missed the Oct 23, 09:00 run: Bridge was off")
        #expect(!body.contains("+03:00"))
    }
}
