#!/bin/sh
# Builds ShelfRunner.app (bundle id dev.ted2xmen.shelf-runner, LSUIElement) from a release build.
#   OUT=dir            where the app goes (default build/)
#   UNIVERSAL=1        arm64 + x86_64 (release; needs full Xcode)
#   VERSION=x.y.z      stamps CFBundleShortVersionString (default 0.0.0-dev from launchd/Info.plist;
#                      only scripts/release.sh sets a real number)
#   BUILD_NUMBER=n     stamps CFBundleVersion (default: the build time, so macOS does not keep a
#                      cached icon of an older build in notifications and Login Items)
#   SIGN_IDENTITY=...  "Developer ID Application: ..." signs with hardened runtime and a secure
#                      timestamp (what notarization needs); default is ad-hoc ("-").
set -eu
cd "$(dirname "$0")/.."
out="${OUT:-build}"
if [ "${UNIVERSAL:-0}" = "1" ]; then arch="--arch arm64 --arch x86_64"; else arch=""; fi
# shellcheck disable=SC2086
swift build -c release --product shelf-runner $arch
# shellcheck disable=SC2086
bin="$(swift build -c release $arch --show-bin-path)/shelf-runner"
app="$out/ShelfRunner.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp launchd/Info.plist "$app/Contents/Info.plist"
[ -n "${VERSION:-}" ] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-$(date +%Y%m%d.%H%M%S)}" "$app/Contents/Info.plist"
# AppIcon from design/icon/runner-app-icon-1024.svg
swift scripts/make-app-icon.swift >/dev/null
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin" "$app/Contents/MacOS/shelf-runner"
identity="${SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then codesign -f -s - "$app"
else codesign -f -s "$identity" -o runtime --timestamp "$app"; fi
echo "$(cd "$out" && pwd)/ShelfRunner.app"
