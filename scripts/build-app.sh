#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(python3 scripts/version.py check)"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "This app currently requires an Apple silicon Mac with macOS 26+." >&2
    exit 1
fi

profile="${1:-debug}"
if [[ "$profile" == release ]]; then
    cargo build --release --locked
elif [[ "$profile" == debug ]]; then
    cargo build --locked
else
    echo "Usage: scripts/build-app.sh [debug|release]" >&2
    exit 2
fi

staging="$(mktemp -d /private/tmp/local-whisper-build.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Local Whisper.app"
mkdir -p build dist "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp macos/Info.plist "$bundle/Contents/Info.plist"
cp CHANGELOG.md LICENSE VERSION release.json "$bundle/Contents/Resources/"
printf APPL???? > "$bundle/Contents/PkgInfo"
swift_flags=(-g)
if [[ "$profile" == release ]]; then swift_flags=(-O); fi
xcrun swiftc -swift-version 6 -target arm64-apple-macosx26.0 \
    "${swift_flags[@]}" -parse-as-library -import-objc-header macos/LocalWhisperCore.h \
    macos/*.swift "target/$profile/liblocal_whisper_core.a" \
    -framework AppKit -framework AVFoundation -framework Speech -framework Carbon \
    -framework ApplicationServices -framework Security -framework SystemConfiguration \
    -framework Metal -framework Accelerate -lc++ -liconv \
    -o "build/Local Whisper"
cp "build/Local Whisper" "$bundle/Contents/MacOS/Local Whisper"
cp "target/$profile/local-whisper" "$bundle/Contents/MacOS/local-whisper"
# Sign outside Desktop/iCloud folders, which can reattach Finder attributes.
xattr -cr "$bundle"
codesign --force --sign "${LOCAL_WHISPER_SIGNING_IDENTITY:--}" "$bundle/Contents/MacOS/local-whisper"
codesign --force --sign "${LOCAL_WHISPER_SIGNING_IDENTITY:--}" \
    --options runtime --entitlements macos/LocalWhisper.entitlements "$bundle"
codesign --verify --deep --strict "$bundle"
archive_name="LocalWhisper-$version-macos-arm64.zip"
ditto -c -k --keepParent --norsrc --noextattr "$bundle" "$PWD/dist/$archive_name"
(
    cd dist
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
cp "dist/$archive_name" "dist/Local Whisper.zip"
ditto --norsrc --noextattr "$bundle" "$PWD/dist/Local Whisper.app"
echo "Built and verified: $PWD/dist/$archive_name"
