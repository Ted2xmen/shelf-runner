---
title: shelf-bridge ecosystem
description: The three apps around shelf-bridge (Shelf, shelf-bridge, Shelf Bench), who does what, and the contract between them.
created_by: opencode
created: 2026-10-25T13:35:00+03:00
---
# Ecosystem

Three apps meet around shelf-bridge. They share no code at runtime; they meet only through the
protocol.

**Shelf** is a sandboxed Mac App Store app that reads your Markdown task files. It is closed source.
For Bridge it is the other end of the contract: it appends signed queue lines to
`AGENT-QUEUE.md`, sends signed commands (run, ignore, stop, requeue, runnow, pause, resume, log,
attach), pings, and reads Bridge's status and log replies
([protocol/v2.md 2](protocol/v2.md#2-channels)).

**shelf-bridge** (this repo) is the macOS background agent. It watches the queue files of folders you
enable, verifies signatures, asks for approval, runs each job in your tmux with your own Claude Code
or Codex, and broadcasts its status ([ARCHITECTURE.md](ARCHITECTURE.md)). It works without Shelf:
`shelf-bridge line` prints a signed queue line that you add with any editor
(`Sources/shelf-bridge/main.swift:136-151`, `Sources/ShelfBridgeCore/Security.swift:143-144`).

**[Shelf Bench](https://github.com/Ted2xmen/shelf-bench)** is an open-source macOS terminal app for
agent jobs. It opens without Bridge. With Bridge, it reads the status and shows each job's
tmux window in an embedded terminal through its own grouped `view-<id>` session, where you can
answer the agent yourself. Toward Bridge it is read-only: it sends no signed commands today and
changes no Bridge state. A click on
a Bridge notification opens the job in Shelf Bench when it is installed
(`Sources/ShelfBridgeCore/Notices.swift:76-94`).

## Who does what

| Task | Shelf | shelf-bridge | Shelf Bench |
|---|---|---|---|
| Write and sign queue lines | yes | no (CLI `line` prints one for you to paste) | no |
| Sign scheduled lines | no ([gap](protocol/v2.md#16-known-gaps)) | no | no |
| Hold the pairing key | yes, in its own secure storage | yes, `pair.key` in the state dir | no |
| Approve a line | signed `run` / `ignore` command | notification or CLI `approve` / `ignore` | no |
| Run jobs in tmux | no | yes | no |
| Broadcast status | no | yes | no |
| Read status | yes | | yes |
| Ping | yes | answers | yes |
| Send signed commands | yes | verifies and executes | no |
| Show a live job | log reply, `attach` | answers `log`, opens Terminal on `attach` | its own tmux view |
| Write your queue files | yes (appends lines) | never | no |

## The contract

The contract is [docs/protocol/v2.md](protocol/v2.md), protocol version 2
(`Sources/ShelfBridgeCore/Protocol.swift:6`). Version rules and fixtures:
[docs/protocol/README.md](protocol/README.md).

## Sources

- `Sources/ShelfBridgeCore/Protocol.swift:6`
- `Sources/ShelfBridgeCore/Security.swift:143-144`
- `Sources/ShelfBridgeCore/Notices.swift:76-94`
- `Sources/shelf-bridge/main.swift:136-151`
- Shelf Bench facts: its README at https://github.com/Ted2xmen/shelf-bench (outside this repo)
