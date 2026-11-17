"""Verify a ZIP byte-for-byte against source and exercise the extracted addon in Lua 5.1."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
from zipfile import BadZipFile, ZipFile

from package import ADDON, ROOT, binding_bodies, interfaces, package_inputs, toc_entries


def verify_archive(root: Path, archive: Path, destination: Path) -> list[tuple[str, int]]:
    version, expected = package_inputs(root)
    if archive.name != f"{ADDON}-{version}.zip":
        raise ValueError(f"Expected archive name {ADDON}-{version}.zip")
    extracted: dict[str, bytes] = {}
    names = {f"{ADDON}/{path}": path for path in expected}
    with ZipFile(archive) as bundle:
        entries = bundle.infolist()
        actual = [entry.filename for entry in entries]
        if len(actual) != len(set(actual)) or set(actual) != names.keys():
            raise ValueError("Archive contents differ from the source manifest or contain duplicate paths")
        for entry in entries:
            name = names[entry.filename]
            data = expected[name]
            if entry.is_dir() or stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size != len(data):
                raise ValueError(f"Archive entry type or length differs from source: {name}")
            payload = bundle.read(entry)
            if payload != data:
                raise ValueError(f"Archive bytes differ from source: {name}")
            extracted[name] = payload
    # Use approved paths and the archive payload in a new temporary directory.
    for name, data in extracted.items():
        target = destination / ADDON / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    matrix = []
    for name in expected:
        if "/" not in name and name.endswith(".toc"):
            metadata, _ = toc_entries(destination / ADDON / name)
            matrix.extend((name, interface) for interface in interfaces(metadata, name))
    return matrix


def smoke(archive: Path, lua: str, root: Path = ROOT) -> None:
    with tempfile.TemporaryDirectory(prefix="rivalguard-archive-smoke-") as directory:
        destination = Path(directory)
        matrix = verify_archive(root, archive, destination)
        package_root = destination / ADDON
        bindings = binding_bodies((package_root / "Bindings.xml").read_bytes())
        for manifest, interface in matrix:
            subprocess.run(
                [lua, str(root / "tests/package_smoke.lua"), str(package_root), str(root), manifest, str(interface), *bindings],
                cwd=destination, check=True,
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--lua", default=shutil.which("lua5.1"))
    args = parser.parse_args()
    if not args.lua:
        parser.error("Lua 5.1 is required")
    lua = shutil.which(args.lua)
    if not lua:
        parser.error("Lua 5.1 executable not found")
    try:
        version = subprocess.run([lua, "-v"], capture_output=True, text=True, check=True)
        if "Lua 5.1" not in version.stdout + version.stderr:
            raise ValueError("Expected a Lua 5.1 executable")
        smoke(args.archive.resolve(), lua)
    except (OSError, ValueError, BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Archive check failed: {error}\n")


if __name__ == "__main__":
    main()
