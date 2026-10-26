import Foundation

/// The only places Bridge writes. Everything hangs off one home
/// directory so tests can point it at a temp folder.
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    /// `SHELF_BRIDGE_HOME` overrides the user's home; meant for tests and demos.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let h = environment["SHELF_BRIDGE_HOME"], !h.isEmpty { return Paths(home: URL(fileURLWithPath: h)) }
        return Paths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var stateDir: URL { home.appendingPathComponent("Library/Application Support/shelf-bridge", isDirectory: true) }
    public var logsDir: URL { home.appendingPathComponent("Library/Logs/shelf-bridge", isDirectory: true) }
    public var configDir: URL { home.appendingPathComponent(".config/shelf-bridge", isDirectory: true) }

    public var configFile: URL { configDir.appendingPathComponent("config.toml") }
    public var foldersFile: URL { stateDir.appendingPathComponent("folders.json") }
    public var runsFile: URL { stateDir.appendingPathComponent("runs.jsonl") }
    public var startSignalsDir: URL { stateDir.appendingPathComponent("start", isDirectory: true) }
    public var stopMarkersDir: URL { stateDir.appendingPathComponent("stop", isDirectory: true) }
    /// `<id>.command` files that `attach` opens in Terminal.
    public var attachDir: URL { stateDir.appendingPathComponent("attach", isDirectory: true) }
    public var agentLock: URL { stateDir.appendingPathComponent("agent.lock") }

    public func logFile(id: String) -> URL { logsDir.appendingPathComponent("\(id).log") }
    /// The job's last pane capture, kept for the log window after the window closes.
    public func screenFile(id: String) -> URL { logsDir.appendingPathComponent("\(id).screen.txt") }
    /// Unattended Claude's raw `--output-format json` stdout.
    public func resultFile(id: String) -> URL { logsDir.appendingPathComponent("\(id).result.json") }
    public func startSignal(id: String) -> URL { startSignalsDir.appendingPathComponent(id) }
    public func stopMarker(id: String) -> URL { stopMarkersDir.appendingPathComponent("\(id).json") }
    public func attachFile(id: String) -> URL { attachDir.appendingPathComponent("\(id).command") }

    public func ensureDirectories() throws {
        for d in [stateDir, logsDir, startSignalsDir, stopMarkersDir, attachDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}

public enum Clock {
    public static func iso(_ d: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
