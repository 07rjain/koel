# Releases and updates

`VERSION` is the authoritative stable semantic version. A changelog entry
describes prepared changes; it does not itself publish a GitHub release.
`0.1.0` in the changelog records the initial local app.

## Prepare a version

```sh
python3 scripts/version.py set 0.2.1
```

This synchronizes `VERSION`, the root package in `Cargo.toml` and `Cargo.lock`,
and the macOS bundle's marketing/build versions. The build number is derived
numerically from major/minor/patch, so it increases even when a component gains
a digit. Minor and patch components must each be below 1000.

Move the changes under `Unreleased` into a dated `## [0.2.1] - YYYY-MM-DD`
section of `CHANGELOG.md`, retain an empty `Unreleased` section, and update the
comparison/release links at the bottom. Use:

```sh
python3 scripts/version.py check
python3 scripts/version.py notes
scripts/check.sh
scripts/build-app.sh release
```

The build produces:

- `dist/LocalWhisper-0.2.1-macos-arm64.zip`
- `dist/LocalWhisper-0.2.1-macos-arm64.zip.sha256`
- `dist/Local Whisper.zip`, a compatibility alias used by the local installer.

Versions, archive names, checksums, and release notes must agree. The build and
CI fail on mismatched versions. The Rust build also checks `VERSION` against
Cargo's package version, including when Cargo is used directly.

## GitHub workflow

After reviewing and committing the release changes, a maintainer can push a
matching version tag:

```sh
git tag -a v0.2.1 -m "Local Whisper 0.2.1"
git push origin v0.2.1
```

The workflow validates the tag, checks the code, builds the Apple silicon app,
and creates a **draft** GitHub release with the archive, checksum, and the
version's changelog notes. Review the draft, signing, and artifacts before
publishing. A tag or draft alone is not visible to the app's update check.
Only push tags or publish when you intend to perform those actions.

The workflow currently ad-hoc signs its binaries, like local development.
It does not configure a Developer ID certificate or notarize the app. Set up
the maintainer's signing/notarization process before distributing binaries
that should open normally on other Macs. The checksum detects accidental
archive corruption; it does not substitute for code signing.

## In-app updates

`release.json` configures `07rjain/koel`. Selecting **Check for Updates** sends
an unauthenticated request to GitHub's latest stable release API. It sends no
recording, transcript, Groq key, or app settings. There are no scheduled or
startup update requests.

The checker compares numeric semantic versions, ignores draft/prerelease
builds, never offers a downgrade, and reports an empty release list distinctly.
Stable release tags must be `vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH`.

When a newer release includes the expected versioned Apple silicon archive,
**Download Update** opens that asset in the browser. **View Release Notes**
opens its GitHub release page. If there is no matching binary, the app offers
the release page. Users quit the old app and replace it with the downloaded
app; preferences, model files, and Keychain entries stay in their existing
locations. Downloading and installation are manual; there is no unattended
replacement, automatic relaunch, or Sparkle integration in this version.

If the repository has no published release yet, the checker reports that
state. Newer-release behavior can be verified with the local fixtures before
a maintainer publishes a version.
