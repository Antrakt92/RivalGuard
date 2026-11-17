"""Build and verify a reproducible RivalGuard addon archive (Python standard library)."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import tempfile
from xml.etree import ElementTree
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
ADDON = "RivalGuard"
BINDING_ACTIONS = {
    "RIVALGUARD_TOGGLE_NEARBY": "nearby",
    "RIVALGUARD_TOGGLE_PAUSE": "pause",
    "RIVALGUARD_TOGGLE_MUTE": "mute",
    "RIVALGUARD_HIGHLIGHT_ALERT": "highlight",
}
ASSET_TYPES = {".tga", ".blp", ".png", ".jpg", ".jpeg", ".ogg", ".mp3", ".wav", ".ttf", ".otf"}
RUNTIME_ROOTS = {"Core", "Runtime", "UI", "Locale", "Locales", "Data", "Adapters"}
ICON_TYPES = {".tga", ".blp"}
DOS_DEVICES = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}


def portable_parts(path: str) -> list[str]:
    parts = path.split("/")
    for part in parts:
        if (
            not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", part)
            or part.endswith(".")
            or part.split(".", 1)[0].upper() in DOS_DEVICES
        ):
            raise ValueError(f"Unsafe or unsupported package path: {path}")
    return parts


def linked(path: Path) -> bool:
    return path.is_symlink() or getattr(path, "is_junction", lambda: False)()


def exact_source(root: Path, path: str) -> Path:
    source = root
    for part in portable_parts(path):
        if part not in {entry.name for entry in source.iterdir()}:
            raise ValueError(f"Missing package input or filename case mismatch: {path}")
        source = source / part
        if linked(source):
            raise ValueError(f"Unsupported symlink or directory junction: {path}")
    if not source.is_file():
        raise ValueError(f"Package input is not a file: {path}")
    return source


def manifests(root: Path) -> list[Path]:
    result = sorted(root.glob(f"{ADDON}*.toc"))
    if not result or root / f"{ADDON}.toc" not in result:
        raise ValueError(f"Missing {ADDON}.toc")
    return [exact_source(root, toc.name) for toc in result]


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
            parts = portable_parts(path)
            if (
                not path.endswith(".lua")
                or (parts[0] not in RUNTIME_ROOTS and path != "Runtime.lua")
            ):
                raise ValueError(f"Unsafe or unsupported runtime path in {toc.name}: {line}")
            if path.casefold() in {item.casefold() for item in entries}:
                raise ValueError(f"Duplicate runtime path in {toc.name}: {path}")
            entries.append(path)
    if not entries:
        raise ValueError(f"No runtime modules in {toc.name}")
    return metadata, entries


def interfaces(metadata: dict[str, str], toc_name: str) -> list[int]:
    value = metadata.get("Interface", "")
    if not re.fullmatch(r"[1-9][0-9]{0,6}(?:\s*,\s*[1-9][0-9]{0,6})*", value):
        raise ValueError(f"Invalid Interface in {toc_name}")
    result = [int(item) for item in value.split(",")]
    if len(result) != len(set(result)):
        raise ValueError(f"Duplicate Interface in {toc_name}")
    return result


def source_tree(root: Path, folder: Path):
    for entry in sorted(folder.iterdir()):
        if entry.name.startswith("."):
            continue
        if linked(entry):
            raise ValueError(f"Unsupported symlink or directory junction: {entry.relative_to(root)}")
        if entry.is_dir():
            yield from source_tree(root, entry)
        elif entry.is_file():
            yield entry


def inspect_icon(value: str, files: dict[str, bytes], toc_name: str) -> None:
    prefix = f"Interface/AddOns/{ADDON}/"
    path = value.replace("\\", "/")
    if not path.startswith(prefix):
        raise ValueError(f"Invalid IconTexture in {toc_name}")
    relative = path[len(prefix):]
    if portable_parts(relative)[0] != "Media":
        raise ValueError(f"IconTexture must name a Media asset in {toc_name}")
    suffix = PurePosixPath(relative).suffix
    candidates = [relative] if suffix in ICON_TYPES else [relative + ext for ext in sorted(ICON_TYPES)] if not suffix else []
    if sum(candidate in files for candidate in candidates) != 1:
        raise ValueError(f"IconTexture missing or ambiguous in {toc_name}: {relative}")


def binding_bodies(data: bytes) -> list[str]:
    try:
        text = data.decode("utf-8-sig")
        if "<!DOCTYPE" in text:
            raise ValueError("Bindings.xml cannot define a document type")
        root = ElementTree.fromstring(text)
    except (ElementTree.ParseError, UnicodeError) as error:
        raise ValueError(f"Invalid Bindings.xml: {error}") from error
    if root.tag != "Bindings" or root.attrib or (root.text or "").strip():
        raise ValueError("Invalid Bindings.xml root")

    names: set[str] = set()
    bodies: list[str] = []
    for binding in root:
        name = binding.get("name", "")
        command = BINDING_ACTIONS.get(name)
        body = (binding.text or "").strip()
        if (
            binding.tag != "Binding"
            or binding.attrib != {"name": name, "category": "BINDING_HEADER_RIVALGUARD"}
            or not command
            or name in names
            or len(binding) != 0
            or body != f'RivalGuard_Binding("{command}")'
            or (binding.tail or "").strip()
        ):
            raise ValueError("Invalid or duplicate action in Bindings.xml")
        names.add(name)
        bodies.append(body)
    if names != BINDING_ACTIONS.keys():
        raise ValueError("Missing action in Bindings.xml")
    return bodies


def package_inputs(root: Path) -> tuple[str, dict[str, bytes]]:
    files: dict[str, bytes] = {}
    versions: set[str] = set()
    icons: dict[str, str] = {}
    for toc in manifests(root):
        metadata, entries = toc_entries(toc)
        version = metadata.get("Version", "")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
            raise ValueError(f"Invalid Version in {toc.name}")
        interfaces(metadata, toc.name)
        if metadata.get("SavedVariables") != "RivalGuardDB":
            raise ValueError(f"Unexpected SavedVariables in {toc.name}")
        versions.add(version)
        icons[toc.name] = metadata.get("IconTexture", "")
        files[toc.name] = toc.read_bytes()
        for entry in entries:
            files[entry] = exact_source(root, entry).read_bytes()
    if len(versions) != 1:
        raise ValueError("Client manifests disagree on version")
    for name in ("Bindings.xml", "LICENSE", "README.md"):
        files[name] = exact_source(root, name).read_bytes()
    binding_bodies(files["Bindings.xml"])
    if (root / "CHANGELOG.md").exists() or linked(root / "CHANGELOG.md"):
        files["CHANGELOG.md"] = exact_source(root, "CHANGELOG.md").read_bytes()
    for folder_name in sorted(RUNTIME_ROOTS | {"Media"}):
        folder = root / folder_name
        if linked(folder):
            raise ValueError(f"Unsupported symlink or directory junction: {folder_name}")
        if not folder.is_dir():
            continue
        for source in source_tree(root, folder):
            relative = source.relative_to(root).as_posix()
            if folder_name != "Media":
                if source.suffix.lower() == ".lua" and relative not in files:
                    raise ValueError(f"Runtime module missing from manifests: {relative}")
            elif source.suffix.lower() in ASSET_TYPES:
                portable_parts(relative)
                if source.stat().st_size > 8 * 1024 * 1024:
                    raise ValueError(f"Oversized media asset: {relative}")
                files[relative] = source.read_bytes()
    if (root / "Runtime.lua").exists() and "Runtime.lua" not in files:
        raise ValueError("Runtime module missing from manifests: Runtime.lua")
    for toc_name, icon in icons.items():
        inspect_icon(icon, files, toc_name)
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
