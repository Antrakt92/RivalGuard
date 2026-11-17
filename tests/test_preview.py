"""Verify scene export from the actual addon UI and geometry rendering."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from xml.etree import ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from render_preview import ROOT, Scene, svg  # noqa: E402


class PreviewTests(unittest.TestCase):
    def test_rules_and_import_export_actual_geometry_without_recursive_frame_fields(self):
        lua = os.environ.get("RIVALGUARD_TEST_LUA") or shutil.which("lua5.1")
        self.assertIsNotNone(lua, "Lua 5.1 is required for preview regression")
        for view, window in (("rules", "RivalGuardRules"), ("import", "RivalGuardTransfer")):
            with self.subTest(view=view):
                result = subprocess.run(
                    [lua, str(ROOT / "tests/preview.lua"), str(ROOT), "ruRU", view, "alerts", "1280", "720", "1.25", "contrast"],
                    capture_output=True, text=True, encoding="utf-8", check=True,
                )
                raw = json.loads(result.stdout)
                self.assertTrue(raw["meta"]["simulation"])
                frames = [frame for frame in raw["frames"] if frame["visible"]]
                self.assertTrue(any(frame.get("name") == window for frame in frames))
                self.assertTrue(all(type(frame.get("enabled")) in {bool, type(None)} for frame in frames))
                self.assertTrue(any(frame.get("enabled") is False for frame in frames))
                scene = Scene(raw)
                parsed = ElementTree.fromstring(svg(scene))
                self.assertEqual(parsed.attrib["viewBox"], "0 0 1280 720")
                self.assertFalse(scene.warnings)


if __name__ == "__main__":
    unittest.main()
