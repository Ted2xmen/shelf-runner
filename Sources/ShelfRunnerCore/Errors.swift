import Foundation

public enum RunnerError: Error, Equatable, CustomStringConvertible {
    case notADirectory(String)
    case folderNotEnabled(String)
    case idNotFound(String)
    case invalidLine(id: String?, line: Int, reason: String)
    case alreadyChecked(String)
    case alreadyRunning(String, session: String?)
    case agentNotFound(String)
    case tmuxNotFound
    case tmuxFailed(args: [String], output: String)
    case forbiddenFlag(arg: String, rule: String)
    case io(String)
    case usage(String)

    public var description: String {
        switch self {
        case .notADirectory(let p): return "not a folder or missing: \(p)"
        case .folderNotEnabled(let p): return "folder is not enabled: \(p) (shelf-runner enable <path>)"
        case .idNotFound(let id): return "not in the \(QueueGrammar.fileName) of any enabled folder: \(id)"
        case .invalidLine(let id, let line, let r): return "line \(line)\(id.map { " (\($0))" } ?? "") is invalid: \(r)"
        case .alreadyChecked(let id): return "line is checked, not run: \(id)"
        case .alreadyRunning(let id, let s): return "already running: \(id)\(s.map { " (tmux session \($0))" } ?? "")"
        case .agentNotFound(let a): return "agent not found: \(a) (config.toml [agents] \(a) = \"/path\")"
        case .tmuxNotFound: return "tmux not found (brew install tmux, or config.toml [tmux] path)"
        case .tmuxFailed(let a, let o): return "tmux \(a.first ?? "") failed: \(o.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .forbiddenFlag(let a, let r): return "permission bypass flag refused: \(a) (rule: \(r))"
        case .io(let m): return m
        case .usage(let m): return m
        }
    }
}
