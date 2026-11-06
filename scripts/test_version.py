import plistlib
from pathlib import Path
import shutil
import tempfile
import tomllib
import unittest

import version


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "macos").mkdir()
        for path in ["VERSION", "Cargo.toml", "Cargo.lock", "macos/Info.plist", "CHANGELOG.md"]:
            shutil.copyfile(version.ROOT / path, self.root / path)

    def test_bump_synchronizes_all_versions_and_preserves_dependency_versions(self):
        before = tomllib.loads((self.root / "Cargo.lock").read_text())["package"]
        version.sync("0.10.0", self.root)
        self.assertEqual(version.check(self.root), "0.10.0")
        after = tomllib.loads((self.root / "Cargo.lock").read_text())["package"]
        dependencies = lambda packages: [p for p in packages if p["name"] != "local-whisper-core"]
        self.assertEqual(dependencies(before), dependencies(after))
        info = plistlib.loads((self.root / "macos/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleVersion"], "10001")
        self.assertGreater(int(info["CFBundleVersion"]), int(version.build_number("0.9.0")))

    def test_drift_is_rejected_instead_of_shipping_mismatched_versions(self):
        (self.root / "VERSION").write_text("9.0.0\n")
        with self.assertRaisesRegex(ValueError, "disagree|expected"):
            version.check(self.root)

    def test_invalid_bumps_leave_files_untouched(self):
        original = (self.root / "Cargo.toml").read_bytes()
        for invalid in ["v0.2.0", "01.2.0", "1.0", "1.0.0-beta.1", "1.1000.0"]:
            with self.assertRaises(ValueError):
                version.sync(invalid, self.root)
        self.assertEqual((self.root / "Cargo.toml").read_bytes(), original)

    def test_release_notes_include_only_the_requested_version(self):
        notes = version.release_notes("0.2.0", self.root)
        self.assertIn("Check for Updates", notes)
        self.assertNotIn("## [0.1.0]", notes)
        self.assertNotIn("[Unreleased]:", notes)
        with self.assertRaises(ValueError):
            version.release_notes("99.0.0", self.root)
