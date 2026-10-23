#!/bin/sh
# Release build: universal ShelfRunner.app, Developer ID signed, notarized and stapled, zipped,
# plus the Homebrew cask for ted2xmen/homebrew-tap. Pushes nothing: it prints the publish steps.
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=shelf-runner scripts/release.sh 0.1.0
#
# One-time setup: a Developer ID Application certificate in the login keychain, and
#   xcrun notarytool store-credentials shelf-runner --apple-id <id> --team-id <TEAMID>
# (asks for an app-specific password and keeps it in the keychain).
set -eu
cd "$(dirname "$0")/.."
fail() { echo "release: $*" >&2; exit 1; }

v="${1:-}"
echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "version must be x.y.z: '$v'"
: "${DEVELOPER_ID:?DEVELOPER_ID is required (Developer ID Application: ...)}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is required (xcrun notarytool store-credentials)}"
case "$DEVELOPER_ID" in "Developer ID Application:"*) ;; *) fail "DEVELOPER_ID must be a Developer ID Application identity" ;; esac
security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID" || fail "not in the keychain: $DEVELOPER_ID"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean (everything, design/ included, must be committed)"
[ -f design/icon/runner-app-icon-1024.svg ] || fail "design/icon/runner-app-icon-1024.svg is missing"

swift test

out="build/release/$v"
rm -rf "$out"
mkdir -p "$out"
# Build number: commit count, monotonic only while releases come from a linear main.
# The log goes to a file, not a pipe: /bin/sh has no pipefail, and a failed build must stop here.
OUT="$out" UNIVERSAL=1 VERSION="$v" BUILD_NUMBER="$(git rev-list --count HEAD)" SIGN_IDENTITY="$DEVELOPER_ID" \
  scripts/build-app.sh >"$out/build.log" 2>&1 || { tail -20 "$out/build.log" >&2; fail "build-app.sh failed ($out/build.log)"; }
app="$(tail -1 "$out/build.log")"
[ -x "$app/Contents/MacOS/shelf-runner" ] || fail "no app bundle: $app"
archs="$(lipo -archs "$app/Contents/MacOS/shelf-runner")"
case " $archs " in *" arm64 "*) ;; *) fail "no arm64: $archs" ;; esac
case " $archs " in *" x86_64 "*) ;; *) fail "no x86_64: $archs" ;; esac
codesign --verify --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -q "(runtime)" || fail "no hardened runtime"

zip="$out/ShelfRunner-$v.zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
# Zip again so the download carries the stapled ticket (works offline, first launch included).
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
# Release notes: CHANGELOG.md without its frontmatter.
awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' CHANGELOG.md > "$out/notes.md"
sed -e "s/@VERSION@/$v/" -e "s/@SHA256@/$sha/" packaging/homebrew/shelf-runner.rb.template > "$out/shelf-runner.rb"

cat <<EOF

ready: $zip
sha256: $sha
cask:  $out/shelf-runner.rb

Publish (this script pushes nothing):
  git tag -a v$v -m "shelf-runner $v" && git push origin main v$v
  gh release create v$v "$zip" --repo ted2xmen/shelf-runner --title "shelf-runner $v" --notes-file "$out/notes.md"
  cp "$out/shelf-runner.rb" <homebrew-tap clone>/Casks/shelf-runner.rb   # ted2xmen/homebrew-tap, commit + push
Try it (clean Mac): brew install --cask ted2xmen/tap/shelf-runner && shelf-runner doctor
EOF
