#!/usr/bin/env python3
"""CPU-time comparison: pinned Taffy (Rust) vs Zig port.

The host is shared and wall-clock benchmarks are dominated by descheduling.
This runner measures each harness scenario as a separate child process and
reports the child's user+sys CPU time from getrusage(RUSAGE_CHILDREN), which
is immune to contention. Best-of-N per scenario (CPU time only varies with
frequency scaling and actual work, not scheduling).

Usage:
    python3 tools/bench/cpu_compare.py --zig-bin /path/to/bench [--repeat 3] [--filter flex]
"""

from __future__ import annotations

import argparse
import resource
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUST_BIN = HERE / "rust" / "target" / "release" / "zlay-bench-rust"

SCENARIOS = [
    "tree_creation_10k",
    "flex_row_1000",
    "flex_wrap_500",
    "grid_50x50",
    "block_nested_50",
    "mixed_flex_grid_block",
]


def run_child(command: list[str]) -> float:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if proc.returncode != 0:
        raise SystemExit(f"failed ({proc.returncode}): {' '.join(command)}")
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)


def best(command: list[str], repeat: int) -> float:
    return min(run_child(command) for _ in range(repeat))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig-bin", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--filter")
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    prefix = ["taskset", "-c", str(args.cpu)]
    scenarios = [s for s in SCENARIOS if not args.filter or args.filter in s]

    if not RUST_BIN.exists():
        manifest = HERE / "rust" / "Cargo.toml"
        print(f"building Rust mirror (missing {RUST_BIN})...", file=sys.stderr)
        subprocess.run(
            ["cargo", "build", "--release", "--quiet", "--manifest-path", str(manifest)],
            check=True,
        )

    lines = [
        "CPU-time benchmark (user+sys, best of %d, pinned CPU %d)" % (args.repeat, args.cpu),
        "ratio = port / taffy; < 1.0 means the port is faster",
        "",
        f"{'scenario':28s} {'taffy_ms':>10s} {'port_ms':>10s} {'ratio':>7s}",
        "-" * 60,
    ]
    ratios = []
    for name in scenarios:
        t = best(prefix + [str(RUST_BIN), "--filter", name], args.repeat) * 1000.0
        p = best(prefix + [str(args.zig_bin), "--filter", name], args.repeat) * 1000.0
        ratio = p / t
        ratios.append(ratio)
        marker = "  <-- faster" if ratio < 1.0 else ("  <-- slower" if ratio > 1.05 else "")
        lines.append(f"{name:28s} {t:10.2f} {p:10.2f} {ratio:6.2f}x{marker}")
    geometric = 1.0
    for ratio in ratios:
        geometric *= ratio
    geometric **= 1.0 / len(ratios) if ratios else 1.0
    lines += ["", f"geometric mean ratio: {geometric:.3f}x ({len(ratios)} scenarios)"]

    table = "\n".join(lines)
    print(table)
    if args.out:
        args.out.write_text(table + "\n")
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
