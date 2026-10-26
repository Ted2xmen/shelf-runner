import Foundation
import Testing
@testable import ShelfBridgeCore

/// `doctor`: green means no `fail`. Fixed probes; fake tools in a temp PATH.
@Suite struct DoctorTests {
    let home: TempDir
    let bin: URL
    let paths: Paths

    init() throws {
        home = try TempDir("doc")
        paths = Paths(home: home.url)
        try paths.ensureDirectories()
        bin = try home.sub("bin")
    }

    func tool(_ name: String, prints: String = "") throws {
        let u = bin.appendingPathComponent(name)
        try "#!/bin/sh\necho '\(prints)'\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }

    /// An executable at the path a real install has: `<dir>/ShelfBridge.app/Contents/MacOS/shelf-bridge`.
    func fakeApp() throws -> String {
        let macos = try home.sub("Applications/ShelfBridge.app/Contents/MacOS")
        let exe = macos.appendingPathComponent("shelf-bridge")
        try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe.path
    }

    func agentPlist(program: String) throws {
        let url = Doctor.plist(paths)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d: [String: Any] = ["Label": Doctor.label, "ProgramArguments": [program, "agent"]]
        try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: url)
    }

    func probe(loaded: Bool? = true, running: Bool = true, inBundle: Bool = true, major: Int = 15) -> Doctor.Probe {
        // PATH holds only the temp bin, but the locator also looks in /opt/homebrew/bin and friends:
        // config.toml pins every tool so the machine's own installs never leak in.
        Doctor.Probe(paths: paths, environment: ["PATH": bin.path], executable: "/Applications/ShelfBridge.app/Contents/MacOS/shelf-bridge",
                     inAppBundle: inBundle, serviceLoaded: { loaded }, agentRunning: { running },
                     osVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 1, patchVersion: 0))
    }

    func config(_ extra: String = "") throws {
        try FileManager.default.createDirectory(at: paths.configDir, withIntermediateDirectories: true)
        try """
        [agents]
        claude = "\(bin.path)/claude"
        codex = "\(bin.path)/codex"
        [tmux]
        path = "\(bin.path)/tmux"
        \(extra)
        """.write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    func enable(_ folder: URL) throws {
        var reg = try FolderRegistry.load(paths)
        _ = reg.enable(try FolderRegistry.canonical(folder.path))
        try reg.save(paths)
    }

    func level(_ checks: [Doctor.Check], _ name: String) -> Doctor.Level? { checks.first { $0.name == name }?.level }

    @Test func healthyInstall() throws {
        try config()
        try tool("tmux", prints: "tmux 3.6a"); try tool("claude"); try tool("codex")
        try agentPlist(program: try fakeApp())
        _ = try KeyStore.pair(paths)
        let folder = try home.sub("Folder")
        try enable(folder)

        let checks = Doctor.run(probe())
        #expect(checks.allSatisfy { $0.level == .ok }, "\(Doctor.render(checks))")
        #expect(checks.contains { $0.name == "tmux" && $0.detail.hasSuffix("tmux 3.6a") })
        #expect(Doctor.render(checks).contains("✓ LaunchAgent"))
    }

    @Test func freshMacWithoutToolsFails() throws {
        try config()
        let checks = Doctor.run(probe(loaded: false, running: false, inBundle: false, major: 13))
        #expect(level(checks, "macOS") == .fail)
        #expect(level(checks, "tmux") == .fail)
        #expect(level(checks, "claude") == .warn && level(checks, "codex") == .warn)
        #expect(level(checks, "agent") == .fail, "neither agent")
        #expect(level(checks, "app") == .warn)
        #expect(level(checks, "LaunchAgent") == .fail)
        #expect(level(checks, "background agent") == .fail)
        #expect(level(checks, "pairing") == .warn && level(checks, "folders") == .warn)
    }

    @Test func oneAgentIsEnoughAndBadPlistIsCaught() throws {
        try config()
        try tool("tmux", prints: "tmux 3.5"); try tool("codex")
        try agentPlist(program: "/nowhere/ShelfBridge.app/Contents/MacOS/shelf-bridge")
        let checks = Doctor.run(probe())
        #expect(level(checks, "claude") == .warn && level(checks, "agent") == nil)
        #expect(checks.first { $0.name == "LaunchAgent" }?.detail.contains("/nowhere/") == true)
        #expect(level(checks, "LaunchAgent") == .fail)

        try agentPlist(program: bin.appendingPathComponent("tmux").path)
        #expect(level(Doctor.run(probe()), "app") == .warn, "the agent's binary is outside the app: no notifications")
        try agentPlist(program: try fakeApp())
        #expect(level(Doctor.run(probe(inBundle: false)), "app") == .ok, "judged by the agent's binary, not this CLI")
        #expect(level(Doctor.run(probe(loaded: false)), "LaunchAgent") == .fail, "plist there but not loaded")
        #expect(level(Doctor.run(probe(loaded: nil)), "LaunchAgent") == .ok, "launchctl unavailable: trust the plist")
    }

    @Test func unreadableLockIsNotRunning() throws {
        try config()
        let p = Doctor.Probe(paths: paths, environment: [:], executable: "/x", inAppBundle: true,
                             serviceLoaded: { true }, agentRunning: { nil })
        let c = Doctor.run(p).first { $0.name == "background agent" }
        #expect(c?.level == .fail && c?.detail.contains("lock file") == true)
    }

    @Test func brokenConfigAndMissingFolder() throws {
        try config("[bridge]\nmax_parallel = \"x\"\n")
        #expect(level(Doctor.run(probe()), "config.toml") == .fail)
        try config("[bridge]\nunknown_key = 1\n")
        #expect(level(Doctor.run(probe()), "config.toml") == .warn)

        let gone = try home.sub("Gone")
        try enable(gone)
        try FileManager.default.removeItem(at: gone)
        let folder = Doctor.run(probe()).first { $0.name == "folder" }
        #expect(folder?.level == .warn && folder?.detail.contains("disable") == true)
    }
}
