import Foundation

enum Fixture {
    static let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let packageRoot = testsDir.deletingLastPathComponent()
    static let dir = testsDir.appendingPathComponent("Fixtures")
    static let fakeAgent = dir.appendingPathComponent("fake-agent.sh").path

    static func text(_ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// The `shelf-runner` binary SwiftPM built next to the test bundle.
    static var builtRunner: String? {
        var url = Bundle.main.bundleURL
        for b in Bundle.allBundles where b.bundlePath.hasSuffix(".xctest") { url = b.bundleURL }
        let candidate = url.deletingLastPathComponent().appendingPathComponent("shelf-runner").path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        let fallback = packageRoot.appendingPathComponent(".build/debug/shelf-runner").path
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    static var tmux: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A throwaway directory spelled as `realpath` spells it (`/private/var/...`), like the runner.
final class TempDir {
    let url: URL
    init(_ label: String = "t") throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-runner-tests-\(label)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: realpath(base.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? base.path)
    }
    var path: String { url.path }
    func sub(_ name: String) throws -> URL {
        let u = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
