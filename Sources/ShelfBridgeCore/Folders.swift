import Foundation

/// Enabled folders: off by default, `enable <path>` turns one on.
/// Stored by Bridge in its own state dir, never in the folder.
public struct FolderRegistry: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var enabledAt: String
    }
    public var folders: [Entry] = []

    public init() {}

    public static func load(_ paths: Paths) throws -> FolderRegistry {
        guard let data = try? Data(contentsOf: paths.foldersFile) else { return FolderRegistry() }
        return try JSONDecoder().decode(FolderRegistry.self, from: data)
    }

    public func save(_ paths: Paths) throws {
        try paths.ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: paths.foldersFile, options: .atomic)
    }

    /// `realpath(3)` of an existing directory: the spelling Shelf signs with, so
    /// `/tmp` becomes `/private/tmp`.
    public static func canonical(_ path: String, cwd: String = FileManager.default.currentDirectoryPath) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let abs = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        guard let real = realpath(abs, nil) else { throw RunnerError.notADirectory(path) }
        defer { free(real) }
        let resolved = String(cString: real)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError.notADirectory(path)
        }
        return resolved
    }

    public func isEnabled(_ canonicalPath: String) -> Bool { folders.contains { $0.path == canonicalPath } }

    /// Returns false when it was already enabled.
    @discardableResult
    public mutating func enable(_ canonicalPath: String) -> Bool {
        guard !isEnabled(canonicalPath) else { return false }
        folders.append(.init(path: canonicalPath, enabledAt: Clock.iso()))
        folders.sort { $0.path < $1.path }
        return true
    }

    @discardableResult
    public mutating func disable(_ canonicalPath: String) -> Bool {
        let before = folders.count
        folders.removeAll { $0.path == canonicalPath }
        return folders.count != before
    }
}
