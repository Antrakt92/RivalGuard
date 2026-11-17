"""Build and verify a reproducible RivalGuard addon archive (Python standard library)."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
ADDON = "RivalGuard"
ASSET_TYPES = {".tga", ".blp", ".png", ".jpg", ".jpeg", ".ogg", ".mp3", ".wav", ".ttf", ".otf"}
RUNTIME_ROOTS = {"Core", "Runtime", "UI", "Locale", "Locales", "Data", "Adapters"}


def manifests(root: Path) -> list[Path]:
    result = sorted(root.glob(f"{ADDON}*.toc"))
    if not result or root / f"{ADDON}.toc" not in result:
        raise ValueError(f"Missing {ADDON}.toc")
    return result


def toc_entries(toc: Path) -> tuple[dict[str, str], list[str]]:
    metadata: dict[str, str] = {}
    entries: list[str] = []
    for raw in toc.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if line.startswith("##"):
            key, separator, value = line[2:].partition(":")
            if separator:
                key = key.strip()
                if key in metadata:
                    raise ValueError(f"Duplicate {key} metadata in {toc.name}")
                metadata[key] = value.strip()
        elif line and not line.startswith("#"):
            path = line.replace("\\", "/")
            parts = PurePosixPath(path).parts
            if (
                not re.fullmatch(r"[A-Za-z0-9_./-]+\.lua", path)
                or ".." in parts
                or path.startswith("/")
                or not parts
                or (parts[0] not in RUNTIME_ROOTS and path != "Runtime.lua")
            ):
                raise ValueError(f"Unsafe or unsupported runtime path in {toc.name}: {line}")
            if path.casefold() in {item.casefold() for item in entries}:
                raise ValueError(f"Duplicate runtime path in {toc.name}: {path}")
            entries.append(path)
    if not entries:
        raise ValueError(f"No runtime modules in {toc.name}")
    return metadata, entries


def package_inputs(root: Path) -> tuple[str, dict[str, bytes]]:
    files: dict[str, bytes] = {}
    versions: set[str] = set()
    for toc in manifests(root):
        metadata, entries = toc_entries(toc)
        version = metadata.get("Version", "")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
            raise ValueError(f"Invalid Version in {toc.name}")
        if not re.fullmatch(r"[0-9]+(?:\s*,\s*[0-9]+)*", metadata.get("Interface", "")):
            raise ValueError(f"Invalid Interface in {toc.name}")
        if metadata.get("SavedVariables") != "RivalGuardDB":
            raise ValueError(f"Unexpected SavedVariables in {toc.name}")
        versions.add(version)
        files[toc.name] = toc.read_bytes()
        for entry in entries:
            source = root / entry
            if not source.is_file() or source.is_symlink():
                raise ValueError(f"Missing runtime module or unsupported symlink: {entry}")
            if not source.resolve().is_relative_to(root.resolve()):
                raise ValueError(f"Runtime module escapes repository: {entry}")
            files[entry] = source.read_bytes()
    if len(versions) != 1:
        raise ValueError("Client manifests disagree on version")
    for name in ("LICENSE", "README.md"):
        if not (root / name).is_file():
            raise ValueError(f"Missing {name}")
        files[name] = (root / name).read_bytes()
    if (root / "CHANGELOG.md").is_file():
        files["CHANGELOG.md"] = (root / "CHANGELOG.md").read_bytes()
    media = root / "Media"
    if media.exists():
        for source in sorted(media.rglob("*")):
            relative = source.relative_to(root)
            if any(part.startswith(".") for part in relative.parts):
                continue
            if source.is_file() and source.suffix.lower() in ASSET_TYPES:
                if source.is_symlink() or not source.resolve().is_relative_to(root.resolve()):
                    raise ValueError(f"Media path escapes repository: {relative}")
                if source.stat().st_size > 8 * 1024 * 1024:
                    raise ValueError(f"Oversized media asset: {relative}")
                files[relative.as_posix()] = source.read_bytes()
    folded = [name.casefold() for name in files]
    if len(folded) != len(set(folded)):
        raise ValueError("Package has case-insensitive path collisions")
    return versions.pop(), dict(sorted(files.items()))


def build(root: Path, output: Path) -> tuple[Path, str]:
    version, files = package_inputs(root)
    expected_name = f"{ADDON}-{version}.zip"
    archive = output / expected_name if output.suffix.lower() != ".zip" else output
    if archive.name != expected_name:
        raise ValueError(f"Expected archive filename {expected_name}")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rivalguard-package-", dir=archive.parent) as staging:
        candidate = Path(staging) / archive.name
        with ZipFile(candidate, "w", compression=ZIP_DEFLATED, compresslevel=9) as bundle:
            for name, data in files.items():
                entry = ZipInfo(f"{ADDON}/{name}", date_time=(2020, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                bundle.writestr(entry, data, compress_type=ZIP_DEFLATED, compresslevel=9)
        with ZipFile(candidate) as bundle:
            expected = [f"{ADDON}/{name}" for name in files]
            if bundle.namelist() != expected or bundle.testzip() is not None:
                raise RuntimeError("Archive structure or CRC validation failed")
            for name, data in files.items():
                if bundle.read(f"{ADDON}/{name}") != data:
                    raise RuntimeError(f"Archive source mismatch: {name}")
        candidate.replace(archive)
    return archive, hashlib.sha256(archive.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    try:
        archive, digest = build(ROOT, args.output.resolve())
    except (ValueError, OSError, RuntimeError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(archive)
    print(f"SHA256 {digest}")


if __name__ == "__main__":
    main()
