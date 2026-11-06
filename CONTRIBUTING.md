# Contributing

Local Whisper lives at [07rjain/koel](https://github.com/07rjain/koel). It is an
Apple silicon macOS 26+ app with a Rust engine and a native Swift shell.

1. Read [README.md](README.md) for setup and [AGENTS.md](AGENTS.md) for repository conventions.
2. Keep changes focused. For bugs, include the app version, macOS version,
   selected provider/model, reproduction steps, and relevant error messages.
   Do not attach API keys or private recordings.
3. Run `scripts/check.sh`. For transcription changes, run the applicable
   synthetic-audio checks from the README. State which paths you exercised.
4. Add user-visible changes under `Unreleased` in [CHANGELOG.md](CHANGELOG.md).
   Maintainers assign the release version using `scripts/version.py`.

Issues and pull requests are welcome. Published binaries and new versions are
managed through the [release process](docs/RELEASING.md).
