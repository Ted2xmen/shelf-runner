import Foundation

/// `~/.config/shelf-bridge/config.toml`. A missing file means defaults.
///
/// ```toml
/// [agents]
/// claude = "/Users/me/.local/bin/claude"
/// codex = "/opt/homebrew/bin/codex"
///
/// [tmux]
/// path = "/opt/homebrew/bin/tmux"
/// socket = ""          # tmux -L <socket>; empty = the user's default server
///
/// [bridge]               # defaults shown
/// max_runtime_seconds = 7200
/// stall_seconds = 360
/// cancel_grace_seconds = 60
/// max_parallel = 2
/// per_folder = 1
/// daily_jobs = 20
/// missed_after_minutes = 60   # a scheduled occurrence seen later than this is `missed`
///
/// [unattended]           # print-mode jobs do not load the user's agent config, so the model is set here
/// claude_model = ""      # passed as --model; empty = the agent's default
/// codex_model = ""       # passed as -m
///
/// [resources]            # defaults shown
/// disk_wait_gb = 10      # below: start only when nothing else runs
/// disk_stop_gb = 5       # below: no new starts
/// battery_percent = 20   # on battery below this (or Low Power Mode): wait
/// limit_percent = 90     # agent's 5-hour use at or above: wait
/// limit_wait_minutes = 90
/// ```
public struct Config: Equatable, Sendable {
    public var agentPaths: [QueueItem.Agent: String] = [:]
    public var tmuxPath: String?
    public var tmuxSocket: String?
    public var policy = Policy()
    /// Unattended jobs only; `nil` = the agent's default.
    public var unattendedModels: [QueueItem.Agent: String] = [:]
    /// Keys the file had that this version does not know; reported, not fatal.
    public var unknownKeys: [String] = []

    public init() {}

    static let knownKeys: Set<String> = ["agents.claude", "agents.codex", "tmux.path", "tmux.socket",
                                         "bridge.max_runtime_seconds", "bridge.stall_seconds", "bridge.cancel_grace_seconds",
                                         "bridge.max_parallel", "bridge.per_folder", "bridge.daily_jobs", "bridge.missed_after_minutes",
                                         "unattended.claude_model", "unattended.codex_model",
                                         "resources.disk_wait_gb", "resources.disk_stop_gb", "resources.battery_percent",
                                         "resources.limit_percent", "resources.limit_wait_minutes"]

    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> Config {
        let t = try TOML.parse(text)
        var c = Config()
        func str(_ k: String) throws -> String? {
            guard let v = t[k] else { return nil }
            guard let s = v.string else { throw TOMLError(line: 0, message: "'\(k)' must be a string") }
            return s.isEmpty ? nil : s
        }
        for a in QueueItem.Agent.allCases { c.agentPaths[a] = try str("agents.\(a.rawValue)") }
        c.tmuxPath = try str("tmux.path")
        c.tmuxSocket = try str("tmux.socket")
        func int(_ k: String, min: Int) throws -> Int? {
            guard let v = t[k] else { return nil }
            guard let i = v.int, i >= min else { throw TOMLError(line: 0, message: "'\(k)' must be an integer of at least \(min)") }
            return i
        }
        if let v = try int("bridge.max_runtime_seconds", min: 1) { c.policy.maxRuntime = TimeInterval(v) }
        if let v = try int("bridge.stall_seconds", min: 1) { c.policy.stallAfter = TimeInterval(v) }
        if let v = try int("bridge.cancel_grace_seconds", min: 0) { c.policy.cancelGrace = TimeInterval(v) }
        if let v = try int("bridge.max_parallel", min: 1) { c.policy.maxParallel = v }
        if let v = try int("bridge.per_folder", min: 1) { c.policy.perFolder = v }
        if let v = try int("bridge.daily_jobs", min: 0) { c.policy.dailyJobs = v }
        if let v = try int("bridge.missed_after_minutes", min: 1) { c.policy.missedAfter = TimeInterval(v * 60) }
        for a in QueueItem.Agent.allCases {
            guard let m = try str("unattended.\(a.rawValue)_model") else { continue }
            // One plain token: never a flag, never a second argument.
            guard m.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\/-]*/) != nil else {
                throw TOMLError(line: 0, message: "'unattended.\(a.rawValue)_model' must be a model name")
            }
            c.unattendedModels[a] = m
        }
        if let v = try int("resources.disk_wait_gb", min: 0) { c.policy.diskWaitGB = v }
        if let v = try int("resources.disk_stop_gb", min: 0) { c.policy.diskStopGB = v }
        if let v = try int("resources.battery_percent", min: 0) { c.policy.batteryMinPercent = v }
        if let v = try int("resources.limit_percent", min: 1) { c.policy.limitPercent = v }
        if let v = try int("resources.limit_wait_minutes", min: 0) { c.policy.limitMaxWait = TimeInterval(v * 60) }
        c.unknownKeys = t.keys.filter { !knownKeys.contains($0) }.sorted()
        return c
    }
}

/// Finds executables without a shell. launchd gives a bare PATH, so common install
/// locations are searched after PATH.
public enum ExecutableLocator {
    public static func find(_ name: String, configured: String?, home: URL,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let c = configured {
            let p = (c as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                 home.appendingPathComponent(".local/bin").path]
        for d in dirs where !d.isEmpty {
            let p = (d as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
