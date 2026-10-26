---
title: shelf-bridge changelog
description: Release notes, newest first; scripts/release.sh uses this file as the GitHub release notes.
created_by: claude-code
created: 2026-10-22T23:30:00+03:00
updated_by: opencode
updated: 2026-10-25T13:35:00+03:00
---
# Changelog

## 0.2.0 (unreleased)

The project is renamed to Shelf Bridge, and the protocol moves to v2.

- Rename: the command is `shelf-bridge`, the app `ShelfBridge.app`, the bundle id and LaunchAgent
  label `dev.ted2xmen.shelf-bridge`, the Swift module `ShelfBridgeCore`. State, logs and config
  live in `shelf-bridge` folders; the environment variables are `SHELF_BRIDGE_*`. The companion
  terminal app is now Shelf Bench (`shelfbench://`).
- Protocol v2 ([docs/protocol/v2.md](docs/protocol/v2.md), `fixtures/protocol/v2/`): notification
  names are `dev.ted2xmen.shelf-bridge.*`, the status `v` is 2 and its `runner` field is now `bridge`, pairing codes start with `SB1-`.
  There is no compatibility with v1: Shelf and Shelf Bench must be updated together. The v1
  document and fixtures stay as history.
- 0.2.0 uses new paths and names, so remove the old LaunchAgent, install again and pair again
  with the new `SB1-` code.

## 0.1.0 (unreleased)

First public release.

- Watches `AGENT-QUEUE.md` and `SCHEDULED.md` in folders you enable and starts each signed, approved
  line as a Claude Code or Codex job in your tmux (attended: interactive; unattended: print mode,
  where Claude gets only Read, Edit, Write, Glob and Grep, and Codex runs `exec` with
  `--sandbox workspace-write` and no network).
- Approval once per line (macOS notification or `shelf-runner approve`), HMAC-signed lines, paths
  kept inside the folder, no permission-bypass flags anywhere.
- Holds new jobs on memory pressure, low disk, battery, heat and agent usage limits; cancel,
  stall and timeout handling.
- Optional bridge to the Shelf app: status broadcast, signed commands, live job log, "Open in Terminal".
- `shelf-runner doctor` checks the install.
- Notifications when an attended job asks you something and when a job fails (once each); a click
  opens the job in Runner Desk, or Shelf.
