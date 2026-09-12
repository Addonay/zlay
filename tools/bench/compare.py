#!/usr/bin/env python3
"""Matched performance comparison: pinned Taffy (Rust) vs the Zig port.

Both harnesses run the same scenarios with the same iteration counts:

    Rust (tools/bench/rust, Cargo profile: opt-level 3 + LTO):
        bench|<scenario>|<iters>|<ns_per_iter>|<peak_live_bytes>
    Zig (tools/bench/main.zig, -Doptimize=ReleaseFast):
        bench|<scenario>|<iters>|<ns_per_iter>|<arena_capacity_bytes>

The fifth field is a memory proxy, not an identical metric: Rust reports peak
live bytes from a counting global allocator; Zig reports the layout arena's
capacity (high-water, retained across iterations). Treat it as an order-of-
magnitude comparison.

Usage (through the build, recommended):
    zig build bench-compare -- --filter flex
    zig build bench-compare -- --strict

Direct usage:
    python3 tools/bench/compare.py --zig-bin /path/to/bench [--filter flex]
    python3 tools/bench/compare.py --rust-only
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent  # package root
RUST_MANIFEST = HERE / "rust" / "Cargo.toml"


def parse(output: str) -> dict[str, tuple[int, int, int]]:
    rows: dict[str, tuple[int, int, int]] = {}
    for line in output.splitlines():
        parts = line.strip().split("|")
        if len(parts) != 5 or parts[0] != "bench":
            continue
        try:
            rows[parts[1]] = (int(parts[2]), int(parts[3]), int(parts[4]))
        except ValueError:
            continue
    return rows


def run_zig(binary: Path, filter_text: str | None, prefix: list[str]) -> dict[str, tuple[int, int, int]]:
    command = prefix + [str(binary)]
    if filter_text:
        command += ["--filter", filter_text]
    proc = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        raise SystemExit(f"zig bench failed ({proc.returncode})")
    return parse(proc.stdout)


def run_rust(filter_text: str | None, prefix: list[str]) -> dict[str, tuple[int, int, int]]:
    command = prefix + ["cargo", "run", "--release", "--quiet", "--manifest-path", str(RUST_MANIFEST)]
    if filter_text:
        command += ["--", "--filter", filter_text]
    proc = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        raise SystemExit(f"rust bench failed ({proc.returncode})")
    return parse(proc.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig-bin", type=Path, help="Zig bench executable (built by the build system)")
    parser.add_argument("--filter", help="scenario-name substring")
    parser.add_argument("--out", type=Path, help="write the table to this file")
    parser.add_argument("--zig-only", action="store_true")
    parser.add_argument("--rust-only", action="store_true")
    parser.add_argument("--strict", action="store_true", help="exit 1 if the port is slower on any scenario")
    parser.add_argument("--tolerance", type=float, default=1.05, help="strict-mode ratio threshold (default 1.05)")
    parser.add_argument("--repeat", type=int, default=1, help="run each harness N times and keep the best ns per scenario")
    parser.add_argument("--cpu", type=int, help="pin both harnesses to this CPU with taskset (reduces scheduler noise)")
    args = parser.parse_args()

    if not RUST_MANIFEST.exists():
        raise SystemExit(f"missing Rust bench manifest: {RUST_MANIFEST}")

    prefix: list[str] = []
    if args.cpu is not None:
        if shutil.which("taskset") is None:
            raise SystemExit("--cpu requires taskset on PATH")
        prefix = ["taskset", "-c", str(args.cpu)]

    def merge(best: dict[str, tuple[int, int, int]], run: dict[str, tuple[int, int, int]]) -> None:
        for name, values in run.items():
            current = best.get(name)
            if current is None or values[1] < current[1]:
                best[name] = values

    taffy: dict[str, tuple[int, int, int]] = {}
    port: dict[str, tuple[int, int, int]] = {}
    for _ in range(max(1, args.repeat)):
        if not args.zig_only:
            merge(taffy, run_rust(args.filter, prefix))
        if not args.rust_only:
            if args.zig_bin is None:
                raise SystemExit("--zig-bin is required unless --rust-only is passed")
            merge(port, run_zig(args.zig_bin, args.filter, prefix))

    if args.rust_only:
        for name, (iters, ns, bytes_) in taffy.items():
            print(f"taffy|{name}|{iters}|{ns}|{bytes_}")
        return 0
    if args.zig_only:
        for name, (iters, ns, bytes_) in port.items():
            print(f"port|{name}|{iters}|{ns}|{bytes_}")
        return 0

    names = sorted(set(taffy) | set(port))
    lines = [
        "Matched benchmark: pinned Taffy (Rust, LTO) vs Zig port (ReleaseFast)",
        "ratio = port_ns / taffy_ns; < 1.0 means the port is faster",
        "",
        f"{'scenario':28s} {'taffy_ns':>12s} {'port_ns':>12s} {'ratio':>7s} {'taffy_bytes':>12s} {'port_bytes':>12s}",
        "-" * 92,
    ]
    regressions: list[str] = []
    ratios: list[float] = []
    for name in names:
        t = taffy.get(name)
        p = port.get(name)
        if t is None or p is None:
            lines.append(f"{name:28s} {'MISSING':>12s} {'MISSING':>12s}")
            continue
        ratio = p[1] / t[1] if t[1] else float("inf")
        ratios.append(ratio)
        marker = ""
        if ratio > args.tolerance:
            regressions.append(f"{name} ({ratio:.2f}x)")
            marker = "  <-- slower"
        elif ratio < 1.0:
            marker = "  <-- faster"
        lines.append(f"{name:28s} {t[1]:12d} {p[1]:12d} {ratio:6.2f}x {t[2]:12d} {p[2]:12d}{marker}")

    if ratios:
        geometric = 1.0
        for ratio in ratios:
            geometric *= ratio
        geometric **= 1.0 / len(ratios)
        lines += ["", f"geometric mean ratio: {geometric:.3f}x ({len(ratios)} scenarios)"]
    if regressions:
        lines += ["", "slower than %0.f%%: %s" % ((args.tolerance - 1.0) * 100.0, ", ".join(regressions))]

    table = "\n".join(lines)
    print(table)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(table + "\n")
        print(f"\nwrote {args.out}")
    if args.strict and regressions:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
