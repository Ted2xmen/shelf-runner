# shelf-runner

Hand a task to Claude Code or Codex by writing one line of Markdown.

```markdown
- [ ] Write release notes for 1.4 id:q-20261022T1630-7f3a agent:claude mode:attended by:you sig:3c1f9a0b
```

shelf-runner is a small macOS background agent. It watches `AGENT-QUEUE.md` (and `SCHEDULED.md`)
in folders you enable. When a signed line appears and you approve it, the runner starts the job in
your own tmux, with your own Claude Code or Codex login. You can attach to the tmux window at any
time to watch or answer the agent. Tick or delete the line and the runner stops the job.

It is the optional companion of **Shelf**, a sandboxed Mac App Store app that reads your Markdown
task files: Shelf appends signed queue lines, sends signed commands (stop, run, log, attach and a
few more) and pings for status; the runner does the rest. The runner also works on its own, with
any editor (see [Using it without Shelf](#using-it-without-shelf)).

> **Status: 0.1.0, not released yet.** There is no signed build or Homebrew cask yet; build it
> from source (below).

## How it works

```text
 AGENT-QUEUE.md ──FSEvents──▶ shelf-runner ──approve?──▶ macOS notification (Run / Ignore)
 SCHEDULED.md                     │
                                  ├─ checks signature, paths, limits (memory, disk, battery, heat, usage)
                                  ▼
            tmux session "shelf-<folder>", window "<job id>"  ──▶  claude / codex  (your login, your settings)
```

- **Attended** jobs (default) run the agent interactively in tmux; it can ask you things and you
  answer by attaching. You get a notification when it asks or fails.
- **Unattended** jobs run in print mode with a fixed, restricted tool list (`claude -p` with file
  tools only, `codex exec` in a sandboxed workspace-write shell with no network).

## Requirements

- macOS 14 (Sonoma) or later
- `tmux` (`brew install tmux`)
- The `claude` and/or `codex` CLI, installed and signed in
- Xcode 16 or the Swift 6 toolchain, to build

## Install from source

```sh
git clone https://github.com/ted2xmen/shelf-runner.git
cd shelf-runner
swift test                     # never runs a real agent: a fake one stands in
scripts/build-app.sh           # builds build/ShelfRunner.app
scripts/install-agent.sh       # installs a LaunchAgent for it (Login Items shows ShelfRunner)
build/ShelfRunner.app/Contents/MacOS/shelf-runner doctor
```

Put `build/ShelfRunner.app/Contents/MacOS/shelf-runner` on your PATH, or call it by full path.
Install from a logged-in desktop session: over ssh the LaunchAgent cannot load, and `doctor` says
so. Allow notifications for ShelfRunner when macOS asks: new lines ask for approval there.

A Homebrew cask (`ted2xmen/tap/shelf-runner`) comes with the first signed release.

## First run

```sh
shelf-runner pair                       # signing key; prints an SR1- code for Shelf (shown once)
shelf-runner enable ~/Projects/notes    # nothing runs in a folder until you enable it
shelf-runner line ~/Projects/notes claude "Write release notes for 1.4" >> ~/Projects/notes/AGENT-QUEUE.md
```

You get a notification: **Run** or **Ignore** (or `shelf-runner approve <id>`). Then:

```sh
shelf-runner status                     # every job and its state
shelf-runner logs q-20261022T1630-7f3a  # plain-text tail of the job's log
tmux attach -t shelf-notes              # watch or answer the agent
```

To stop a job, tick its line (`- [x]`) or delete it. The runner presses Esc and Ctrl-C in the
job's window and closes the window if the agent is still running 60 seconds later.

## Using it without Shelf

Shelf is optional. On its own the runner needs only the CLI and an editor:

```sh
shelf-runner enable ~/Projects/notes    # 1. turn the folder on
shelf-runner pair                       # 2. make the signing key (ignore the SR1- code)
shelf-runner line ~/Projects/notes codex "Summarize the meeting notes" --mode unattended --out summary.md
                                        # 3. prints a signed line: id, agent, mode, by:you, sig
```

4. Paste the printed line into `~/Projects/notes/AGENT-QUEUE.md` (end the file with a newline).
5. Approve it: **Run** in the notification, or `shelf-runner approve <id>`.

`line` takes `<folder> <claude|codex> <title...>` and the options `--mode attended|unattended`,
`--ref file@<8 hex>` and `--out <path>`. It refuses a title that contains a reserved key such as
`id:` or `agent:`, and warns when the folder is not enabled.

## The queue line

```markdown
- [ ] Write release notes for 1.4 id:q-20261022T1630-7f3a agent:claude mode:attended ref:TODO.md@a41c09e2 by:you sig:3c1f9a0b
```

| Key | Meaning |
|---|---|
| `id:` | `q-<yyyyMMddTHHmm>-<4 hex>`, unique per line |
| `agent:` | `claude` or `codex` |
| `mode:` | `attended` (default) or `unattended` (see above) |
| `ref:`, `out:` | optional source line and output path; both must stay inside the folder |
| `by:` | who wrote the line |
| `sig:` | first 8 hex of an HMAC-SHA256, made with your pairing key over the line's canonical text (id, folder, title, agent, mode; see [the protocol](docs/protocol/v1.md#5-canonical-text-and-signatures)); the runner never starts an unsigned or edited line |

The rest of the line is the task text. It goes to the agent as one argument, never through a shell.
Lines in `SCHEDULED.md` add `due:`, `at:` and `every:` (`day`, `week`, `month`, `year`). Nothing
signs scheduled lines today: the CLI cannot, and Shelf writes only queue lines (see
[Known gaps](docs/protocol/v1.md#16-known-gaps)).

## Safety model

- **Off by default.** Only folders you `enable` are watched.
- **Signed lines.** Every line carries an HMAC made with the key from `shelf-runner pair`. A line
  someone else wrote (or edited) waits as `waiting:signature`.
- **Approval once per line**, by notification or CLI. `shelf-runner run <id>` is your own explicit
  action and skips both the signature and the approval check.
- **No permission bypass.** No `--dangerously-skip-permissions`, `--yolo` or similar flag exists on
  any code path or in any setting; a test scans the command templates. Attended jobs use your own
  agent settings; unattended jobs run with a fixed, restricted tool list.
- **No shell.** Processes start with an argument array; the task text never reaches `sh -c`.
- **Paths stay inside the folder.** `ref:` and `out:` outside it fail as `failed:path`.
- **The runner never writes your files.** It reads queue files and writes only its own state
  (`~/Library/Application Support/shelf-runner`), logs (`~/Library/Logs/shelf-runner`) and the
  agent's tmux window. The agent you approved does the work.
- **No network.** The runner itself makes no network requests and has no dependencies beyond
  Foundation and system frameworks.
- **Limits.** At most 2 jobs at once, 1 per folder, 20 a day, 2 hours each (all configurable).
  New jobs wait while memory pressure is high, disk is low, the battery is low or in Low Power
  Mode, the Mac is hot, or an agent's 5-hour usage is at 90% or more.

## Configuration

`~/.config/shelf-runner/config.toml`; every key is optional.

```toml
[agents]
claude = "/Users/me/.local/bin/claude"
codex = "/opt/homebrew/bin/codex"

[tmux]
path = "/opt/homebrew/bin/tmux"
socket = ""                  # tmux -L <socket>; empty = your default server

[runner]
max_runtime_seconds = 7200
stall_seconds = 360
cancel_grace_seconds = 60
max_parallel = 2
per_folder = 1
daily_jobs = 20
missed_after_minutes = 60    # a scheduled run seen later than this is `missed`

[unattended]
claude_model = ""            # --model for print-mode jobs; empty = the agent's default
codex_model = ""             # -m

[resources]
disk_wait_gb = 10
disk_stop_gb = 5
battery_percent = 20
limit_percent = 90
limit_wait_minutes = 90
```

Agent usage limits: Claude Code reports them to its status line command on stdin. Set that command
to `shelf-runner limits-tee | <your current command>` (the JSON passes through unchanged), or to
`shelf-runner limits-tee --show` for a short line of its own. Codex limits come from its session files.

## Commands

```text
enable <folder>       disable <folder>      list                  status
run <id>              logs <id> [lines]     approve <id>          ignore <id>
pair                  doctor                version
line <folder> <claude|codex> <title...> [--mode m] [--ref f@h] [--out p]
limits-tee [--show]
```

## Uninstall

```sh
scripts/install-agent.sh --uninstall
rm -rf ~/Library/Application\ Support/shelf-runner ~/Library/Logs/shelf-runner ~/.config/shelf-runner
```

## Repository layout

| Path | What |
|---|---|
| `Sources/ShelfRunnerCore` | queue parsing, signing, supervisor, tmux, limits, bridge to Shelf |
| `Sources/shelf-runner` | the CLI and the notification app |
| `Tests/` | Swift Testing suite with a fake agent and recorded tmux screens |
| `fixtures/protocol/v1/` | generated protocol test files; consumers keep their own copies (no automatic sync). The contract itself is [docs/protocol/v1.md](docs/protocol/v1.md) |
| `docs/` | protocol, architecture and ecosystem docs |
| `scripts/` | build, LaunchAgent install, icon and release scripts |
| `packaging/homebrew/` | cask template filled in by `scripts/release.sh` |
| `e2e/` | end-to-end probe: a sandboxed app talks to the runner |

Releases: `scripts/release.sh <version>` builds a universal app, signs it with a Developer ID,
notarizes and staples it, and writes the cask for `ted2xmen/homebrew-tap`. See the script header.

## Documentation

- [docs/protocol/README.md](docs/protocol/README.md): what the protocol is, version policy, fixtures
- [docs/protocol/v1.md](docs/protocol/v1.md): the protocol v1 contract
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the runner is built
- [docs/ECOSYSTEM.md](docs/ECOSYSTEM.md): Shelf, shelf-runner and Runner Desk
- [CONTRIBUTING.md](CONTRIBUTING.md): build, test and the rules for changes

## License

MIT. See [LICENSE](LICENSE).
