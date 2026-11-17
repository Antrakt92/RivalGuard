"""Exercise packaging against disposable source fixtures, including unsafe inputs."""

from pathlib import Path
import sys
import tempfile
import unittest
import warnings
from zipfile import ZipFile, ZipInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from package import build, package_inputs, toc_entries  # noqa: E402
from check_package import verify_archive  # noqa: E402


BINDINGS_XML = """<Bindings>
    <Binding name="RIVALGUARD_TOGGLE_NEARBY" category="BINDING_HEADER_RIVALGUARD">
        RivalGuard_Binding("nearby")
    </Binding>
    <Binding name="RIVALGUARD_TOGGLE_PAUSE" category="BINDING_HEADER_RIVALGUARD">
        RivalGuard_Binding("pause")
    </Binding>
    <Binding name="RIVALGUARD_TOGGLE_MUTE" category="BINDING_HEADER_RIVALGUARD">
        RivalGuard_Binding("mute")
    </Binding>
</Bindings>
"""


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rivalguard-package-test-")
        self.root = Path(self.directory.name)
        (self.root / "Core").mkdir()
        (self.root / "Core/Bootstrap.lua").write_text("local addon, namespace = ...\n", encoding="utf-8")
        (self.root / "LICENSE").write_text("Fixture license\n", encoding="utf-8")
        (self.root / "README.md").write_text("Fixture help\n", encoding="utf-8")
        (self.root / "Media").mkdir()
        (self.root / "Media/Icon.tga").write_bytes(b"image fixture")
        self.bindings = self.root / "Bindings.xml"
        self.bindings.write_text(BINDINGS_XML, encoding="utf-8")
        self.toc = self.root / "RivalGuard.toc"
        self.write_toc()

    def tearDown(self):
        self.directory.cleanup()

    def write_toc(self, entries="Core/Bootstrap.lua", version="0.1.0-dev"):
        self.toc.write_text(
            "## Interface: 120000\n## Title: RivalGuard\n"
            f"## Version: {version}\n## SavedVariables: RivalGuardDB\n"
            f"## IconTexture: Interface\\AddOns\\RivalGuard\\Media\\Icon\n{entries}\n",
            encoding="utf-8",
        )

    def test_reproducible_archive_reads_back_exact_source_and_only_allowed_files(self):
        (self.root / "tests").mkdir()
        (self.root / "tests/private.lua").write_text("excluded", encoding="utf-8")
        (self.root / ".env").write_text("excluded", encoding="utf-8")
        (self.root / "Media/source.psd").write_bytes(b"working file")
        first, first_hash = build(self.root, self.root / "output-a")
        second, second_hash = build(self.root, self.root / "output-b")
        self.assertEqual(first_hash, second_hash)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with ZipFile(first) as archive:
            self.assertEqual(archive.namelist(), [
                "RivalGuard/Bindings.xml", "RivalGuard/Core/Bootstrap.lua", "RivalGuard/LICENSE",
                "RivalGuard/Media/Icon.tga", "RivalGuard/README.md", "RivalGuard/RivalGuard.toc",
            ])
            self.assertEqual(archive.read("RivalGuard/Bindings.xml"), self.bindings.read_bytes())
            self.assertEqual(archive.read("RivalGuard/Core/Bootstrap.lua"), (self.root / "Core/Bootstrap.lua").read_bytes())

    def test_native_binding_file_has_exact_case_and_is_not_loaded_through_toc(self):
        self.bindings.unlink()
        with self.assertRaisesRegex(ValueError, "Missing package input.*Bindings.xml"):
            package_inputs(self.root)
        (self.root / "bindings.xml").write_text(BINDINGS_XML, encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "filename case mismatch.*Bindings.xml"):
            package_inputs(self.root)
        self.write_toc(entries="Bindings.xml\nCore/Bootstrap.lua")
        with self.assertRaisesRegex(ValueError, "unsupported runtime path.*Bindings.xml"):
            package_inputs(self.root)

    def test_native_binding_file_rejects_extra_actions_defaults_and_scripting(self):
        for text in (
            BINDINGS_XML.replace("RIVALGUARD_TOGGLE_MUTE", "RIVALGUARD_TOGGLE_PAUSE"),
            BINDINGS_XML.replace("RIVALGUARD_TOGGLE_MUTE", "ANOTHER_ACTION"),
            BINDINGS_XML.replace("RIVALGUARD_TOGGLE_MUTE\"", "RIVALGUARD_TOGGLE_MUTE\" key=\"K\""),
            BINDINGS_XML.replace("BINDING_HEADER_RIVALGUARD", "BINDING_HEADER_INTERFACE"),
            BINDINGS_XML.replace('RivalGuard_Binding("mute")', 'RivalGuard_Binding("pause")'),
            BINDINGS_XML.replace('RivalGuard_Binding("mute")', 'RivalGuard_Binding("mute"); OtherCall()'),
            BINDINGS_XML.replace('RivalGuard_Binding("mute")', '<Script>RivalGuard_Binding("mute")</Script>'),
            "<Bindings/>",
            BINDINGS_XML.replace("</Bindings>", ""),
            '<!DOCTYPE Bindings [<!ENTITY example "example">]>\n' + BINDINGS_XML,
        ):
            with self.subTest(text=text):
                self.bindings.write_text(text, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "Bindings.xml"):
                    package_inputs(self.root)

    def test_traversal_absolute_and_nonruntime_entries_are_rejected(self):
        for entry in ("../outside.lua", "Core/../outside.lua", "/Core/Bootstrap.lua", "tests/private.lua", "C:/outside.lua", "Core/./Bootstrap.lua", "Core//Bootstrap.lua", "Core/NUL.lua"):
            with self.subTest(entry=entry):
                self.write_toc(entries=entry)
                with self.assertRaises(ValueError):
                    package_inputs(self.root)

    def test_missing_and_case_duplicate_modules_are_rejected(self):
        self.write_toc(entries="Core/Missing.lua")
        with self.assertRaisesRegex(ValueError, "Missing package input"):
            package_inputs(self.root)
        self.write_toc(entries="Core/Bootstrap.lua\nCore/bootstrap.lua")
        with self.assertRaisesRegex(ValueError, "Duplicate runtime"):
            package_inputs(self.root)

    def test_missing_icon_duplicate_icon_and_case_mismatch_fail(self):
        (self.root / "Media/Icon.blp").write_bytes(b"other texture")
        with self.assertRaisesRegex(ValueError, "IconTexture missing or ambiguous"):
            package_inputs(self.root)
        (self.root / "Media/Icon.blp").unlink()
        self.toc.write_text(self.toc.read_text(encoding="utf-8").replace("Media\\Icon", "Media\\ICON"), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "IconTexture missing or ambiguous"):
            package_inputs(self.root)
        self.write_toc(entries="Core/bootstrap.lua")
        with self.assertRaisesRegex(ValueError, "filename case mismatch"):
            package_inputs(self.root)

    def test_undeclared_runtime_source_fails_packaging(self):
        (self.root / "Core/Undeclared.lua").write_text("return true", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Runtime module missing from manifests"):
            package_inputs(self.root)

    def test_linked_source_never_enters_package(self):
        symlink = self.root / "Core/Linked.lua"
        try:
            symlink.symlink_to(self.root / "Core/Bootstrap.lua")
        except OSError as error:
            self.skipTest(f"Filesystem does not allow creation of a test symlink: {error}")
        self.write_toc(entries="Core/Linked.lua")
        with self.assertRaisesRegex(ValueError, "Unsupported symlink"):
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
            original.replace("120000", "120000,120000"),
            original.replace("120000", "0"),
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

    def test_archive_load_matrix_and_contents_equal_source(self):
        self.toc.write_text(self.toc.read_text(encoding="utf-8").replace("120000", "120000, 16001"), encoding="utf-8")
        archive, _ = build(self.root, self.root / "out")
        destination = self.root / "extracted"
        self.assertEqual(verify_archive(self.root, archive, destination), [("RivalGuard.toc", 120000), ("RivalGuard.toc", 16001)])
        self.assertEqual((destination / "RivalGuard/Core/Bootstrap.lua").read_bytes(), (self.root / "Core/Bootstrap.lua").read_bytes())
        self.assertEqual((destination / "RivalGuard/Bindings.xml").read_bytes(), self.bindings.read_bytes())

    def test_archive_rejects_duplicate_foreign_type_or_modified_bytes_before_extracting(self):
        _, inputs = package_inputs(self.root)
        archive = self.root / "RivalGuard-0.1.0-dev.zip"
        destination = self.root / "extracted"
        for defect in ("duplicate", "traversal", "symlink", "modified"):
            with self.subTest(defect=defect):
                with ZipFile(archive, "w") as bundle:
                    for name, data in inputs.items():
                        entry = ZipInfo(f"RivalGuard/{name}")
                        if name == "README.md" and defect == "symlink":
                            entry.create_system = 3
                            entry.external_attr = 0o120777 << 16
                        if name == "README.md" and defect == "modified":
                            data = bytes([data[0] ^ 1]) + data[1:]
                        bundle.writestr(entry, data)
                    if defect == "duplicate":
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore", UserWarning)
                            bundle.writestr("RivalGuard/README.md", inputs["README.md"])
                    if defect == "traversal":
                        bundle.writestr("RivalGuard/../escape.lua", b"unsafe")
                with self.assertRaises(ValueError):
                    verify_archive(self.root, archive, destination)
                self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
