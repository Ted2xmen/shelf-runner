---
title: shelf-runner changelog
description: Release notes, newest first; scripts/release.sh uses this file as the GitHub release notes.
created_by: claude-code
created: 2026-10-22T23:30:00+03:00
updated_by: claude-code
updated: 2026-10-23T19:27:00+03:00
---
# Changelog

## 0.1.0 (unreleased)

First public release.

- Watches `AGENT-QUEUE.md` and `SCHEDULED.md` in folders you enable and starts each signed, approved
  line as a Claude Code or Codex job in your tmux (attended: interactive; unattended: print mode
  with read and edit tools only).
- Approval once per line (macOS notification or `shelf-runner approve`), HMAC-signed lines, paths
  kept inside the folder, no permission-bypass flags anywhere.
- Holds new jobs on memory pressure, low disk, battery, heat and agent usage limits; cancel,
  stall and timeout handling.
- Optional bridge to the Shelf app: status broadcast, signed commands, live job log, "Open in Terminal".
- `shelf-runner doctor` checks the install.
- Notifications when an attended job asks you something and when a job fails (once each); a click
  opens the job in Runner Desk, or Shelf.
