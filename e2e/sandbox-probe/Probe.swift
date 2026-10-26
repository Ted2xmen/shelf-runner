// End-to-end probe: a sandboxed app (like Shelf) pings Bridge, reads the status, sends signed commands.
// argv[1] = pairing key as hex (test only). Writes what it saw to its container: probe.json.
import AppKit
import CryptoKit

let keyHex = CommandLine.arguments.dropFirst().first ?? ""
let key = Data(stride(from: 0, to: keyHex.count, by: 2).compactMap { i -> UInt8? in
    let s = keyHex.index(keyHex.startIndex, offsetBy: i); return UInt8(keyHex[s..<keyHex.index(s, offsetBy: 2)], radix: 16)
})
let out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("probe.json")
let dnc = DistributedNotificationCenter.default()
let object = "dev.ted2xmen.shelf"
var seen: [[String: Any]] = []
var step = 0

func send(_ verb: String) {
    let ts = Int(Date().timeIntervalSince1970)
    let mac = HMAC<SHA256>.authenticationCode(for: Data("cmd|\(verb)|-|\(ts)".utf8), using: SymmetricKey(data: key))
    let sig = mac.map { String(format: "%02x", $0) }.joined().prefix(16)
    dnc.postNotificationName(.init("dev.ted2xmen.shelf-bridge.cmd.\(verb).-.\(ts).\(sig)"), object: object, userInfo: nil, deliverImmediately: true)
}
func finish() {
    let doc: [String: Any] = ["sandboxed": NSHomeDirectory().contains("/Library/Containers/"), "statuses": seen]
    try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: out)
    exit(0)
}

dnc.addObserver(forName: .init("dev.ted2xmen.shelf-bridge.status"), object: nil, queue: .main) { n in
    guard let json = n.userInfo?["json"] as? String,
          let s = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
    seen.append(["v": n.userInfo?["v"] ?? NSNull(), "paused": s["paused"] ?? NSNull(), "keyId": s["keyId"] ?? NSNull(),
                 "jobs": (s["jobs"] as? [Any])?.count ?? -1, "bytes": json.utf8.count])
    switch step {
    case 0: step = 1; send("pause")
    case 1 where s["paused"] as? Bool == true: step = 2; send("resume")
    case 2 where s["paused"] as? Bool == false: finish()
    default: break
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    dnc.postNotificationName(.init("dev.ted2xmen.shelf.ping"), object: object, userInfo: nil, deliverImmediately: true)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish() }
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
