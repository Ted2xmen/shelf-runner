#!/bin/sh
# Test stand-in for claude/codex: never a real agent (CLAUDE.md).
# Prints its argv, sleeps FAKE_SECONDS, exits FAKE_EXIT; FAKE_IGNORE_INT=1 ignores Ctrl-C; FAKE_JSON see below. Reads them from fake-agent.env next to the queue.
[ -f ./fake-agent.env ] && . ./fake-agent.env
if [ -n "$FAKE_IGNORE_INT" ]; then trap '' INT; else trap 'echo "fake-agent: SIGINT"; exit 130' INT; fi
# FAKE_JSON: print mode's single JSON result on stdout instead of the argv; the start line goes to stderr.
if [ -n "$FAKE_JSON" ]; then echo "fake-agent: start pwd=$(pwd)" >&2; printf '%s\n' "$FAKE_JSON"; exit "${FAKE_EXIT:-0}"; fi
echo "fake-agent: start pwd=$(pwd)"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
i=0; while [ "$i" -lt "${FAKE_SECONDS:-0}" ]; do sleep 1; i=$((i+1)); done
exit "${FAKE_EXIT:-0}"
