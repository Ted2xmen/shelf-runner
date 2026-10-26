import Foundation

/// `shelf-bridge doctor`: what a fresh install needs, one line per check. Green means
/// no `fail`; a `warn` is something the user may want (pairing, a second agent) but can run without.
public enum Doctor {
    public enum Level: String, Sendable { case ok, warn, fail }

    public struct Check: Equatable, Sendable {
        public var level: Level
        public var name: String
        public var detail: String
    }

    /// What the checks read from the machine; tests pass fixed values.
    public struct Probe {
        public var paths: Paths
        public var environment: [String: String]
        /// The running binary, symlinks resolved.
        public var executable: String
        public var inAppBundle: Bool
        /// `nil` = launchctl could not be asked.
        public var serviceLoaded: () -> Bool?
        /// `nil` = the lock file could not be opened.
        public var agentRunning: () -> Bool?
        public var osVersion: OperatingSystemVersion

        public init(paths: Paths, environment: [String: String], executable: String, inAppBundle: Bool,
                    serviceLoaded: @escaping () -> Bool?, agentRunning: @escaping () -> Bool?,
                    osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
            self.paths = paths; self.environment = environment; self.executable = executable; self.inAppBundle = inAppBundle
            self.serviceLoaded = serviceLoaded; self.agentRunning = agentRunning; self.osVersion = osVersion
        }
    }

    public static let label = "dev.ted2xmen.shelf-bridge"

    public static func plist(_ paths: Paths) -> URL {
        paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func run(_ p: Probe) -> [Check] {
        var out: [Check] = []
        func add(_ l: Level, _ n: String, _ d: String) { out.append(Check(level: l, name: n, detail: d)) }

        let v = p.osVersion
        add(v.majorVersion >= 14 ? .ok : .fail, "macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(v.majorVersion >= 14 ? "" : " (14 or later required)")")

        var config = Config()
        do {
            config = try Config.load(from: p.paths.configFile)
            let file = FileManager.default.fileExists(atPath: p.paths.configFile.path) ? p.paths.configFile.path : "none, defaults"
            if config.unknownKeys.isEmpty { add(.ok, "config.toml", file) }
            else { add(.warn, "config.toml", "unknown key: \(config.unknownKeys.sorted().joined(separator: ", "))") }
        } catch {
            add(.fail, "config.toml", "\(error)")
        }

        if let tmux = ExecutableLocator.find("tmux", configured: config.tmuxPath, home: p.paths.home, environment: p.environment) {
            let version = (try? Exec.run(tmux, ["-V"]))?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            add(.ok, "tmux", "\(tmux) · \(version)")
        } else {
            add(.fail, "tmux", config.tmuxPath.map { "not executable: \($0)" } ?? "not found (brew install tmux)")
        }

        var agents = 0
        for a in QueueItem.Agent.allCases {
            if let path = ExecutableLocator.find(a.rawValue, configured: config.agentPaths[a], home: p.paths.home, environment: p.environment) {
                agents += 1
                add(.ok, a.rawValue, path)
            } else {
                add(.warn, a.rawValue, config.agentPaths[a].map { "not executable: \($0)" } ?? "not found; lines for this agent will not start")
            }
        }
        if agents == 0 { add(.fail, "agent", "neither claude nor codex found") }

        let plist = plist(p.paths)
        let program = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            .flatMap { ($0["ProgramArguments"] as? [String])?.first }
        // Notifications need the bundle around the binary the LaunchAgent starts, not around this CLI.
        let agentBinary = program ?? p.executable
        let bundled = program.map { $0.hasSuffix("/ShelfBridge.app/Contents/MacOS/shelf-bridge") } ?? p.inAppBundle
        add(bundled ? .ok : .warn, "app", bundled ? agentBinary : "\(agentBinary) is not inside ShelfBridge.app: approval notifications will not work")

        if let program {
            if !FileManager.default.isExecutableFile(atPath: program) {
                add(.fail, "LaunchAgent", "\(plist.path) starts a missing binary: \(program)")
            } else if p.serviceLoaded() == false {
                add(.fail, "LaunchAgent", "not loaded: launchctl bootstrap gui/$(id -u) \(plist.path)")
            } else {
                add(.ok, "LaunchAgent", plist.path)
            }
        } else {
            add(.fail, "LaunchAgent", "\(plist.path) missing (brew reinstall --cask shelf-bridge or scripts/install-agent.sh)")
        }
        switch p.agentRunning() {
        case true?: add(.ok, "background agent", "running")
        case false?: add(.fail, "background agent", "not running (agent.log: \(p.paths.logsDir.path)/agent.log)")
        case nil: add(.fail, "background agent", "cannot open the lock file: \(p.paths.agentLock.path)")
        }

        if let key = KeyStore.load(p.paths) { add(.ok, "pairing", "keyId \(ProtocolV2.keyId(key))") }
        else { add(.warn, "pairing", "none: lines cannot be signed and the agent starts no line (shelf-bridge pair)") }

        let folders = ((try? FolderRegistry.load(p.paths)) ?? FolderRegistry()).folders
        if folders.isEmpty { add(.warn, "folders", "no enabled folders (shelf-bridge enable <folder>)") }
        for f in folders {
            var dir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: f.path, isDirectory: &dir) && dir.boolValue
            if !exists { add(.warn, "folder", "\(f.path) is missing: shelf-bridge disable \(f.path)") }
            else if !FileManager.default.isReadableFile(atPath: f.path) { add(.warn, "folder", "\(f.path) is not readable (Full Disk Access?)") }
            else { add(.ok, "folder", f.path) }
        }

        let perms = (try? FileManager.default.attributesOfItem(atPath: p.paths.stateDir.path))?[.posixPermissions] as? Int
        if let perms, perms & 0o077 != 0 { add(.warn, "state folder", "\(p.paths.stateDir.path) has mode \(String(perms, radix: 8)), should be 700") }
        return out
    }

    public static func render(_ checks: [Check]) -> String {
        let mark: [Level: String] = [.ok: "✓", .warn: "!", .fail: "✗"]
        let width = checks.map(\.name.count).max() ?? 0
        return checks.map { c in
            "\(mark[c.level]!) \(c.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.detail)"
        }.joined(separator: "\n")
    }

    /// Asks launchd about the user's service; `nil` if launchctl could not run.
    public static func launchdLoaded() -> Bool? {
        guard let out = try? Exec.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) else { return nil }
        return out.status == 0
    }
}
