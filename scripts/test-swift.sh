#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/LiveTranscript.swift tests/LiveTranscriptTests.swift \
    -o build/tests/LiveTranscriptTests
build/tests/LiveTranscriptTests
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    macos/FnGesture.swift macos/RecordingLifecycle.swift tests/FnShortcutTests.swift \
    -o build/tests/FnShortcutTests
build/tests/FnShortcutTests
