import Foundation
import Security

/// The pairing key: 32 random bytes, 0600, in the state dir. Re-pairing replaces it.
public enum KeyStore {
    public static func file(_ paths: Paths) -> URL { paths.stateDir.appendingPathComponent("pair.key") }

    public static func load(_ paths: Paths) -> Data? {
        guard let d = try? Data(contentsOf: file(paths)), d.count == 32 else { return nil }
        return d
    }

    /// Writes a new key and returns it; the old one stops verifying at once.
    public static func pair(_ paths: Paths) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RunnerError.io("could not generate a random key")
        }
        try paths.ensureDirectories()
        let tmp = file(paths).appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600])
        else { throw RunnerError.io("could not write the key") }
        if rename(tmp.path, file(paths).path) != 0 { throw RunnerError.io("could not write the key: \(String(cString: strerror(errno)))") }
        return Data(bytes)
    }
}

/// User decisions on new ids: from the CLI, a notification answer or a signed
/// command. A file so the notification-launched instance and the agent share it.
public struct Approvals: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable { case run, ignore }
    public struct Entry: Codable, Equatable, Sendable {
        public var decision: Decision
        public var at: String
        /// `cli`, `notification`, `shelf`
        public var via: String
    }
    public var entries: [String: Entry] = [:]

    public init() {}

    public static func file(_ paths: Paths) -> URL { paths.stateDir.appendingPathComponent("approvals.json") }

    public static func load(_ paths: Paths) -> Approvals {
        guard let d = try? Data(contentsOf: file(paths)) else { return Approvals() }
        return (try? JSONDecoder().decode(Approvals.self, from: d)) ?? Approvals()
    }

    /// Read-modify-write under `flock`.
    public static func record(_ paths: Paths, id: String, decision: Decision, via: String) throws {
        try paths.ensureDirectories()
        let lock = open(paths.stateDir.appendingPathComponent("approvals.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RunnerError.io("could not open approvals.lock") }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        var a = load(paths)
        a.entries[id] = Entry(decision: decision, at: Clock.iso(), via: via)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(a).write(to: file(paths), options: .atomic)
    }
}

/// `out:` and `ref:` resolve inside the enabled folder: relative, no `..`, no symlink escape.
/// The path need not exist yet; its nearest existing ancestor is resolved.
public enum PathGuard {
    public static func isInside(_ relative: String, folder: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return false }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".."), !parts.isEmpty else { return false }
        var url = URL(fileURLWithPath: folder, isDirectory: true)
        for p in parts { url.appendPathComponent(String(p)) }
        var probe = url.path
        while !FileManager.default.fileExists(atPath: probe), probe != folder, probe != "/" {
            probe = (probe as NSString).deletingLastPathComponent
        }
        guard let real = realpath(probe, nil) else { return false }
        defer { free(real) }
        let resolved = String(cString: real)
        return resolved == folder || resolved.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The file part of `ref:` (`TODO.md@a41c09e2`), still escaped.
    public static func refPath(_ ref: String) -> String { String(ref.split(separator: "@").first ?? "") }

    /// The only escapes a `ref:` path may carry: space, `@`, `%`.
    public static let refEscapes: [String: Character] = ["%20": " ", "%40": "@", "%25": "%"]

    /// Decodes `refEscapes` in one left-to-right pass (`%2520` is the text `%20`); any other `%`
    /// makes the path invalid (`nil`). Only the path check uses this; the status echoes `ref` as written.
    public static func decodeRefPath(_ path: String) -> String? {
        var out = ""
        var i = path.startIndex
        while i < path.endIndex {
            guard path[i] == "%" else { out.append(path[i]); i = path.index(after: i); continue }
            guard let end = path.index(i, offsetBy: 3, limitedBy: path.endIndex),
                  let c = refEscapes[String(path[i..<end])] else { return nil }
            out.append(c)
            i = end
        }
        return out
    }

    /// The path check for `ref:`: decode the three escapes, then the same inside-the-folder check as `out:`.
    public static func refIsInside(_ ref: String, folder: String) -> Bool {
        decodeRefPath(refPath(ref)).map { isInside($0, folder: folder) } ?? false
    }
}

/// The start gate in `Supervisor`, in this order: signature, paths, approval.
public struct AgentGate {
    public var key: Data?
    public var approvals: Approvals

    public init(key: Data?, approvals: Approvals) {
        self.key = key
        self.approvals = approvals
    }

    public func check(_ item: QueueItem, folder: String) -> Supervisor.GateResult {
        guard let key, ProtocolV2.verify(key: key, item: item, folder: folder) else { return .hold("waiting:signature") }
        if let out = item.out, !PathGuard.isInside(out, folder: folder) { return .hold("failed:path") }
        if let ref = item.ref, !PathGuard.refIsInside(ref, folder: folder) { return .hold("failed:path") }
        switch approvals.entries[item.id]?.decision {
        case .run?: return .pass
        case .ignore?: return .hold("cancelled")
        case nil: return .hold("needs-approval")
        }
    }
}

/// `q-<yyyyMMdd'T'HHmm>-<4 hex>` in local time.
public enum QueueID {
    public static func make(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd'T'HHmm"
        return "q-\(f.string(from: now))-\(String(format: "%04x", UInt16.random(in: 0...UInt16.max)))"
    }

    /// A ready-to-paste signed line for someone writing the queue by hand (Bridge works without Shelf).
    public static func signedLine(key: Data, folder: String, title: String, agent: QueueItem.Agent, mode: QueueItem.Mode,
                                  ref: String? = nil, out: String? = nil, now: Date = Date()) throws -> String {
        let clean = ProtocolV2.canonicalTitle(title)
        let probe = QueueGrammar.parseLine("- [ ] \(clean) id:q-00000000T0000-0000 agent:\(agent.rawValue)")
        guard case .success(let parsed)? = probe, parsed.title == clean else {
            throw RunnerError.usage("the title contains a reserved key (id:, agent:, mode:, ref:, out:, by:, sig:)")
        }
        let id = make(now: now)
        var keys = "id:\(id) agent:\(agent.rawValue) mode:\(mode.rawValue)"
        if let ref { keys += " ref:\(ref)" }
        if let out { keys += " out:\(out)" }
        let sig = ProtocolV2.lineSig(key: key, canonical: ProtocolV2.queueCanonical(id: id, folder: folder, title: clean,
                                                                                    agent: agent.rawValue, mode: mode.rawValue))
        let line = "- [ ] \(clean) \(keys) by:you sig:\(sig)"
        guard case .success(let item)? = QueueGrammar.parseLine(line), ProtocolV2.verify(key: key, item: item, folder: folder) else {
            throw RunnerError.usage("could not build the line (ref: must be file@<8 hex>)")
        }
        return line
    }
}
