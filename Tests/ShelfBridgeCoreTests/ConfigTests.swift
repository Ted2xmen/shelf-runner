import Foundation
import Testing
@testable import ShelfBridgeCore

@Suite struct ConfigTests {
    @Test func tomlSubset() throws {
        let t = try TOML.parse("""
        # comment
        top = 1
        [a]
        s = "x # not a comment" # comment
        b = true
        f = 1.5
        n = 1_000
        arr = ["p", "q", 3]
        esc = "a\\"b\\\\c"
        """)
        #expect(t["top"] == .int(1))
        #expect(t["a.s"] == .string("x # not a comment"))
        #expect(t["a.b"] == .bool(true))
        #expect(t["a.f"] == .double(1.5))
        #expect(t["a.n"] == .int(1000))
        #expect(t["a.arr"] == .array([.string("p"), .string("q"), .int(3)]))
        #expect(t["a.esc"] == .string("a\"b\\c"))
    }

    @Test func tomlErrors() {
        #expect(throws: TOMLError.self) { try TOML.parse("x = ") }
        #expect(throws: TOMLError.self) { try TOML.parse("x = \"open") }
        #expect(throws: TOMLError.self) { try TOML.parse("x = 1\nx = 2") }
        #expect(throws: TOMLError.self) { try TOML.parse("[[t]]") }
        #expect(throws: TOMLError.self) { try TOML.parse("x = 1 2") }
    }

    @Test func config() throws {
        let c = try Config.parse("""
        [agents]
        claude = "/bin/c"
        [tmux]
        socket = "sock"
        path = ""
        extra = 1
        """)
        #expect(c.agentPaths[.claude] == "/bin/c")
        #expect(c.agentPaths[.codex] == nil)
        #expect(c.tmuxSocket == "sock")
        #expect(c.tmuxPath == nil, "empty string means default")
        #expect(c.unknownKeys == ["tmux.extra"])
        #expect(throws: TOMLError.self) { try Config.parse("[agents]\nclaude = 3") }
    }

    @Test func resourceThresholds() throws {
        let c = try Config.parse("[resources]\ndisk_wait_gb = 20\ndisk_stop_gb = 8\nbattery_percent = 30\nlimit_percent = 80\nlimit_wait_minutes = 30\n")
        #expect(c.policy.diskWaitGB == 20 && c.policy.diskStopGB == 8 && c.policy.batteryMinPercent == 30)
        #expect(c.policy.limitPercent == 80 && c.policy.limitMaxWait == 1800)
        #expect(c.unknownKeys.isEmpty)
        #expect(throws: TOMLError.self) { try Config.parse("[resources]\nlimit_percent = 0") }
    }

    @Test func missingConfigIsDefault() throws {
        let tmp = try TempDir("cfg")
        #expect(try Config.load(from: tmp.url.appendingPathComponent("nope.toml")) == Config())
    }
}

@Suite struct FolderRegistryTests {
    @Test func enableDisablePersist() throws {
        let home = try TempDir("home"), work = try TempDir("work")
        let folder = try work.sub("Project")
        let r = Runner(paths: Paths(home: home.url), config: Config(), wrapExecutable: "/x")

        let e1 = try r.enable(folder.path + "/./")
        #expect(e1.changed && e1.path == folder.path)
        #expect(try !r.enable(folder.path).changed)
        #expect(try FolderRegistry.load(Paths(home: home.url)).folders.map(\.path) == [folder.path])

        #expect(throws: RunnerError.self) { try r.enable(work.url.appendingPathComponent("missing").path) }

        #expect(try r.disable(folder.path).changed)
        #expect(try !r.disable(folder.path).changed)
        #expect(try r.list().isEmpty)
    }

    @Test func symlinkResolvesToSameFolder() throws {
        let work = try TempDir("link")
        let real = try work.sub("real")
        let link = work.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(try FolderRegistry.canonical(link.path) == real.path)
    }
}
