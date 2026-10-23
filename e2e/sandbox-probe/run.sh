#!/bin/sh
# End-to-end check: a sandboxed test app reads the runner status (ping -> status, signed pause/resume).
# Uses a temp home and a private tmux socket; never the user's runner state.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
tmp="$(mktemp -d)"; trap 'kill $agent 2>/dev/null || true; rm -rf "$tmp"' EXIT
swift build --package-path "$root" >/dev/null
bin="$(swift build --package-path "$root" --show-bin-path)/shelf-runner"
app="$tmp/ShelfRunnerProbe.app"; mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ted2xmen.shelf-runner.probe</string>
<key>CFBundleExecutable</key><string>probe</string><key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/></dict></plist>
PLIST
printf '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' > "$tmp/ent.plist"
swiftc -O "$here/Probe.swift" -o "$app/Contents/MacOS/probe"
codesign -f -s - --entitlements "$tmp/ent.plist" "$app" 2>/dev/null
export SHELF_RUNNER_HOME="$tmp/home"; mkdir -p "$tmp/home/.config/shelf-runner"
printf '[tmux]\nsocket = "shelf-runner-probe"\n' > "$tmp/home/.config/shelf-runner/config.toml"
"$bin" pair >/dev/null 2>&1
keyhex="$(xxd -p -c 64 "$tmp/home/Library/Application Support/shelf-runner/pair.key")"
"$bin" agent 2>"$tmp/agent.err" & agent=$!
sleep 1
out="$HOME/Library/Containers/dev.ted2xmen.shelf-runner.probe/Data/probe.json"; rm -f "$out"
open -W -n "$app" --args "$keyhex"
cat "$out"
grep -E "command" "$tmp/agent.err" || true
