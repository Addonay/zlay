#!/usr/bin/env python3
"""Differential parity runner: pinned Taffy (Rust) vs the Zig port.

Runs `tools/parity/rust` (a Cargo oracle against .references/taffy) and
`tools/parity/zig` (the port) over the same hard-coded scenario list, then
compares unrounded node layouts. Lines are `scenario|label|x|y|w|h`.

Usage:
    python3 tools/parity/run.py [--tolerance 0.1] [--strict] [--rust-only] [--zig-only]

Exit status: 0 when every compared node matches within tolerance, 1 otherwise.
Pass --report to always exit 0 (useful while gaps are being fixed).
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent  # package root


def run(command: list[str], cwd: Path) -> str:
    proc = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        raise SystemExit(f"command failed ({proc.returncode}): {' '.join(command)}")
    return proc.stdout


def parse(output: str) -> dict[tuple[str, str], tuple[float, float, float, float]]:
    result: dict[tuple[str, str], tuple[float, float, float, float]] = {}
    for line in output.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 6:
            continue
        scenario, label = parts[0], parts[1]
        try:
            values = tuple(float(v) for v in parts[2:])
        except ValueError:
            continue
        result[(scenario, label)] = values  # type: ignore[assignment]
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tolerance", type=float, default=0.1)
    parser.add_argument("--strict", action="store_true", help="deprecated alias for report-only off")
    parser.add_argument("--report", action="store_true", help="always exit 0 (report-only)")
    parser.add_argument("--rust-only", action="store_true")
    parser.add_argument("--zig-only", action="store_true")
    args = parser.parse_args()

    rust_dir = HERE / "rust"
    zig_dir = HERE / "zig"

    if not (ROOT / ".references" / "taffy" / "Cargo.toml").exists():
        raise SystemExit("missing .references/taffy; run tools/fetch-reference.sh first")

    rust_out = ""
    zig_out = ""
    if not args.zig_only:
        rust_out = run(["cargo", "run", "--quiet"], rust_dir)
    if not args.rust_only:
        zig_out = run(["zig", "build", "run"], zig_dir)

    if args.rust_only:
        print(rust_out, end="")
        return 0
    if args.zig_only:
        print(zig_out, end="")
        return 0

    rust = parse(rust_out)
    zig = parse(zig_out)

    keys = sorted(set(rust) | set(zig))
    mismatches: list[str] = []
    missing: list[str] = []
    for key in keys:
        r = rust.get(key)
        z = zig.get(key)
        if r is None or z is None:
            missing.append(f"{key[0]}|{key[1]}: rust={r} zig={z}")
            continue
        deltas = [abs(a - b) for a, b in zip(r, z)]
        if max(deltas) > args.tolerance:
            mismatches.append(
                f"{key[0]:28s} {key[1]:8s} rust=({r[0]:8.3f},{r[1]:8.3f},{r[2]:8.3f},{r[3]:8.3f})"
                f"  zig=({z[0]:8.3f},{z[1]:8.3f},{z[2]:8.3f},{z[3]:8.3f})"
                f"  max_delta={max(deltas):.3f}"
            )

    scenarios = sorted({k[0] for k in keys})
    print(f"scenarios: {len(scenarios)}, compared nodes: {len(keys)}")
    print(f"matches: {len(keys) - len(mismatches) - len(missing)}, mismatches: {len(mismatches)}, missing: {len(missing)}")
    if missing:
        print("\nMissing rows:")
        for line in missing:
            print(f"  {line}")
    if mismatches:
        print("\nMismatches (tolerance %.3f):" % args.tolerance)
        for line in mismatches:
            print(f"  {line}")

    if args.report:
        return 0
    return 1 if (mismatches or missing) else 0


if __name__ == "__main__":
    raise SystemExit(main())
