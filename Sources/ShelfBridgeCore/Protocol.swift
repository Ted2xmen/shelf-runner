import CryptoKit
import Foundation

/// Shelf and Bridge protocol v2. Both repos test against `fixtures/protocol/v2/`.
public enum ProtocolV2 {
    public static let version = 2
    public static let statusName = "dev.ted2xmen.shelf-bridge.status"
    public static let pingName = "dev.ted2xmen.shelf.ping"
    /// The answer to `cmd.log.<id>`.
    public static let logName = "dev.ted2xmen.shelf-bridge.log"
    public static let commandPrefix = "dev.ted2xmen.shelf-bridge.cmd."
    /// Shelf posts commands and `ping` with this `object`; Bridge observes `name: nil` filtered
    /// on it. macOS does not deliver to a fully unfiltered observer. Anyone can post
    /// with it: security is the `sig`.
    public static let shelfObject = "dev.ted2xmen.shelf"

    // MARK: keys

    /// First 8 hex of SHA-256 over the raw key bytes.
    public static func keyId(_ key: Data) -> String { hex(Data(SHA256.hash(data: key))).prefix(8).description }

    static func hmac(_ key: Data, _ message: String) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))))
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // MARK: line signatures

    /// Whitespace runs collapse to one space, then NFC.
    public static func canonicalTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
    }

    public static func queueCanonical(id: String, folder: String, title: String, agent: String, mode: String) -> String {
        ["q1", id, folder, canonicalTitle(title), agent, mode].joined(separator: "\n")
    }

    /// Missing `at:` / `every:` are empty strings.
    public static func scheduledCanonical(id: String, folder: String, title: String, agent: String, mode: String,
                                          due: String, at: String?, every: String?) -> String {
        ["s1", id, folder, canonicalTitle(title), agent, mode, due, at ?? "", every ?? ""].joined(separator: "\n")
    }

    public static func lineSig(key: Data, canonical: String) -> String { String(hmac(key, canonical).prefix(8)) }

    public static func lineSig(key: Data, item: QueueItem, folder: String) -> String {
        if let s = item.schedule {
            return lineSig(key: key, canonical: scheduledCanonical(id: item.id, folder: folder, title: item.title, agent: item.agent.rawValue,
                                                                   mode: item.mode.rawValue, due: s.due, at: s.at, every: s.every?.rawValue))
        }
        return lineSig(key: key, canonical: queueCanonical(id: item.id, folder: folder, title: item.title,
                                                           agent: item.agent.rawValue, mode: item.mode.rawValue))
    }

    /// Constant-time comparison of the line's `sig:` with the expected one.
    public static func verify(key: Data, item: QueueItem, folder: String) -> Bool {
        guard let sig = item.sig else { return false }
        return constantTimeEqual(sig, lineSig(key: key, item: item, folder: folder))
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: commands

    /// `log` and `attach` read or show a job; they change no state.
    public enum Verb: String, CaseIterable, Sendable { case run, ignore, stop, requeue, runnow, pause, resume, log, attach }

    public struct Command: Equatable, Sendable {
        public var verb: Verb
        /// `nil` for `pause` / `resume` (`-` on the wire).
        public var id: String?
        public var ts: Int
        public var sig: String
    }

    public static func commandSig(key: Data, verb: Verb, id: String?, ts: Int) -> String {
        String(hmac(key, "cmd|\(verb.rawValue)|\(id ?? "-")|\(ts)").prefix(16))
    }

    public static func commandName(key: Data, verb: Verb, id: String?, ts: Int) -> String {
        commandPrefix + [verb.rawValue, id ?? "-", String(ts), commandSig(key: key, verb: verb, id: id, ts: ts)].joined(separator: ".")
    }

    /// Shape only; `CommandGate` checks signature, age and replay.
    public static func parseCommand(_ name: String) -> Command? {
        guard name.hasPrefix(commandPrefix) else { return nil }
        let parts = name.dropFirst(commandPrefix.count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let verb = Verb(rawValue: parts[0]), let ts = Int(parts[2]),
              parts[3].count == 16, parts[3].allSatisfy(\.isHexDigit) else { return nil }
        let global = verb == .pause || verb == .resume
        if global { guard parts[1] == "-" else { return nil } } else { guard JobID.isValid(parts[1]) else { return nil } }
        return Command(verb: verb, id: global ? nil : parts[1], ts: ts, sig: parts[3].lowercased())
    }
}

public enum ScheduledID {
    public static func isValid(_ s: String) -> Bool { s.wholeMatch(of: /^s-[0-9]{8}T[0-9]{4}-[0-9a-f]{4}$/) != nil }
}

/// A job id: a queue line (`q-`) or a scheduled line (`s-`, one job id for every occurrence).
public enum JobID {
    public static func isValid(_ s: String) -> Bool { QueueGrammar.isValidID(s) || ScheduledID.isValid(s) }
}

/// Accepts a command once: valid signature, at most 60 s old, not seen before.
public struct CommandGate {
    public let key: Data
    public var maxAge: Int = 60
    private var seen: [String: Int] = [:]

    public init(key: Data) { self.key = key }

    public enum Rejection: Error, Equatable { case malformed, badSignature, stale, replay }

    public mutating func accept(_ name: String, now: Int) -> Result<ProtocolV2.Command, Rejection> {
        guard let c = ProtocolV2.parseCommand(name) else { return .failure(.malformed) }
        guard ProtocolV2.constantTimeEqual(c.sig, ProtocolV2.commandSig(key: key, verb: c.verb, id: c.id, ts: c.ts))
        else { return .failure(.badSignature) }
        guard abs(now - c.ts) <= maxAge else { return .failure(.stale) }
        seen = seen.filter { now - $0.value <= maxAge * 2 }
        let token = "\(c.ts).\(c.sig)"
        guard seen[token] == nil else { return .failure(.replay) }
        seen[token] = c.ts
        return .success(c)
    }
}

/// `SB1-` + RFC 4648 base32, upper case, no padding. Decoding ignores case, spaces and dashes.
public enum PairCode {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    public static let prefix = "SB1-"

    public static func encode(_ key: Data) -> String {
        var out = "", buffer = 0, bits = 0
        for byte in key {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return prefix + out
    }

    public static func decode(_ code: String) -> Data? {
        var s = code.uppercased().filter { $0 != " " && $0 != "-" }
        let bare = prefix.replacingOccurrences(of: "-", with: "")
        guard s.hasPrefix(bare) else { return nil }
        s.removeFirst(bare.count)
        var out = Data(), buffer = 0, bits = 0
        for c in s {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | v; bits += 5
            if bits >= 8 { out.append(UInt8((buffer >> (bits - 8)) & 0xff)); bits -= 8 }
            buffer &= (1 << bits) - 1
        }
        return out.count == 32 ? out : nil
    }
}
