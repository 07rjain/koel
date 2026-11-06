#!/usr/bin/env python3
"""Keep Cargo and macOS versions synchronized with the canonical VERSION file."""
import argparse
from pathlib import Path
import plistlib
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parent.parent
PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def parse_version(value):
    match = PATTERN.fullmatch(value)
    if match is None:
        raise ValueError("Use a stable semantic version, such as 0.2.0 (without v).")
    parts = tuple(int(part) for part in match.groups())
    if parts[1] >= 1000 or parts[2] >= 1000:
        raise ValueError("Minor and patch versions must be below 1000 for the macOS build number.")
    return parts


def read_version(root=ROOT):
    version = (root / "VERSION").read_text().strip()
    parse_version(version)
    return version


def build_number(version):
    major, minor, patch = parse_version(version)
    return str(major * 1_000_000 + minor * 1000 + patch + 1)


def check(root=ROOT):
    version = read_version(root)
    manifest = tomllib.loads((root / "Cargo.toml").read_text())
    lock = tomllib.loads((root / "Cargo.lock").read_text())
    package = next(package for package in lock["package"] if package["name"] == manifest["package"]["name"])
    info = plistlib.loads((root / "macos/Info.plist").read_bytes())
    expected = {
        "Cargo.toml": (manifest["package"]["version"], version),
        "Cargo.lock": (package["version"], version),
        "CFBundleShortVersionString": (info["CFBundleShortVersionString"], version),
        "CFBundleVersion": (info["CFBundleVersion"], build_number(version)),
    }
    for name, (actual, target) in expected.items():
        if actual != target:
            raise ValueError(f"{name} is {actual}, expected {target}. Run: python3 scripts/version.py sync")
    return version


def sync(version, root=ROOT):
    parse_version(version)
    manifest_path = root / "Cargo.toml"
    manifest = manifest_path.read_text()
    name = tomllib.loads(manifest)["package"]["name"]
    manifest, count = re.subn(r'(?m)^(version\s*=\s*)"[^"]+"', lambda m: f'{m[1]}"{version}"', manifest, count=1)
    if count != 1:
        raise ValueError("Cannot locate Cargo package version")
    lock_path = root / "Cargo.lock"
    lock = lock_path.read_text()
    expression = rf'(\[\[package\]\]\nname = "{re.escape(name)}"\nversion = ")[^"]+("\n)'
    lock, count = re.subn(expression, lambda m: f"{m[1]}{version}{m[2]}", lock)
    if count != 1:
        raise ValueError("Cannot locate the root package in Cargo.lock")
    info_path = root / "macos/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build_number(version)
    # Compute/validate all outputs before changing files.
    info_bytes = plistlib.dumps(info, sort_keys=False)
    manifest_path.write_text(manifest)
    lock_path.write_text(lock)
    info_path.write_bytes(info_bytes)
    (root / "VERSION").write_text(version + "\n")
    check(root)


def release_notes(version, root=ROOT):
    parse_version(version)
    changelog = (root / "CHANGELOG.md").read_text()
    match = re.search(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\n(.*?)(?=^## |^\[Unreleased\]:|\Z)", changelog, re.M | re.S)
    if match is None or not match[1].strip():
        raise ValueError(f"Add a dated [{version}] entry to CHANGELOG.md before releasing")
    return match[1].strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("sync")
    commands.add_parser("print")
    commands.add_parser("notes")
    commands.add_parser("set").add_argument("version")
    args = parser.parse_args()
    try:
        if args.command == "set":
            sync(args.version)
            print(f"Synchronized version {args.version}; update CHANGELOG.md before releasing.")
        elif args.command == "sync":
            sync(read_version())
            print(f"Synchronized version {read_version()}")
        elif args.command == "notes":
            print(release_notes(check()))
        else:
            print(check())
    except (ValueError, OSError, KeyError, StopIteration) as error:
        parser.exit(1, f"Version error: {error}\n")


if __name__ == "__main__":
    main()
