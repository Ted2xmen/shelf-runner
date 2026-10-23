#!/bin/sh
# Development install: writes the LaunchAgent for build/ShelfRunner.app and loads it.
# The runner binary never writes outside its own folders; installing the agent is this script's
# (later Homebrew's) job. Undo: scripts/install-agent.sh --uninstall
set -eu
cd "$(dirname "$0")/.."
label=dev.ted2xmen.shelf-runner
plist="$HOME/Library/LaunchAgents/$label.plist"
if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist"; echo "removed: $plist"; exit 0
fi
app="$PWD/build/ShelfRunner.app"
[ -x "$app/Contents/MacOS/shelf-runner" ] || { echo "run scripts/build-app.sh first" >&2; exit 1; }
# Register this build with LaunchServices: notifications take the icon from it .
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" || true
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/shelf-runner"
sed -e "s|@LABEL@|$label|" -e "s|@APP@|$app|" -e "s|@LOG@|$HOME/Library/Logs/shelf-runner|" -e "s|@ENV@||" \
  launchd/$label.plist.template > "$plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the old job is gone; bootstrap then fails with error 5. Retry briefly.
i=0
until launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 10 ] || { launchctl bootstrap "gui/$(id -u)" "$plist"; exit 1; }
  sleep 0.5
done
echo "loaded: $plist"
