---
title: shelf-bridge architecture
description: How shelf-bridge is built - targets, source files, CLI, the agent loop, files it reads and writes, packaging, scripts and tests - with a source line for each claim.
created_by: opencode
created: 2026-10-25T13:35:00+03:00
---
# shelf-bridge architecture

This page explains how Bridge is put together. Anything that crosses the process boundary
(line grammar, signatures, notifications, status JSON) is specified in
[protocol/v2.md](protocol/v2.md); this page links there instead of repeating it.

## Targets

`Package.swift` declares three targets, macOS 14 or later (`Package.swift:6-16`):

| Target | Kind | Role |
|---|---|---|
| `ShelfBridgeCore` | library | everything testable: parsing, signing, planning, tmux, status, bridge |
| `shelf-bridge` | executable | the CLI, the background agent and the notification app |
| `ShelfBridgeCoreTests` | tests | depends on the executable too, so integration tests can start the real `wrap` (`Package.swift:14-15`) |

The package has no external dependencies: `Package.swift` declares none (`Package.swift:4-17`).
The source files import only Apple system frameworks (for example `Sources/ShelfBridgeCore/Protocol.swift:1-2`,
`Sources/ShelfBridgeCore/StatusBuilder.swift:1-2`, `Sources/shelf-bridge/AppNotifier.swift:1-4`).

## Source files

`Sources/ShelfBridgeCore/`:

| File | Role |
|---|---|
| `QueueLine.swift` | `AGENT-QUEUE.md` grammar ([v2.md 3](protocol/v2.md#3-queue-lines-agent-queuemd)) |
| `Schedule.swift` | `SCHEDULED.md` grammar and occurrence math ([v2.md 4](protocol/v2.md#4-scheduled-lines-scheduledmd)) |
| `Protocol.swift` | protocol constants, canonical text, HMAC, command names and gate, pairing code |
| `Security.swift` | `pair.key`, approvals, path guard, the start gate, queue ids and the CLI's signed line |
| `Supervisor.swift` | pure planning: snapshot in, actions out; policy defaults; job state sets |
| `Agent.swift` | the background loop: observe, plan, execute; FSEvents watcher; agent lock |
| `Runner.swift` | `enable`, `disable`, `list`, `run`, and starting a job in tmux |
| `Wrap.swift` | `shelf-bridge wrap`: runs inside the tmux window, starts the agent, records the result |
| `Tmux.swift` | `Exec` (posix_spawn, no shell) and every tmux call |
| `AgentCommand.swift` | fixed agent argv templates, the permission guard, the prompt wrapper |
| `ShelfChannel.swift` | status broadcast, ping, signed commands, log replies |
| `StatusV2.swift` | the status JSON type and its size clamp |
| `StatusBuilder.swift` | builds the status from a snapshot; machine readings |
| `LogReply.swift`, `LogTail.swift`, `AnsiText.swift` | log reply, control-sequence stripping, colour runs |
| `Attach.swift` | the `attach` `.command` file |
| `Limits.swift` | Claude and Codex usage limits, `limits-tee`, `now` / `asking` summaries |
| `Notices.swift`, `NoticeText.swift` | which notifications to send, their text, what a click opens |
| `RunStore.swift` | `runs.jsonl`, append-only job records |
| `Folders.swift` | enabled folders, stored by realpath |
| `Config.swift`, `TOML.swift` | `config.toml` and a small TOML parser; executable lookup |
| `Paths.swift` | every path Bridge uses; ISO clock |
| `PrintResult.swift` | unattended Claude's JSON result and its `blocked` count |
| `Doctor.swift` | `shelf-bridge doctor` checks |
| `Errors.swift` | `RunnerError` messages |

`Sources/shelf-bridge/`:

| File | Role |
|---|---|
| `main.swift` | argument dispatch, `runAgent`, the notification responder |
| `AppNotifier.swift` | macOS notifications with Run / Ignore, click handling; works only inside `ShelfBridge.app` (`Sources/shelf-bridge/AppNotifier.swift:8-18`) |

## CLI

Usage text: `Sources/shelf-bridge/main.swift:8-28`.

| Command | What it does | Source |
|---|---|---|
| `enable <folder>` / `disable <folder>` | add or remove a folder (realpath) in `folders.json` | `main.swift:73-78`; `Runner.swift:23-38` |
| `list` | enabled folders, their queue and scheduled lines, invalid lines | `main.swift:79-92` |
| `run <id>` | start a line now; skips signature, approval and holds | `main.swift:93-97`; `Runner.swift:89-102` |
| `status` | agent running or not, each job's state | `main.swift:98-112` |
| `logs <id> [lines]` | plain tail of the job's log, default 40 lines | `main.swift:113-118` |
| `agent` | the background agent (launchd starts it); one per user | `main.swift:119-122`; `Agent.swift:289-306` |
| `pair` | new key, prints the `SB1-` code | `main.swift:123-130` |
| `approve <id>` / `ignore <id>` | record an approval decision (`via: cli`) | `main.swift:131-135` |
| `line <folder> <claude\|codex> <title...> [--mode m] [--ref f@h] [--out p]` | print a signed queue line | `main.swift:136-151` |
| `limits-tee [--show]` | save Claude Code's status line JSON, pass it on; runs before config load and never fails | `main.swift:54-60` |
| `doctor` | install checks; exit 1 on any failure | `main.swift:152-161`; `Doctor.swift:41-118` |
| `version`, `help` | | `main.swift:162-165` |
| `wrap ...` (internal) | started by tmux for each job, not in the usage text | `main.swift:62-64`; `Wrap.swift:22-37` |

(`main.swift` is `Sources/shelf-bridge/main.swift`; the others are under `Sources/ShelfBridgeCore/`.)

Launched with no arguments, inside the app bundle and without a terminal, the binary is the
notification responder: macOS started it to deliver a Run / Ignore answer. It records the answer and
exits, without taking the agent lock (`Sources/shelf-bridge/main.swift:48-49`, `:226-240`).

## The agent loop

`runAgent` builds an `Agent` and a `Bridge` and runs the main run loop; inside the app bundle it runs
an accessory `NSApplication` so notifications work (`Sources/shelf-bridge/main.swift:182-214`).
Everything runs on the main queue (`Sources/ShelfBridgeCore/Agent.swift:17-19`).

**Triggers.**

- FSEvents on every enabled folder and on the state dir; any event means "re-read", flags are not
  trusted (`Sources/ShelfBridgeCore/Agent.swift:280-287`, `:309-328`).
- Events are debounced: one tick 0.3 s after the first event (`Sources/ShelfBridgeCore/Agent.swift:266-273`).
- A fallback timer ticks every 5 s, for missed events and for the stall and timeout clocks
  (`Sources/ShelfBridgeCore/Agent.swift:255-264`).
- A tick is not re-entrant; a nested call is deferred (`Sources/ShelfBridgeCore/Agent.swift:115-120`).

**One tick** (`Sources/ShelfBridgeCore/Agent.swift:116-139`):

1. Reload `config.toml` if it changed (`Sources/ShelfBridgeCore/Agent.swift:209-214`).
2. **Observe**: read both Markdown files of every enabled folder, look at live tmux windows, read
   `runs.jsonl` and stop markers. Machine readings (sysctl, IOKit, `~/.codex/sessions`) are taken
   only when some line could start (`Sources/ShelfBridgeCore/Agent.swift:59-113`).
3. **Plan** with `Supervisor`, a pure function of the snapshot
   (`Sources/ShelfBridgeCore/Supervisor.swift:108-262`):
   - active jobs: lost window, stop grace, ticked or removed line, timeout, stall
     (`Sources/ShelfBridgeCore/Supervisor.swift:137-175`);
   - candidate lines: the start gate (signature, paths, approval) from `AgentGate`
     (`Sources/ShelfBridgeCore/Security.swift:111-131`), then pause, daily limit, machine and
     folder slots, then resources (`Sources/ShelfBridgeCore/Supervisor.swift:182-205`);
   - resource holds in order memory, disk (startup volume and the folder's volume), battery,
     thermal, agent limit; an unknown reading never holds
     (`Sources/ShelfBridgeCore/Supervisor.swift:264-283`);
   - scheduled lines: one run per occurrence, `missed` when seen too late
     (`Sources/ShelfBridgeCore/Supervisor.swift:220-259`).
4. **Execute** the actions: start, set status, interrupt, kill, notify
   (`Sources/ShelfBridgeCore/Agent.swift:141-175`).
5. Failure notices, saved screens, log pruning (14 days), attach cleanup, then `onTick` for the
   bridge (`Sources/ShelfBridgeCore/Agent.swift:129-138`, `:227-251`).

Defaults (`Sources/ShelfBridgeCore/Supervisor.swift:4-23`): 2 h max runtime, stall after 6 min,
60 s cancel grace, 2 jobs at once, 1 per folder, 20 starts a day, disk wait 10 GB and stop 5 GB,
battery 20 %, limit 90 %, limit wait 90 min, missed after 60 min. All are `config.toml` keys
(`Sources/ShelfBridgeCore/Config.swift:3-33`, `:46-51`, `:74-93`). Unknown keys are reported, not
fatal (`Sources/shelf-bridge/main.swift:68`).

## Starting a job: Runner, Tmux, Wrap

1. `Runner.start` builds the agent argv, opens a tmux window named after the job id in session
   `shelf-<folder>`, starts `shelf-bridge wrap --id ... --folder ... --agent ... --mode ... -- <argv>`
   in it, pipes the pane to `<id>.log`, appends a `running` record, and finally writes the start
   signal (`Sources/ShelfBridgeCore/Runner.swift:104-143`). If the log pipe or the record fails, it
   interrupts the window before the agent starts (`Sources/ShelfBridgeCore/Runner.swift:131-138`).
2. `wrap` waits up to 10 s for the start signal (`Sources/ShelfBridgeCore/Wrap.swift:17`, `:131-136`),
   then spawns the agent with `posix_spawn`, which keeps it in `wrap`'s process group (the tty's
   foreground group), so the agent can read the terminal and receives Ctrl-C, while `wrap` has a
   SIGINT handler and survives to record the result
   (`Sources/ShelfBridgeCore/Wrap.swift:66-68`, `:102-129`).
3. On exit `wrap` appends `done` or `failed:<code>`; a stop marker's reason wins when the stop caused
   the exit (`Sources/ShelfBridgeCore/Wrap.swift:46-64`, `Sources/ShelfBridgeCore/Supervisor.swift:46-53`).
   For unattended Claude, stdout goes to `<id>.result.json`, whose `result` text is appended to the
   log and whose denial count becomes `blocked` (`Sources/ShelfBridgeCore/Wrap.swift:44-45`, `:80-91`).

**No shell.** `Exec` uses `posix_spawn` with an argv array (`Sources/ShelfBridgeCore/Tmux.swift:3-40`).
tmux window commands always have two or more arguments, because a single one would go through
`sh -c` (`Sources/ShelfBridgeCore/Tmux.swift:42-43`, `:84`). The one `sh -c` is `pipe-pane`, with a
fixed `cat` and a single-quoted path Bridge built (`Sources/ShelfBridgeCore/Tmux.swift:99-106`).
The task text is one argument, after a fixed preamble so it can never be read as a flag
(`Sources/ShelfBridgeCore/AgentCommand.swift:3-4`, `:84-96`).

## Agent command templates

`Sources/ShelfBridgeCore/AgentCommand.swift:34-55`:

| Agent, mode | argv before the prompt |
|---|---|
| any, attended | `<agent>` alone: interactive in tmux, the agent's own settings and permission prompts |
| claude, unattended | `claude -p [--model m] --restricted --strict-mcp-config --settings {"disableAllHooks":true} --tools Read,Edit,Write,Glob,Grep --allowedTools Read,Edit,Write,Glob,Grep --output-format json` |
| codex, unattended | `codex exec [-m m] --ignore-user-config --ignore-rules --skip-git-repo-check --sandbox workspace-write -c sandbox_workspace_write.network_access=false -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true -c web_search="disabled" -c approval_policy="never"`, `--disable` for ten network or screen features, `--color never` |

- The unattended model comes from `[unattended]` in `config.toml` and must be one plain token
  (`Sources/ShelfBridgeCore/Config.swift:81-88`).
- `PermissionGuard` scans every template argument, case-insensitive, for bypass substrings
  (`dangerously`, `skip-permissions`, `yolo`, `full-auto`, `--permission-mode`, `--add-dir`, ...) and
  refuses to start on a hit (`Sources/ShelfBridgeCore/AgentCommand.swift:64-82`).
- Unattended prompts add a note that nobody will answer (`Sources/ShelfBridgeCore/AgentCommand.swift:87-92`).
- Agents and tmux are found from config, then `PATH`, then common install folders
  (`Sources/ShelfBridgeCore/Config.swift:99-117`).

## Bridge, status and notices

- `Bridge` observes ping and commands, publishes the status on a timer, on ping, on commands and on
  change, and answers `log` requests (`Sources/ShelfBridgeCore/ShelfChannel.swift:3-116`). Wire details:
  [v2.md 7-10](protocol/v2.md#7-status).
- `StatusBuilder` turns the agent's snapshot into `StatusV2` and clamps it
  (`Sources/ShelfBridgeCore/StatusBuilder.swift:68-153`).
- `NoticeWatch` sends a notification once when a job enters `failed:*` or starts asking; the first
  pass after a start only records (`Sources/ShelfBridgeCore/Notices.swift:32-74`). Approval
  notifications come from the `needs-approval` action (`Sources/ShelfBridgeCore/Agent.swift:154-159`).
- Outside the app bundle, notifications go to stderr instead (`Sources/ShelfBridgeCore/Agent.swift:10-15`,
  `Sources/shelf-bridge/main.swift:187-194`).

## Files

`SHELF_BRIDGE_HOME` replaces the home directory for every path below
(`Sources/ShelfBridgeCore/Paths.swift:10-14`). Bridge directories are created with mode 0700
(`Sources/ShelfBridgeCore/Paths.swift:38-43`).

**Written by Bridge**

| Path | Contents | Source |
|---|---|---|
| `~/Library/Application Support/shelf-bridge/` | state dir | `Paths.swift:16` |
| `.../folders.json` | enabled folders | `Paths.swift:21`; `Folders.swift:19-24` |
| `.../runs.jsonl` | append-only job records under `flock`; last record per id wins | `Paths.swift:22`; `RunStore.swift:3`, `:44-57` |
| `.../pair.key` | 32-byte key, 0600 | `Security.swift:6`, `:14-25` |
| `.../approvals.json`, `approvals.lock` | approval decisions, read-modify-write under `flock` | `Security.swift:42`, `:49-62` |
| `.../paused` | exists while paused | `Agent.swift:216-225` |
| `.../heartbeat.json` | copy of the last status | `ShelfChannel.swift:65` |
| `.../claude-limits.json` | Claude Code status line JSON from `limits-tee` | `Limits.swift:15`, `:77-80` |
| `.../agent.lock` | one agent per user | `Paths.swift:27`; `Agent.swift:289-306` |
| `.../start/<id>` | start signal for `wrap` | `Paths.swift:23`, `:34` |
| `.../stop/<id>.json` | stop marker (reason, times) | `Paths.swift:24`, `:35`; `Supervisor.swift:38-54` |
| `.../attach/<id>.command` | 0700 attach script | `Paths.swift:25-26`, `:36`; `Attach.swift:24-31` |
| `~/Library/Logs/shelf-bridge/<id>.log` | the job's pane output | `Paths.swift:17`, `:29` |
| `.../<id>.screen.txt` | last pane capture, written when it changes | `Paths.swift:31`; `Agent.swift:228-239` |
| `.../<id>.result.json` | unattended Claude's raw stdout | `Paths.swift:33` |
| `.../agent.log` | the agent's stderr and stdout (set by the LaunchAgent) | `launchd/dev.ted2xmen.shelf-bridge.plist.template:17-18` |

Job logs, screens and results older than 14 days are deleted, checked at most once an hour
(`Sources/ShelfBridgeCore/Agent.swift:241-251`). (Paths in the table are under
`Sources/ShelfBridgeCore/`.)

**Read only**

| Path | Why | Source |
|---|---|---|
| `<folder>/AGENT-QUEUE.md`, `<folder>/SCHEDULED.md` | the queue | `Agent.swift:65-68` |
| `~/.config/shelf-bridge/config.toml` | settings; missing = defaults | `Paths.swift:18-20`; `Config.swift:53-56` |
| `~/.codex/sessions/**/rollout-*.jsonl` | Codex usage limits | `Limits.swift:12`, `:36-48` |
| `~/Library/LaunchAgents/dev.ted2xmen.shelf-bridge.plist` | `doctor` checks it | `Doctor.swift:35-39`, `:76-95` |

Bridge never writes queue files or anything else inside your folders; `Paths` lists every
place it writes (`Sources/ShelfBridgeCore/Paths.swift:3-4`). The agent you approve does the work in
the folder.

## Environment variables

| Variable | Effect | Source |
|---|---|---|
| `SHELF_BRIDGE_HOME` | home directory for all paths; passed on to the tmux job | `Paths.swift:10-14`; `Runner.swift:117` |
| `SHELF_BRIDGE_TICK_SECONDS` | fallback tick interval (test hook, default 5) | `main.swift:197-198` |
| `SHELF_BRIDGE_FIXED_READINGS=1` | calm fixed machine readings (test hook) | `main.swift:199-200`; `StatusBuilder.swift:62-66` |
| `SHELF_BRIDGE_STATUS_SECONDS` | forced status interval (default 30) | `main.swift:204` |
| `REGEN_PROTOCOL_FIXTURES=1` | tests rewrite `fixtures/protocol/v2/` | `Tests/ShelfBridgeCoreTests/ProtocolFixtureTests.swift:371` |
| `SHOW_AGENT_ERR=1` | integration tests print the agent's stderr | `Tests/ShelfBridgeCoreTests/AgentIntegrationTests.swift:39-40` |
| `OUT`, `UNIVERSAL`, `VERSION`, `BUILD_NUMBER`, `SIGN_IDENTITY` | `scripts/build-app.sh` options | `scripts/build-app.sh:3-10` |
| `DEVELOPER_ID`, `NOTARY_PROFILE` | `scripts/release.sh` signing and notarization | `scripts/release.sh:5`, `:16-17` |

## No sandbox

Bridge is not sandboxed: `scripts/build-app.sh` signs the app ad hoc or with a Developer ID
and hardened runtime, with no entitlements file (`scripts/build-app.sh:29-31`). It needs to read
any folder you enable, run tmux and the agent CLIs, and post distributed notifications. Sandboxed
apps reach it only through the protocol; `e2e/sandbox-probe/` checks that path.

## Packaging and launchd

- **App bundle**: `ShelfBridge.app`, bundle id `dev.ted2xmen.shelf-bridge`, `LSUIElement`, macOS 14
  (`launchd/Info.plist:4-12`). The version comes from `CFBundleShortVersionString`; a bare build says
  `dev` (`Sources/shelf-bridge/main.swift:5-6`). Notifications need the binary to run from inside the
  bundle by its real path (`Sources/shelf-bridge/AppNotifier.swift:8-18`).
- **LaunchAgent** `dev.ted2xmen.shelf-bridge`: runs `ShelfBridge.app/Contents/MacOS/shelf-bridge agent`
  at load, restarts it after a crash (`KeepAlive` `SuccessfulExit` false), 30 s throttle, background
  process type, logs to `agent.log` (`launchd/dev.ted2xmen.shelf-bridge.plist.template:1-19`).
- **Homebrew cask template**: `packaging/homebrew/shelf-bridge.rb.template`, filled in by
  `scripts/release.sh`; depends on tmux, installs the app and a `shelf-bridge` binary symlink, writes
  and loads the LaunchAgent in `postflight`, `zap` removes the three Bridge folders
  (`packaging/homebrew/shelf-bridge.rb.template:1-72`).

## Scripts

| Script | What it does | Source |
|---|---|---|
| `scripts/build-app.sh` | release build, assembles `build/ShelfBridge.app`, icon, signs | `scripts/build-app.sh:1-32` |
| `scripts/install-agent.sh` | development install: writes and loads the LaunchAgent for `build/ShelfBridge.app`; `--uninstall` removes it | `scripts/install-agent.sh:1-27` |
| `scripts/release.sh <x.y.z>` | clean tree check, `swift test`, universal signed build, notarize, staple, zip, cask; pushes nothing | `scripts/release.sh:1-66` |
| `scripts/make-app-icon.swift` | renders `design/icon/bridge-app-icon-1024.svg` into `build/AppIcon.icns` | `scripts/make-app-icon.swift:1-5`; `scripts/build-app.sh:25-27` |

## End-to-end probe

`e2e/sandbox-probe/run.sh` builds Bridge, builds a tiny sandboxed app, pairs in a temp home with
a private tmux socket, starts the agent, and lets the app ping, read the status and send signed
`pause` and `resume` (`e2e/sandbox-probe/run.sh:1-30`, `e2e/sandbox-probe/Probe.swift:1-40`).

## Tests and fixtures

- `Tests/ShelfBridgeCoreTests/`: Swift Testing suites for grammar, schedule, security, supervisor,
  config, doctor, notices, bridge, log and attach, colours, permission guard, protocol fixtures, and
  integration tests that run the real binary in tmux (`Tests/ShelfBridgeCoreTests/Support.swift:13-25`).
- `Tests/Fixtures/fake-agent.sh` stands in for `claude` and `codex`; tests never run a real agent
  (`Tests/Fixtures/fake-agent.sh:2-3`).
- `Tests/Fixtures/queue/` and `Tests/Fixtures/screens/` hold sample queue files and recorded tmux
  screens.
- `fixtures/protocol/v2/` is generated by `ProtocolFixtureTests`; see
  [v2.md 15](protocol/v2.md#15-fixtures).

## Sources

- `Package.swift:4-17`
- `Sources/shelf-bridge/main.swift:5-6, 8-28, 48-49, 54-68, 73-165, 182-214, 226-240`
- `Sources/shelf-bridge/AppNotifier.swift:1-4, 8-18`
- `Sources/ShelfBridgeCore/Protocol.swift:1-2`
- `Sources/ShelfBridgeCore/Agent.swift:10-19, 59-139, 141-175, 209-306, 309-328`
- `Sources/ShelfBridgeCore/Supervisor.swift:4-23, 38-54, 108-283`
- `Sources/ShelfBridgeCore/Security.swift:6, 14-25, 42, 49-62, 111-131`
- `Sources/ShelfBridgeCore/Runner.swift:23-38, 89-143`
- `Sources/ShelfBridgeCore/Wrap.swift:17, 22-37, 44-68, 80-91, 102-136`
- `Sources/ShelfBridgeCore/Tmux.swift:3-43, 84, 99-106`
- `Sources/ShelfBridgeCore/AgentCommand.swift:3-4, 34-55, 64-96`
- `Sources/ShelfBridgeCore/ShelfChannel.swift:3-116`
- `Sources/ShelfBridgeCore/StatusBuilder.swift:1-2, 62-66, 68-153`
- `Sources/ShelfBridgeCore/Notices.swift:32-74`
- `Sources/ShelfBridgeCore/Paths.swift:3-43`
- `Sources/ShelfBridgeCore/Folders.swift:19-24`
- `Sources/ShelfBridgeCore/RunStore.swift:3, 44-57`
- `Sources/ShelfBridgeCore/Limits.swift:12, 15, 36-48, 77-80`
- `Sources/ShelfBridgeCore/Config.swift:3-33, 46-56, 74-93, 99-117`
- `Sources/ShelfBridgeCore/Doctor.swift:35-39, 41-118`
- `launchd/Info.plist:4-12`
- `launchd/dev.ted2xmen.shelf-bridge.plist.template:1-19`
- `packaging/homebrew/shelf-bridge.rb.template:1-72`
- `scripts/build-app.sh:1-32`
- `scripts/install-agent.sh:1-27`
- `scripts/release.sh:1-66`
- `scripts/make-app-icon.swift:1-5`
- `e2e/sandbox-probe/run.sh:1-30`
- `e2e/sandbox-probe/Probe.swift:1-40`
- `Tests/ShelfBridgeCoreTests/Support.swift:13-25`
- `Tests/ShelfBridgeCoreTests/ProtocolFixtureTests.swift:371`
- `Tests/ShelfBridgeCoreTests/AgentIntegrationTests.swift:39-40`
- `Tests/Fixtures/fake-agent.sh:2-3`
