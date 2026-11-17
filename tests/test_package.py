"""Exercise packaging against disposable source fixtures, including unsafe inputs."""

from pathlib import Path
import sys
import tempfile
import unittest
from zipfile import ZipFile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from package import build, package_inputs, toc_entries  # noqa: E402


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rivalguard-package-test-")
        self.root = Path(self.directory.name)
        (self.root / "Core").mkdir()
        (self.root / "Core/Bootstrap.lua").write_text("local addon, namespace = ...\n", encoding="utf-8")
        (self.root / "LICENSE").write_text("Fixture license\n", encoding="utf-8")
        (self.root / "README.md").write_text("Fixture help\n", encoding="utf-8")
        self.toc = self.root / "RivalGuard.toc"
        self.write_toc()

    def tearDown(self):
        self.directory.cleanup()

    def write_toc(self, entries="Core/Bootstrap.lua", version="0.1.0-dev"):
        self.toc.write_text(
            "## Interface: 120000\n## Title: RivalGuard\n"
            f"## Version: {version}\n## SavedVariables: RivalGuardDB\n{entries}\n",
            encoding="utf-8",
        )

    def test_reproducible_archive_reads_back_exact_source_and_only_allowed_files(self):
        (self.root / "tests").mkdir()
        (self.root / "tests/private.lua").write_text("excluded", encoding="utf-8")
        (self.root / ".env").write_text("excluded", encoding="utf-8")
        (self.root / "Media").mkdir()
        (self.root / "Media/icon.tga").write_bytes(b"image fixture")
        (self.root / "Media/source.psd").write_bytes(b"working file")
        first, first_hash = build(self.root, self.root / "output-a")
        second, second_hash = build(self.root, self.root / "output-b")
        self.assertEqual(first_hash, second_hash)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), [
                "RivalGuard/Core/Bootstrap.lua", "RivalGuard/LICENSE",
                "RivalGuard/Media/icon.tga", "RivalGuard/README.md", "RivalGuard/RivalGuard.toc",
            ])
            self.assertEqual(archive.read("RivalGuard/Core/Bootstrap.lua"), (self.root / "Core/Bootstrap.lua").read_bytes())

    def test_traversal_absolute_and_nonruntime_entries_are_rejected(self):
        for entry in ("../outside.lua", "Core/../outside.lua", "/Core/Bootstrap.lua", "tests/private.lua", "C:/outside.lua"):
            with self.subTest(entry=entry):
                self.write_toc(entries=entry)
                with self.assertRaises(ValueError):
                    package_inputs(self.root)

    def test_missing_and_case_duplicate_modules_are_rejected(self):
        self.write_toc(entries="Core/Missing.lua")
        with self.assertRaisesRegex(ValueError, "Missing runtime"):
            package_inputs(self.root)
        self.write_toc(entries="Core/Bootstrap.lua\nCore/bootstrap.lua")
        with self.assertRaisesRegex(ValueError, "Duplicate runtime"):
            package_inputs(self.root)

    def test_duplicate_metadata_and_client_version_drift_are_rejected(self):
        self.toc.write_text(self.toc.read_text(encoding="utf-8") + "## Version: 0.2.0\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Duplicate Version"):
            toc_entries(self.toc)
        self.write_toc()
        other = self.root / "RivalGuard_Forever.toc"
        other.write_text(self.toc.read_text(encoding="utf-8").replace("0.1.0-dev", "0.2.0-dev"), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "disagree"):
            package_inputs(self.root)

    def test_wrong_version_interface_and_saved_variables_fail_closed(self):
        original = self.toc.read_text(encoding="utf-8")
        for text in (
            original.replace("0.1.0-dev", "latest"),
            original.replace("120000", "unknown"),
            original.replace("RivalGuardDB", "OtherDB"),
        ):
            self.toc.write_text(text, encoding="utf-8")
            with self.assertRaises(ValueError):
                package_inputs(self.root)

    def test_wrong_output_filename_does_not_write_archive(self):
        output = self.root / "wrong.zip"
        with self.assertRaisesRegex(ValueError, "Expected archive"):
            build(self.root, output)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
