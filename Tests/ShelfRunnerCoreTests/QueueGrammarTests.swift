import Testing
@testable import ShelfRunnerCore

@Suite struct QueueGrammarTests {
    @Test func validFixture() throws {
        let q = QueueGrammar.parse(try Fixture.text("queue/valid.md"))
        #expect(q.invalid.isEmpty)
        #expect(q.items.map(\.id) == ["q-20261021T1305-7f3a", "q-20261020T0900-0001", "q-20261021T1306-00ff", "q-20261021T1308-0003"])

        let first = try #require(q.items.first)
        #expect(first.title == "Write release notes for Pantheon 1.4")
        #expect(first.agent == .claude && first.mode == .attended && !first.checked)
        #expect(first.ref == "TODO.md@a41c09e2" && first.by == "you" && first.sig == "5c1e9a02" && first.line == 3)

        #expect(q.items[1].checked)
        let third = q.items[2]
        #expect(third.mode == .attended, "mode defaults to attended")
        #expect(third.title == "Default mode and note:this stays in the title", "keys outside the closed list stay in the title")
        #expect(third.out == "reports/")
        #expect(q.items[3].mode == .unattended)
    }

    @Test func invalidFixture() throws {
        let q = QueueGrammar.parse(try Fixture.text("queue/invalid.md"))
        #expect(q.items.map(\.id) == ["q-20261021T1305-0007"])
        let errors = q.invalid.map(\.error)
        #expect(errors == [
            .missingKey("id"),
            .badValue(key: "id", value: "20261021-7f3a"),
            .badValue(key: "agent", value: "gpt"),
            .duplicateKey("id"),
            .emptyValue("agent"),
            .badValue(key: "mode", value: "auto"),
            .badValue(key: "ref", value: "TODO.md"),
            .duplicateID("q-20261021T1305-0007", firstLine: 8),
            .missingKey("title"),
        ])
    }

    @Test func trailingFragmentIsIgnored() throws {
        let q = QueueGrammar.parse(try Fixture.text("queue/partial.md"))
        #expect(q.items.map(\.id) == ["q-20261021T1305-0001"])
        #expect(q.invalid.isEmpty)
    }

    @Test func crlfAndNonTaskLines() {
        let q = QueueGrammar.parse("- [ ] a id:q-20261021T1305-0001 agent:claude\r\n* [ ] a star does not count id:q-20261021T1305-0002 agent:claude\n")
        #expect(q.items.map(\.title) == ["a"])
    }

    @Test func idFormat() {
        #expect(QueueGrammar.isValidID("q-20261021T1305-7f3a"))
        #expect(!QueueGrammar.isValidID("q-20261021T1305-7F3A"))
        #expect(!QueueGrammar.isValidID("s-20261021T1305-7f3a"))
        #expect(!QueueGrammar.isValidID("q-20261021T1305-7f3a/../x"))
    }
}
