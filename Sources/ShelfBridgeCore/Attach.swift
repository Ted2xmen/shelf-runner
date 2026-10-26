import Foundation

/// What the last `attach` did for a job.
public struct Attachment: Equatable, Sendable {
    /// ISO time Terminal was asked to open the job's window.
    public var attached: String?
    /// `no-session`: the job has no live tmux session.
    public var error: String?
}

extension Agent {
    /// Writes a 0700 `.command` that attaches to the job's tmux session and window and
    /// opens it with Terminal. A missing session is `attachError: "no-session"`; the job state
    /// does not change.
    public func attach(id: String, now: Date = Date()) {
        let r = runner.store.latest(id: id)
        guard let r, JobState.active.contains(r.status), let session = r.tmuxSession,
              let tmux = try? runner.tmux(), (try? tmux.hasSession(session)) == true else {
            attachments[id] = Attachment(attached: nil, error: "no-session")
            log("attach \(id): no tmux session")
            return
        }
        let window = tmux.windowAlive(r.tmuxWindow ?? "", name: id) ? id : nil
        let file = paths.attachFile(id: id)
        do {
            try paths.ensureDirectories()
            try? FileManager.default.removeItem(at: file)
            guard FileManager.default.createFile(atPath: file.path, contents: Data(tmux.attachScript(session: session, window: window).utf8),
                                                 attributes: [.posixPermissions: 0o700]) else {
                throw RunnerError.io("could not write: \(file.path)")
            }
        } catch {
            log("attach \(id): \(error)")
            return
        }
        guard openTerminal(file) else { log("attach \(id): could not open Terminal"); return }
        attachments[id] = Attachment(attached: Clock.iso(now), error: nil)
        log("attach \(id): Terminal opened")
    }

    /// `open -a Terminal <file>`: Terminal runs a `.command` file.
    nonisolated static func openInTerminal(_ file: URL) -> Bool {
        (try? Exec.run("/usr/bin/open", ["-a", "Terminal", file.path]))?.status == 0
    }

    /// Scripts and results of jobs that are no longer active go away.
    func sweepAttachments(_ o: Observed) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: paths.attachDir, includingPropertiesForKeys: nil)) ?? [] {
            let id = url.deletingPathExtension().lastPathComponent
            if !(o.snapshot.records[id].map { JobState.active.contains($0.status) } ?? false) { try? fm.removeItem(at: url) }
        }
        attachments = attachments.filter { id, _ in o.snapshot.records[id].map { JobState.active.contains($0.status) } ?? false }
    }
}
