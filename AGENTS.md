# Repository instructions

## Product and architecture

Local Whisper is a macOS menu bar dictation app. Its GitHub repository is
`https://github.com/07rjain/koel`. Keep product naming unchanged unless the user
requests a rename.

- `src/` owns the Rust core: settings, WAV validation, Hugging Face model
  downloads, local inference, Groq, and the JSON C interface.
- `macos/` owns native macOS integration: AppKit menus, microphone recording,
  Apple Speech, Keychain, the global shortcut, and clipboard/paste behavior.
- `scripts/` owns builds, installation, verification, and release tooling.
- The current target is Apple silicon with macOS 26+ and Swift 6.2+.
- Keep the app accessible from the menu bar. Do not introduce a main window,
  Electron, a web frontend, or another UI framework without a product reason.

## Working conventions

- Read relevant code and README sections before editing. Work independently;
  delegate only when the user explicitly requests delegation.
- Keep inference, HTTP, model downloads, and expensive disk work off the UI
  thread. Swift types crossing concurrency boundaries must be `Sendable`.
- Preserve the separation between on-device providers and Groq. Never switch
  providers or upload audio as an implicit fallback.
- Keep Groq credentials in Keychain; never include keys in settings, logs,
  source, tests, command-line arguments, or release artifacts.
- Keep temporary audio private and clean it up after handled completion,
  discard, or normal shutdown. Do not introduce transcript retention without
  an explicit product decision.
- Pin model artifacts and validate size and SHA-256 before loading native code.
- Explicitly release cached local inference sessions before process exit so
  Metal cleanup does not crash.
- Use synthetic audio for unattended tests. Do not record the user's microphone
  or send recordings to a cloud provider merely to exercise a test.

## Versions and releases

- `VERSION` is the canonical stable semantic version. Use `scripts/version.py`
  to synchronize the Cargo manifest and lockfile; do not edit generated version
  values independently.
- Record user-visible changes in `CHANGELOG.md`. Keep an `Unreleased` section;
  put released entries under a dated version heading.
- Keep updater behavior and GitHub release asset names consistent with the
  release workflow. `release.json` identifies the release repository.
- Do not publish releases, push tags, change a release repository, or sign with
  user credentials unless authorized by the current task.
- Development builds use ad-hoc signing. Public distribution requires the
  maintainer's Developer ID/notarization setup; never invent credentials or
  claim a build is notarized without verification.

## Validation

- Run `scripts/check.sh` for code changes affecting the engine, native app,
  version synchronization, or release packaging.
- For transcription changes, use `python3 scripts/smoke.py --apple` when its
  model and Apple assets are installed. Test only the affected paths when a
  narrower check provides the needed evidence.
- A real Groq request requires an explicit opt-in and a user-provided key. The
  default tests use a local HTTP fixture.
- Verify app signatures on a clean staging directory outside Desktop/iCloud.
  Use the install script to install the verified archive. Do not overwrite an
  unrelated app or replace a running instance.
- Report actual verification and remaining interactive checks separately.
