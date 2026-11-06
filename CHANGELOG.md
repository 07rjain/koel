# Changelog

User-visible changes are recorded here. Versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.1] - 2026-11-06

### Added

- Fn/Globe hold-to-talk (release to transcribe) and double-tap to start/stop with any selected provider.
- Menu bar keyboard setup guidance for Accessibility, Input Monitoring, and macOS Fn/Dictation shortcut conflicts.
- Permissions menu for microphone and keyboard/pasting access, visible Fn setup, and shortcut registration/permission diagnostics.
- Microphone-free Fn gesture testing, copyable in-memory timing diagnostics, and a `--test-fn` launch mode.
- Deterministic shortcut tests for gesture timing, key combinations, interruptions, and release during microphone startup.
- Apple microphone dictation now streams directly into on-device SpeechAnalyzer, with partial text visible in the menu bar while speaking.
- Apple volatile hypotheses are replaced as they change; only finalized text is copied/pasted when recording stops.
- A paced synthetic-audio streaming check verifies recognition produces updates before input ends.

### Changed

- Fn double-tap recognizes the second press immediately, accepts a 500 ms tap gap, and keeps hands-free recording active when the second press is held longer or released.
- Automatically pause the macOS standalone Globe action while Fn listening is active, following OpenWhispr’s native approach, so double-tap does not also open emoji or Apple Dictation. Restore the original on quit, sleep, session changes, or lost keyboard access; recover interrupted runs and preserve user changes. No manual Keyboard settings change is required.
- Fn can use Accessibility approval without a separate Input Monitoring grant; Input Monitoring remains an alternative for keyboard listening alone.
- The global shortcut uses the Carbon event dispatcher, checks its registered identity, and unregisters cleanly on shutdown.
- Apple microphone dictation no longer writes a temporary WAV or waits for Stop to begin recognition. File imports, local Hugging Face models, and Groq retain their file-based workflows.

### Fixed

- Extra macOS key events after Fn release no longer cancel the first tap. Like OpenWhispr, another key interrupts the gesture only while Fn is held, fixing double-tap failures with normal tap timing.
- Fn detection follows modifier-flag transitions, including releases with alternate key-code metadata, and preserves gestures across duplicate Fn notifications.

### Distribution

- Apple silicon and macOS 26+ are required. This release is ad-hoc signed and is not notarized.

## [0.2.0] - 2026-11-06

### Added

- Menu bar **Check for Updates** action connected to `07rjain/koel` GitHub releases.
- Current version in the menu, About dialog, diagnostics, and both command-line tools.
- A canonical `VERSION` file and tooling to synchronize Rust and macOS bundle versions.
- Versioned macOS release archives, SHA-256 checksums, and a GitHub release workflow.
- Contributor and agent instructions, including release and verification guidance.

### Changed

- Update checks distinguish unpublished releases from an up-to-date installation.
- Updates are checked only when requested; downloads and installation remain manual.

## [0.1.0] - 2026-11-06

### Added

- Native menu bar app backed by a Rust transcription core.
- Apple's on-device SpeechAnalyzer / SpeechTranscriber integration on macOS 26+.
- Local Hugging Face Whisper Tiny, Whisper large-v3-turbo, and Parakeet v3 models using transcribe.cpp and Metal.
- Pinned model downloads with size and SHA-256 verification.
- Groq speech transcription with Keychain storage for API keys.
- Global recording shortcut, clipboard output, and optional insertion into the focused app.
- Native app packaging, local installation, and synthetic-audio smoke checks.

[Unreleased]: https://github.com/07rjain/koel/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/07rjain/koel/releases/tag/v0.2.1
[0.2.0]: https://github.com/07rjain/koel/releases/tag/v0.2.0
[0.1.0]: https://github.com/07rjain/koel/releases/tag/v0.1.0
