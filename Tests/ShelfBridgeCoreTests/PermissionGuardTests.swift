import Foundation
import Testing
@testable import ShelfBridgeCore

/// Guards the invariant: permission bypass flags are never passed.
@Suite struct PermissionGuardTests {
    static let knownBypassFlags = [
        "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
        "--permission-mode", "bypassPermissions", "--yolo", "--full-auto",
        "--dangerously-bypass-approvals-and-sandbox", "danger-full-access",
        "--approve-for-me", "--add-dir", "sandbox_permissions",
    ]

    @Test(arguments: QueueItem.Agent.allCases, QueueItem.Mode.allCases)
    func everyTemplateIsClean(agent: QueueItem.Agent, mode: QueueItem.Mode) throws {
        let t = CLIAgentCommand(agent: agent, executable: "/usr/bin/\(agent.rawValue)").template(mode: mode)
        try PermissionGuard.check(t)
        for arg in t { for flag in Self.knownBypassFlags { #expect(!arg.lowercased().contains(flag.lowercased())) } }
    }

    /// Any change to an unattended template shows up here and gets reviewed.
    @Test func unattendedTemplatesAreExact() {
        #expect(CLIAgentCommand(agent: .claude, executable: "claude").template(mode: .unattended) == [
            "claude", "-p", "--restricted", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#, "--tools", "Read,Edit,Write,Glob,Grep",
            "--allowedTools", "Read,Edit,Write,Glob,Grep", "--output-format", "json",
        ])
        #expect(CLIAgentCommand(agent: .codex, executable: "codex").template(mode: .unattended) == [
            "codex", "exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
            "--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=false",
            "-c", "sandbox_workspace_write.exclude_slash_tmp=true", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
            "-c", #"web_search="disabled""#, "-c", "approval_policy=\"never\"",
            "--disable", "apps", "--disable", "plugins", "--disable", "remote_plugin", "--disable", "browser_use",
            "--disable", "browser_use_external", "--disable", "in_app_browser", "--disable", "computer_use",
            "--disable", "in_app_local_automation", "--disable", "hooks", "--disable", "skill_mcp_dependency_install",
            "--color", "never",
        ])
    }

    /// No code-running or network tool is ever pre-approved for Claude.
    @Test func claudeToolListHasNoShellOrNetwork() {
        let tools = Set(CLIAgentCommand.claudeTools.split(separator: ",").map(String.init))
        #expect(tools.isDisjoint(with: ["Bash", "PowerShell", "WebFetch", "WebSearch", "Task", "Agent", "NotebookEdit"]))
    }

    @Test func unattendedPromptSaysItCannotAsk() {
        let item = QueueItem(id: "q-20261021T1305-7f3b", title: "Report", checked: false, agent: .codex, mode: .unattended, line: 1)
        let p = Prompt.wrap(item, folder: "/tmp/x")
        #expect(p.hasPrefix(Prompt.preamble + "\n" + Prompt.unattendedNote))
        let attended = QueueItem(id: "q-20261021T1305-7f3c", title: "Report", checked: false, agent: .codex, mode: .attended, line: 1)
        #expect(!Prompt.wrap(attended, folder: "/tmp/x").contains(Prompt.unattendedNote))
    }

    @Test(arguments: knownBypassFlags)
    func guardRejects(flag: String) {
        #expect(throws: RunnerError.self) { try PermissionGuard.check(["/usr/bin/claude", flag]) }
        #expect(throws: RunnerError.self) { try PermissionGuard.check(["/usr/bin/claude", flag.uppercased()]) }
    }

    /// The task text may say anything; it is data, not a flag.
    @Test func promptIsNotScannedButCannotBeAFlag() throws {
        let item = QueueItem(id: "q-20261021T1305-7f3a", title: "--dangerously-skip-permissions yolo", checked: false,
                             agent: .claude, mode: .attended, line: 1)
        let prompt = Prompt.wrap(item, folder: "/tmp/x")
        let argv = try CLIAgentCommand(agent: .claude, executable: "/usr/bin/claude").argv(prompt: prompt, mode: .attended)
        #expect(argv == ["/usr/bin/claude", prompt])
        #expect(prompt.hasPrefix(Prompt.preamble))
        #expect(!prompt.hasPrefix("-"))
    }

    /// No source file builds a bypass flag some other way.
    @Test func sourcesNeverMentionBypassFlagsOutsideTheGuard() throws {
        let sources = Fixture.packageRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AgentCommand.swift" }
        #expect(!files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8).lowercased()
            for flag in Self.knownBypassFlags { #expect(!text.contains(flag.lowercased()), "\(f.lastPathComponent): \(flag)") }
        }
    }
}
