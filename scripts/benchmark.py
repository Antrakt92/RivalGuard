"""Measure a deterministic simulated domain workload; this is not an in-game benchmark."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=20000)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--lua", default=shutil.which("lua5.1"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.lua or not 100 <= args.iterations <= 1000000 or not 1 <= args.runs <= 20 or not 1 <= args.seed < 2147483647:
        parser.error("Require Lua 5.1, 100..1000000 iterations, 1..20 runs and a valid positive seed")
    version = subprocess.run([args.lua, "-v"], capture_output=True, text=True, check=False)
    if version.returncode or "Lua 5.1" not in version.stdout + version.stderr:
        parser.error("Expected Lua 5.1 executable")
    inputs = [*sorted((ROOT / "Core").glob("*.lua")), ROOT / "tests/workload.lua", ROOT / "tests/support/harness.lua"]
    def source_digest():
        digest = hashlib.sha256()
        for source in inputs:
            digest.update(source.relative_to(ROOT).as_posix().encode())
            digest.update(b"\0")
            digest.update(source.read_bytes())
            digest.update(b"\0")
        return digest.hexdigest()

    source_hash = source_digest()
    samples = []
    for _ in range(args.runs):
        result = subprocess.run([args.lua, str(ROOT / "tests/workload.lua"), str(ROOT), str(args.iterations), str(args.seed)], capture_output=True, text=True, check=False)
        if result.returncode:
            parser.exit(1, f"Workload failed:\n{result.stdout}{result.stderr}")
        samples.append(json.loads(result.stdout))
    if source_digest() != source_hash:
        parser.exit(1, "Source changed during workload measurement; rerun after writers settle.\n")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=False)
    dirty = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ROOT, capture_output=True, text=True, check=False)
    report = {
        "timestampUTC": datetime.now(timezone.utc).isoformat(),
        "scope": "Synthetic Engine Observe/Remove/Tick/Snapshot workload in standalone Lua 5.1",
        "limitations": "Excludes native WoW API cost, native taint/secret behavior, rendering, game CPU contention and real player detection; no competitor comparison.",
        "sourceSHA256": source_hash, "gitRevision": revision.stdout.strip() if revision.returncode == 0 else None,
        "trackedSourceDirty": bool(dirty.stdout.strip()), "seed": args.seed,
        "medianCPUSeconds": statistics.median(sample["cpuSeconds"] for sample in samples),
        "samples": samples,
    }
    text = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    main()
