#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/LiveTranscript.swift tests/LiveTranscriptTests.swift \
    -o build/tests/LiveTranscriptTests
build/tests/LiveTranscriptTests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/FnGesture.swift macos/RecordingLifecycle.swift macos/KeyboardAccess.swift tests/FnShortcutTests.swift \
    -o build/tests/FnShortcutTests
build/tests/FnShortcutTests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/HotKey.swift tests/HotKeyTests.swift -framework AppKit -framework Carbon \
    -o build/tests/HotKeyTests
build/tests/HotKeyTests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/GlobeAction.swift macos/FnGesture.swift macos/FnHotKey.swift macos/KeyboardAccess.swift macos/Permissions.swift \
    tests/FnEventTests.swift -framework AppKit -framework Carbon \
    -framework AVFoundation -framework ApplicationServices -o build/tests/FnEventTests
build/tests/FnEventTests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/GlobeAction.swift tests/GlobeActionTests.swift -o build/tests/GlobeActionTests
build/tests/GlobeActionTests
