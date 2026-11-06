#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

archive="$PWD/dist/Local Whisper.zip"
if [[ ! -f "$archive" ]]; then scripts/build-app.sh "${1:-debug}"; fi
destination="$HOME/Applications/Local Whisper.app"
if [[ -e "$destination" ]]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")
    if [[ "$bundle_id" != app.localwhisper.desktop ]]; then
        echo "Another app already exists at $destination; leaving it in place." >&2
        exit 1
    fi
    if pgrep -f "$destination/Contents/MacOS/Local Whisper" >/dev/null; then
        echo "Quit Local Whisper before installing a new build." >&2
        exit 1
    fi
fi
stage="$(mktemp -d /private/tmp/local-whisper-install.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto -x -k --noextattr "$archive" "$stage"
codesign --verify --deep --strict "$stage/Local Whisper.app"
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "$stage/Local Whisper.app" "$destination"
xattr -cr "$destination"
codesign --verify --deep --strict "$destination"
echo "Installed: $destination"
