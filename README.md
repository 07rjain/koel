# Local Whisper

A macOS menu bar dictation app with a Rust transcription core and a small native Swift/AppKit shell. Select Apple Speech, a downloaded Hugging Face model, or Groq; record with **⌘⇧Space**, press it again to finish, and paste into the app you were using. Apple Speech transcribes live while you speak.

[GitHub](https://github.com/07rjain/koel) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Release process](docs/RELEASING.md)

This first version focuses on the transcription providers and native integration. Controls live in the menu bar; there is no main window, web view, Electron runtime, or Dock icon. Small native dialogs handle API-key entry and errors.

## Requirements

- **Apple silicon, macOS 26 or later.** The Apple provider uses `SpeechAnalyzer` / `SpeechTranscriber` from macOS 26. It does not use the older server-capable `SFSpeechRecognizer` path.
- Rust/Cargo, Python 3.11+, Xcode Command Line Tools with the macOS 26 SDK and Swift 6.2+, and CMake. Install missing CMake with `brew install cmake`.

## Build and run

```sh
scripts/run.sh
```

This builds the Rust core and native shell, packages and signs the app for local development, installs it to `~/Applications/Local Whisper.app`, and opens it. Look for the waveform icon in the menu bar. Installation refuses to replace a differently identified app or update an instance that is running.

For an optimized build:

```sh
scripts/run.sh release
```

Build without installing or opening:

```sh
scripts/build-app.sh release
```

The verified release archive is `dist/LocalWhisper-<version>-macos-arm64.zip`, accompanied by a SHA-256 file. `dist/Local Whisper.zip` is kept as an installer alias, and a convenience bundle is copied to `dist/Local Whisper.app`. Signing happens in a temporary directory because Desktop/iCloud file providers can attach attributes that break signing. The archive and installation scripts avoid carrying these attributes into the installed app. Debug symbols stay in `build/`.

Development builds are ad-hoc signed. Set `LOCAL_WHISPER_SIGNING_IDENTITY` to a suitable signing identity when needed. Public distribution still requires Developer ID signing and notarization.

## First dictation

1. Open the menu and select a provider.
2. For **Apple Speech**, choose **Apple Speech → Prepare Apple Speech**. macOS reuses installed assets or downloads the selected language once. Apple supports a specific set of locales; the menu lists those reported by the system.
3. For **Hugging Face Model**, choose a download under **Local Models**. Downloading also selects that model and the local provider.
4. For **Groq**, enter your API key under **Groq → Set API Key**, then select the Groq provider. Keys are stored in macOS Keychain, outside the preferences file.
5. Press **⌘⇧Space**, grant microphone permission when macOS asks, speak, and press the shortcut again. Start/stop is also available from the menu.
6. To insert text automatically, use **Enable Pasting (Accessibility)** and grant the app access in System Settings. Until then, transcripts are copied to the clipboard so you can paste manually.

Recordings stop after five minutes. With Apple Speech selected, open the menu while speaking to see **Live Transcript** update. Partial words can change as the model hears more audio. Stop finalizes the text, then copies/pastes it once; it does not insert changing partial hypotheses into your other app. Discard cancels the stream without copying it. A second recording cannot start while finalization, file transcription, or a model download is running. If ⌘⇧Space is already registered by another app, the menu controls remain available.

## Fn / Globe shortcuts

Both gestures work with Apple Speech, local models, and Groq, using the selected provider:

- **Hold Fn:** hold for 0.3 seconds to start, speak, then release to stop and transcribe. Start speaking when the menu bar recording indicator turns red.
- **Double-tap Fn:** tap twice with no more than 0.35 seconds between the first release and second press to start hands-free recording. Double-tap again to stop and transcribe.
- **⌘⇧Space:** continues to toggle recording without Fn setup. Start/stop is also available in the menu.

Open **Keyboard Shortcuts → Set Up Fn / Globe Key** in the app menu. Enable Local Whisper in **System Settings → Privacy & Security → Input Monitoring**; quit and reopen it if macOS requests this. In **System Settings → Keyboard**, set **Press 🌐 key to** (or **Press fn key to**) to **Do Nothing**. Under **Keyboard → Dictation**, change or disable **Press Fn Twice** if selected, so Apple Dictation does not start alongside this app. Local Whisper does not change these system settings or suppress key events.

A single tap does nothing. Combining Fn with another key cancels a pending hold/double tap, so Fn+arrows and other Fn shortcuts pass through normally. If another key is pressed during hold-to-talk, that hold stops. Releasing a hold does not stop a recording started with double-tap, the menu, or ⌘⇧Space. Sleep, session changes, and a disabled event listener stop Fn-owned recording. Fn must be exposed as the macOS Fn/Globe key; keyboards that handle Fn entirely in firmware cannot provide these gestures. Secure Input and other apps that intercept Fn can prevent event delivery; use the menu or ⌘⇧Space in that case.

If you release Fn while microphone permission or Apple Speech startup is pending, that attempt is cancelled before capture starts. Grant the permission, then hold Fn again. The passive keyboard listener handles only gesture state; it does not save or log typed text.

## Providers

**Apple Speech** uses Apple's on-device model through the native Speech framework. Microphone dictation feeds audio from `AVAudioEngine` into `SpeechAnalyzer` continuously with progressive results. Audio is converted to the analyzer's preferred format off the microphone callback. Revised hypotheses replace overlapping partial text; final segments are retained without duplicating words. The menu and status-item tooltip display the live transcript. Stop ends the input and flushes the remaining final results. Apple microphone audio stays in memory and is not saved as a WAV.

Language preparation is explicit; recording does not initiate an asset download. Apple models can require a first download even if built-in Dictation already works, because system speech services do not necessarily use the same assets. After the selected assets are installed, recognition works locally. Imported audio files retain the completed-file Apple transcription path.

**Local Hugging Face models** run inside the Rust process using `transcribe.cpp 0.4.1` with Metal. The catalog contains:

- Whisper Tiny Q8: approximately 46 MB, multilingual, useful for a quick first run.
- Parakeet TDT v3 Q8: approximately 740 MB, 25 European languages, automatic language detection.
- Whisper large-v3-turbo Q8: approximately 886 MB, multilingual.

Downloads use pinned Hugging Face revisions and validate the expected size and SHA-256 before an atomic install. Models are verified again before loading and cached between recordings; changing the provider or model releases the cache. Failed downloads leave the installed model untouched and can be retried from the menu; partial downloads currently restart. This supports the listed `transcribe.cpp` GGUF speech models, not arbitrary Hugging Face PyTorch models, LLMs, or whisper.cpp GGML files.

**Groq** uploads a WAV recording to `https://api.groq.com/openai/v1/audio/transcriptions`. Choose `whisper-large-v3-turbo` or `whisper-large-v3`. The API key comes from Keychain for the app, or `GROQ_API_KEY` for the standalone Rust CLI. Groq requires a connection and an account/key; provider errors do not trigger an automatic fallback or upload to another service.

The Local / Groq Language menu supplies an optional language hint. Apple has its own locale selection. Parakeet v3 always detects its language. No rewriting or cleanup service is applied to recognition output.

## Audio, clipboard, and data

- Apple microphone dictation streams in memory without creating a recording file. Local and Groq dictation record mono, 16 kHz, 16-bit PCM WAV in a private temporary folder. Those recordings are removed after success, handled failure, discard, and normal quit. A crash or force quit can leave temporary files for the OS to clean up.
- No transcript history is written to disk. The latest successful transcript stays in memory and is placed on the system clipboard; the OS and clipboard tools may retain clipboard content.
- Paste targets the app that was active when recording started and checks focus before sending ⌘V.
- Preferences and downloaded models are in `~/Library/Application Support/LocalWhisper/`. The menu can open this folder.
- Groq keys are stored under the `app.localwhisper.groq` Keychain service and can be removed from the menu.
- Nothing is uploaded for the Apple or local provider. Network requests occur for explicit model preparation/downloads, selected Groq transcription, and requested update checks against GitHub.

**Transcribe Audio File** accepts WAV files. For Rust/local/Groq, use mono, 16 kHz, 16-bit PCM, up to five minutes. Convert other formats with:

```sh
ffmpeg -i input.m4a -ar 16000 -ac 1 -c:a pcm_s16le output.wav
```

File transcription copies text without automatically pasting into another app or deleting the source file.

## Versions and updates

`VERSION` is the canonical app version. It is synchronized with Cargo and the macOS bundle by:

```sh
python3 scripts/version.py check
python3 scripts/version.py set 0.2.1
```

The current version is shown in the menu, About dialog, diagnostics, and `--version` output from both executables. Update checks run only when you select **Check for Updates**. They query the latest stable public release from [07rjain/koel](https://github.com/07rjain/koel), compare semantic versions, and offer a download/release page when a newer version exists. If nothing has been published yet, the app says so. It never sends audio, transcripts, credentials, or app settings during a check.

Updates are downloaded through your browser and installed manually by replacing the app after quitting it. Existing preferences, models, and Keychain credentials stay in their separate locations. Automatic installation and Sparkle are not included.

Add user-visible changes to [CHANGELOG.md](CHANGELOG.md). The [release guide](docs/RELEASING.md) explains version bumps, tag validation, versioned archives, and the workflow that creates a draft GitHub release for review. The workflow does not publish a release until a maintainer publishes the draft.

## Development and verification

```sh
scripts/check.sh
python3 scripts/smoke.py --apple
```

`check.sh` runs version consistency checks, Python release-tool tests, native Swift tests, Rust formatting, Clippy with warnings denied, focused tests, and a complete native build with signature verification. Tests cover rejected audio formats, corrupted model files, atomic configuration validation, multipart Groq requests against a local HTTP fixture, and update handling for newer/equal/older versions, previews, missing releases, invalid responses, and rate limits. Swift tests check transcript revisions, Fn gesture timing/chords/interruptions, recording ownership, and release/stop requests during asynchronous startup. Shortcut tests use synthetic timestamps without injecting keys or recording microphone audio. GitHub Actions runs the same checks on macOS.

`smoke.py` generates synthetic speech with macOS `say` and exercises real transcription through the Rust CLI, the Swift-to-Rust bridge, and optionally Apple Speech. The Apple check includes completed-file recognition and a paced 48 kHz stereo stream: it cancels/restarts a session, requires partial text before input ends, and checks the final text for duplication. It isolates its configuration and leaves your provider preferences unchanged. It needs Whisper Tiny installed; add `--download` to allow its download. `--apple` requires English (US) Apple assets prepared first. Add `--groq` only when you want to send the synthetic fixture to Groq with the key you entered in the app.

Useful diagnostics:

```sh
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --diagnose
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --version
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --check-updates
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --prepare-apple en-US
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --apple-transcribe output.wav en-US
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --apple-stream-file output.wav en-US
"$HOME/Applications/Local Whisper.app/Contents/MacOS/Local Whisper" --transcribe output.wav
target/debug/local-whisper --help
```

`LOCAL_WHISPER_DATA_DIR` overrides the data directory for development and isolated checks. The Rust CLI accepts JSON requests over stdin with `local-whisper request`; it never accepts API keys in command-line arguments.

## Layout and references

- `src/`: Rust configuration, audio validation, model catalog/downloads, `transcribe.cpp` inference, Groq client, JSON C bridge, and CLI.
- `macos/`: native menu bar, recording, Apple Speech, Keychain, hotkey, and paste integration.
- `scripts/`: build, install, run, and verification commands.

References: [Hex](https://github.com/anomalyco/hex) for Rust/transcribe.cpp and pinned model metadata; [OpenWhispr](https://github.com/OpenWhispr/openwhispr) for the selectable local/cloud dictation workflow; [CodexBar](https://github.com/steipete/CodexBar) for the native menu bar product direction. This is a separate implementation, not a fork of their UIs.

Current verification: real Apple Speech and Whisper Tiny recognition were exercised with synthetic audio on this Mac, including the Apple streaming pipeline. Live microphone permissions, physical Fn/Globe gestures, keyboard insertion into other apps, and a real Groq account require an interactive check. The larger catalog models have not been downloaded or benchmarked here. Visual polish, custom model imports, login items, and public distribution are future work.
