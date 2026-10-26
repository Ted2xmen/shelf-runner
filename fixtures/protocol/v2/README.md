---
title: Protocol v2 fixtures
description: Test files shared by shelf-bridge and Shelf, how they are made, and the rules of protocol v2 they pin down.
created_by: claude-code
created: 2026-10-22T19:00:00+03:00
updated_by: claude-code
updated: 2026-10-22T22:40:00+03:00
---
# Protocol v2 fixtures

shelf-bridge generates these files; Shelf copies them byte for byte. Do not edit them by hand:
`REGEN_PROTOCOL_FIXTURES=1 swift test --filter ProtocolFixture` rewrites them, and a normal test
run checks that they match the code byte for byte.

| File | Contents |
|---|---|
| `key.json` | Test key (0x00..0x1f), `keyId`, `SB1-` pairing code |
| `queue-lines.md` | Queue and scheduled lines, canonical text, expected `sig`, valid or not; an escaped `ref` and its real `h8` (`refs`) |
| `commands.json` | Command names and their 16-hex signatures, a fixed `ts`; the `object` they are posted with |
| `status-busy.json` | Paired, `slots` full (2/2), every job state and most waiting reasons once, an `asking` job, an unattended Claude job that ended with `blocked: 2`, two limits, one scheduled line |
| `status-idle.json` | Paired, nothing running, no limits (stale or unreadable), charging |
| `status-offline-stale.json` | Same as `status-busy`, `seen` 7 hours old: Shelf draws "Runner offline" and "unknown" |
| `status-unpaired.json` | `keyId: null`, an unsigned line in `waiting:signature`, unknown disk and battery as `null` |
| `log-reply.json` | The `dev.ted2xmen.shelf-bridge.log` answer for a live window: `userInfo` (with `json` as one string) and its decoded form; `lines` and coloured `styles` from `capture-pane -e` text (rule 17) |
| `log-reply-plain.json` | The same lines without `styles` (a finished job, an older Bridge): colour, `ESC ( B`, column moves and a `\r` progress line cleaned from the raw log |

## Rules

1. **Canonical title:** split the line on whitespace, drop the `key:value` words of the closed key list, join the rest with one space, then convert to NFC. An `x:y` word whose key is not in the closed list stays in the title.
2. **Without `mode:`** the canonical text has `attended` (the default). The tick (`[x]`) is not signed.
3. **The folder's real path:** `realpath(3)` (what Shelf uses for roots and ids; the `/private/var/...` form).
4. **On a scheduled line** a missing `at:` or `every:` is an empty string in the canonical text; it always has 9 lines.
5. **Pairing code:** `SB1-` + RFC 4648 base32 (A-Z, 2-7), upper case, no padding; 32 bytes = 52 characters. The reader ignores case, spaces and dashes.
6. **`keyId`** comes from SHA-256 of the raw 32 bytes. Signatures and digests are lower-case hex.
7. **`mac.battery`:** `charging` while on AC (desktops included); `null` when the battery cannot be read.
8. **`waiting:` reasons**, a closed list: `memory`, `disk`, `battery`, `thermal`, `limit`, `slot`, `folder`, `paused`, `daily` (the daily job limit is reached; the state is exactly `waiting:daily`) + `signature` (no signature, or it does not match; Bridge neither runs the line nor asks for approval). `waitMaxMin` is 90 for `limit` only, `null` for the others. `failed:timeout` is a job over the maximum run time, `failed:lost` a job Bridge lost track of.
9. **`object`:** Shelf posts commands and `ping` with `object: "dev.ted2xmen.shelf"`; Bridge listens with `name: nil` and this `object` (macOS does not deliver to a fully unfiltered observer).
10. **`ref`** is read from the line and sent back unchanged; Bridge never computes it. The path has only three escapes: space `%20`, `@` `%40`, `%` `%25`. The runner decodes them in one pass, only for its inside-the-folder path check (`%2520` is the text `%20`); any other `%` makes the line `failed:path`, and `..` and symlink escapes are still refused. Example: `ref:My%20Notes/TODO.md@…` in `queue-lines.md`, with its `itemID` and `h8` in the `refs` block.
11. **`now`:** the log's last meaningful line (one with a letter or digit), frame and prompt characters (`│ ╭ ❯ › > $ ⏺ ✻ …`) trimmed from both ends, at most 120 characters. **`asking`:** attended, running or stalled, no output for 60 s, and the last line ends with `?` or is an approval prompt (`(y/n)`, `Do you want`, `Allow`, `❯ 1.` …).
12. **A command `id`** is a queue (`q-`) or scheduled (`s-`) id; `-` for `pause` / `resume`.
13. **`log`:** a live job's lines are the screen text from tmux `capture-pane` (what the user sees in Terminal, with TUI redraws applied); a finished job answers with its last saved screen, or else its cleaned log file. Empty lines are dropped. `truncated`: older lines were left out, or a line was cut at 400 characters. The 16 KB limit is for the whole `json` string; when it does not fit, the oldest lines go first. An unknown job gets no answer.
14. **`attach`:** the `.command` file first selects the job's window (`select-window -t '=<session>:<job id>'`), then attaches to the session; paths are single-quoted and there is no task text. `attached` and `attachError` stay in the status while the job is active; when it ends, both and the file are removed. If Terminal cannot be opened, neither field is written (Shelf's 3 s fallback takes over).
15. **`asking` and `now`** for a live job come from the screen text. `asking` looks at the last 6 lines (Claude Code's folder-trust and choice screens end in their options: `Enter to confirm`, `Enter to select`, `Esc to cancel`, `❯ 1.` …). `now` skips footer lines (`shift+tab to cycle`, `? for shortcuts` …).
16. **`blocked`:** the key is on every job. An unattended Claude job runs with `--output-format json`; when it ends, the number of `permission_denials` in the JSON becomes `blocked` (0 included), the `result` text goes to the log file, and the raw JSON stays in `~/Library/Logs/shelf-bridge/<id>.result.json`. `null` for attended jobs, Codex, running or waiting jobs, and when the JSON cannot be read. A denial does not change the state: exit 0 is `done`.
17. **`styles`:** optional; only in the answer for a live window (`capture-pane -e`). Same count and order as `lines`, one `[start,len,fg,bg,flags]` array per run, `[]` for a line without colour; no key when no line has a run. `start`/`len` count Unicode scalars of the line in `lines` (the 400 cut counts characters (graphemes) as in `lines`; runs are clipped to the scalars the cut leaves). `fg`/`bg`: `-1` default, `0…255` palette, `≥256` truecolor `256 + (r<<16 | g<<8 | b)`; `flags`: 1 bold, 2 dim, 4 italic, 8 underline, 16 inverse. Runs are in increasing order, never overlap, at most 24 per line (the rest are dropped and the text stays plain). Spaces that look uncoloured (no background, underline or inverse) join a run when both sides have the same style, and stay outside it otherwise. `lines` and `truncated` are computed as if there were no `styles`; then, over 16 KB, the oldest lines' runs become `[]`, and if it still does not fit the key is dropped.
