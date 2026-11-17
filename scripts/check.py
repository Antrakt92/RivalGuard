"""Run local Lua 5.1, behavioral, metadata and packaging checks."""

from __future__ import annotations

import argparse
import ast
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from package import ADDON, ROOT, build, package_inputs
from package import ASSET_TYPES
from check_package import smoke


def fingerprint() -> str:
    digest = hashlib.sha256()
    excluded = {".git", "dist", "__pycache__", ".pytest_cache"}
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or any(part in excluded for part in path.relative_to(ROOT).parts):
            continue
        if path.suffix.lower() not in {".lua", ".py", ".toc"} | ASSET_TYPES and path.name not in {"LICENSE", "README.md", "CHANGELOG.md"}:
            continue
        digest.update(path.relative_to(ROOT).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def run(command: list[str], root: Path = ROOT, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(command, cwd=root, env=env, check=False)
    if result.returncode:
        raise RuntimeError(f"Check exited {result.returncode}: {command[0]}")


def tool(name: str, override: str | None) -> str:
    found = override or shutil.which(name)
    if not found:
        raise RuntimeError(f"Required tool missing: {name}; use its explicit command-line option")
    return str(Path(found).resolve()) if Path(found).is_file() else found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", help="Path to Lua 5.1 executable")
    parser.add_argument("--luac", help="Path to Lua 5.1 compiler")
    parser.add_argument("--core-only", action="store_true", help="Run existing Lua suites before client manifests are authored")
    args = parser.parse_args()
    try:
        before = fingerprint()
        lua, luac = tool("lua5.1", args.lua), tool("luac5.1", args.luac)
        for executable in (lua, luac):
            result = subprocess.run([executable, "-v"], capture_output=True, text=True, check=False)
            if result.returncode or "Lua 5.1" not in result.stdout + result.stderr:
                raise RuntimeError(f"Expected Lua 5.1: {executable}")
        source_files = sorted(path for path in ROOT.rglob("*.lua") if ".git" not in path.parts and "dist" not in path.parts)
        for source in source_files:
            run([luac, "-p", str(source)])
        for source in sorted(ROOT.rglob("*.py")):
            if ".git" not in source.parts and "dist" not in source.parts:
                ast.parse(source.read_text(encoding="utf-8-sig"), filename=str(source))
        suites = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "tests").glob("test_*.lua"))
        if not suites:
            raise RuntimeError("No behavioral suites found")
        run([lua, str(ROOT / "tests/run.lua"), str(ROOT), *suites])
        python_suites = sorted((ROOT / "tests").glob("test_*.py"))
        if python_suites:
            run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"], env={**os.environ, "RIVALGUARD_TEST_LUA": lua})
        if not args.core_only:
            version, files = package_inputs(ROOT)
            bootstrap = (ROOT / "Core/Bootstrap.lua").read_text(encoding="utf-8-sig")
            runtime_version = re.search(r'RG\.version\s*=\s*"([^"]+)"', bootstrap)
            if not runtime_version or runtime_version.group(1) != version:
                raise RuntimeError("Bootstrap and client manifests disagree on version")
            declared = {name for name in files if name.endswith(".lua")}
            runtime = {path.relative_to(ROOT).as_posix() for path in source_files if path.parts[len(ROOT.parts)] != "tests"}
            if runtime != declared:
                raise RuntimeError(f"Runtime/manifest mismatch: undeclared={sorted(runtime - declared)}, missing={sorted(declared - runtime)}")
            with tempfile.TemporaryDirectory(prefix="rivalguard-check-") as directory:
                output = Path(directory)
                first, digest = build(ROOT, output / "first")
                second, repeated = build(ROOT, output / "second")
                if digest != repeated or first.read_bytes() != second.read_bytes():
                    raise RuntimeError("Package is not reproducible")
                smoke(first, lua)
                print(f"Package {ADDON}-{version}: {len(files)} files; reproducible SHA256 {digest}")
        if fingerprint() != before:
            raise RuntimeError("Source changed during verification; rerun after writers settle")
        print(f"Checks passed: {len(source_files)} Lua files, {len(suites)} Lua suites")
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Check failed: {error}\n")


if __name__ == "__main__":
    main()
