# zlay

A standalone Zig layout engine: a faithful, behavior-verified port of
[Taffy](https://github.com/DioxusLabs/taffy) 0.14 (pinned at
`v0.14.0-7-g1b918ba`). Flexbox, grid, block/float layout, RTL, baselines,
absolute positioning, content sizing, scrollable overflow and
`calc()`-resolved lengths — with Taffy's API shape and semantics.

**Status: behavioral parity with Taffy 0.14, and faster overall in the matched
benchmark suite** (geometric mean ~0.86× Taffy's time in both wall-clock and
CPU-time measurements; block chains 0.57–0.68×, tree creation 0.48–0.62×,
flex/grid largely at parity, mixed workloads 1.08–1.21×).

| Gate | Result |
| --- | --- |
| Taffy generated XML fixtures | **6,084 / 6,084** (incl. scroll extents and resolved grid track lists) |
| Unit tests (`zig build test`) | **87 / 87** (**97 / 97** with `-Dserde=true`) |
| Differential oracle vs real Taffy (`zig build parity`) | **36 / 36 nodes** |
| Matched benchmarks (`zig build bench-compare` / `bench-cpu`) | geomean **0.862×** wall / **0.856×** CPU (port faster; best-of-N, pinned CPU; re-verified **0.958×** CPU on a second host, 2026-09-22 — see report.md §2.4) |
| Taffy `serde` wire format | validated against Rust-generated JSON (`audit/serde_format_rust.txt`) |

The port is checked in file-by-file against the pinned Rust sources; the parity
verdict, evidence and the (non-behavioral) remaining API gaps are documented in
[report.md](report.md). Per-subsystem audit history and raw evidence live under
[`audit/`](audit/).

## Using zlay

```sh
zig fetch --save=zlay <git-url>
```

This pins the package in your `build.zig.zon`; expose its module to a build:

```zig
// build.zig
const zlay = b.dependency("zlay", .{ .target = target, .optimize = optimize });

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zlay", .module = zlay.module("zlay") }},
});
```

```zig
// src/main.zig
const zlay = @import("zlay");

var tree = zlay.TaffyTree.init(allocator);
const root = try tree.new_with_children(
    .{
        .display = .flex,
        .size = .{ .width = zlay.Dimension.length(400), .height = zlay.Dimension.auto },
    },
    &.{ try tree.new_leaf(.{ .size = .{
        .width = zlay.Dimension.length(60),
        .height = zlay.Dimension.length(10),
    } }) },
);
try tree.compute_layout(root, .{ .width = .{ .definite = 400 }, .height = .max_content });
```

Taffy-compatible JSON serde is an optional package feature; enable it at the
dependency call and it is fetched lazily:

```zig
const zlay = b.dependency("zlay", .{
    .target = target,
    .optimize = optimize,
    .serde = true, // compiles `zlay.serde_support`
});
```

## Repository layout

```
build.zig              package build: module, tests, fixtures, parity, audit, bench
build.zig.zon          package manifest (serde is the only, lazy, dependency)
src/                   the port (Taffy-shaped topology)
  root.zig             module entry point
  geometry.zig, style/, tree/, compute/, util/, prelude.zig, ...
  port.md              porting ledger with its completion gates
tools/
  fetch-reference.sh   clone pinned Taffy into .references/taffy
  pin.env              Taffy repo + immutable revision
  api_audit.py         static public-surface diff (Rust -> Zig)
  parity/              differential harness: Rust oracle vs Zig port
  fixtures/            Taffy XML fixture runner + out-of-process driver
  bench/               tree/flex/grid/block/mixed benchmarks
audit/                 generated results, probes, audits and reports
report.md              parity verdict, evidence, remaining gaps
plan.md                campaign plan and optimization results
.references/            ignored: pinned Taffy source checkout
```

## Building and testing

```sh
zig build test                 # 87 unit tests
zig build test -Dserde=true    # 97 tests, including Taffy wire-format serde
zig build check                # alias for `test`
zig build fixtures             # run the XML fixture suite in-process
zig build fixtures-bin         # install the fixture runner into zig-out/bin
python3 tools/fixtures/run_all.py --jobs 12   # one process per fixture (robust)
zig build parity -- --report   # differential harness (needs cargo)
zig build audit                # static Rust-vs-Zig declaration diff
zig build bench                # Zig benchmarks (defaults to ReleaseFast)
zig build bench-rust           # Rust Taffy mirror benchmarks
zig build bench-compare        # matched ratio table (`-- --repeat 3 --out ...`)
zig build bench-cpu            # CPU-time ratio table (`-- --repeat 3 --cpu 2`)
```

Useful filters and helpers:

```sh
zig build fixtures -- --group flex --filter align --max-failures 10
python3 tools/fixtures/run_all.py --group grid --jobs 8 --failures /tmp/grid.txt
zig build bench -Doptimize=ReleaseFast -- --filter grid
bash tools/fetch-reference.sh                  # restore .references/taffy
```

`fixtures`, `parity` and `audit` require the pinned reference checkout;
`fetch-reference.sh` restores it. The parity oracle uses Cargo and the local
`.references/taffy` path only.

## Serialization (serde)

Zig has no derive-macro serde. The closest ecosystem equivalents are
[`std.json`](https://github.com/ziglang/zig/blob/master/lib/std/json.zig)
(first-party reflection plus `jsonStringify`/`jsonParse` hooks),
[`serde.zig`](https://github.com/OrlovEvgeny/serde.zig) (format-agnostic
options, custom hooks, JSON/YAML/TOML/MessagePack/...), and
[`ziggy`](https://github.com/kristoff-it/ziggy) (schema-based). This package
uses **serde.zig**, pinned by commit in `build.zig.zon`, because it offers
serde-like `serde` options and `zerdeSerialize`/`zerdeDeserialize` hooks while
supporting Zig 0.17 development builds.

`zig build test -Dserde=true` compiles Taffy-compatible JSON support:

- `Style` serializes with the same field set and order as Rust, including
  `"dummy": null`.
- `CompactLength` and its wrappers use Taffy's u64 wire bits with the same
  deserialization tag validation (calc is rejected on read).
- Enums use PascalCase names; alignments use `Safe`-prefixed strings;
  `GridPlacement`/`RepetitionCount` use Taffy's external tagging.

The expected wire format was captured from the pinned Rust crate into
`audit/serde_format_rust.txt`, and the tests deserialize Rust-generated JSON
directly. Serde is optional: without `-Dserde=true` no serde code is compiled
and the dependency is not imported (Zig materializes the pinned package under
the gitignored `zig-pkg/` directory at configure time).

## Reference pin

| Component | Revision |
| --- | --- |
| Taffy | `1b918bafcab101dd234ebeb27da0443e24fd9de2` (`v0.14.0-7-g1b918ba`, 2026-09-03) |
| Tested Zig | `0.17.0-dev.2122+3e15e99e6` (floor `0.17.0-dev.2085+5e36170b5`) |

## License and provenance

MIT — see [LICENSE](LICENSE).

The Zig sources are a port of Taffy (MIT, Copyright (c) 2018 Visly Inc. and the
Taffy Authors) and started life as the layout engine of the ZUI project
(`zui/src/layout`). The Taffy checkout under `.references/` is used only as a
verification oracle and is not distributed with this package.
