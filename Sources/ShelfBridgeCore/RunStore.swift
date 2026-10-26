import Foundation

/// One line of `runs.jsonl`. The file is append-only; the last record for an id wins.
public struct RunRecord: Codable, Equatable, Sendable {
    public var id: String
    public var folder: String
    public var status: String
    public var agent: String
    public var mode: String
    /// Kept so the status JSON can name a job after its line is gone.
    public var title: String?
    public var ref: String?
    public var startedAt: String?
    public var endedAt: String?
    public var tmuxSession: String?
    public var tmuxWindow: String?
    public var logPath: String?
    public var out: String?
    public var exitCode: Int32?
    /// When the current `waiting:<reason>` began; `nil` otherwise.
    public var waitingSince: String?
    /// Scheduled jobs: the occurrence (ISO instant) this record is about; kept until the next is claimed.
    public var occurrence: String?
    /// Unattended Claude: `permission_denials` count from its JSON result; `nil` otherwise.
    public var blocked: Int?
    public var at: String

    public init(id: String, folder: String, status: String, agent: String, mode: String, title: String? = nil, ref: String? = nil, startedAt: String? = nil,
                endedAt: String? = nil, tmuxSession: String? = nil, tmuxWindow: String? = nil,
                logPath: String? = nil, out: String? = nil, exitCode: Int32? = nil, at: String = Clock.iso()) {
        self.id = id; self.folder = folder; self.status = status; self.agent = agent; self.mode = mode; self.title = title; self.ref = ref
        self.startedAt = startedAt; self.endedAt = endedAt; self.tmuxSession = tmuxSession
        self.tmuxWindow = tmuxWindow; self.logPath = logPath; self.out = out; self.exitCode = exitCode; self.at = at
    }

    public static func status(exitCode: Int32) -> String { exitCode == 0 ? "done" : "failed:\(exitCode)" }
}

public struct RunStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    /// Appends under an exclusive `flock`: `run` and `wrap` write from different processes.
    public func append(_ r: RunRecord) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(r)
        data.append(0x0A)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RunnerError.io("could not open runs.jsonl: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw RunnerError.io("could not write runs.jsonl") }
    }

    /// Latest record per id. Lines that do not decode (a torn write, a newer schema) are skipped.
    public func latest() -> [String: RunRecord] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var out: [String: RunRecord] = [:]
        let dec = JSONDecoder()
        for line in text.split(separator: "\n") {
            if let r = try? dec.decode(RunRecord.self, from: Data(line.utf8)) { out[r.id] = r }
        }
        return out
    }

    public func latest(id: String) -> RunRecord? { latest()[id] }
}
