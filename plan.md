# zlay parity campaign

Goal: bring the extracted Zig port to behavioral parity with pinned Taffy
0.14 (`1b918ba`) as measured by Taffy's 6,084 generated XML fixtures, then
close the API/feature gaps in `report.md`.

## Verification gate

```sh
zig build fixtures -- --group flex --filter align --max-failures 10
python3 tools/fixtures/run_all.py --group grid --jobs 8
python3 tools/fixtures/run_all.py            # full suite, one process per fixture
zig build test                               # package unit tests
zig build parity                             # differential Rust oracle (21 scenarios)
```

The per-fixture driver records a panic as a failure instead of aborting the
suite, so implementation gaps cannot hide behind crashes.

## Baseline (2026-09-12, after the measure/dispatch refactor)

| Group | Passing (start) | Passing (final) |
|---|---:|---:|
| block | 62 / 948 | **948 / 948** |
| blockflex | 0 / 44 | **44 / 44** |
| blockgrid | 8 / 56 | **56 / 56** |
| contain | 0 / 32 | **32 / 32** |
| flex | 118 / 2664 | **2664 / 2664** |
| float | 0 / 92 | **92 / 92** |
| grid | 443 / 2164 | **2164 / 2164** |
| gridflex | 0 / 28 | **28 / 28** |
| leaf | 48 / 56 | **56 / 56** |
| **total** | **679 / 6084 (11%)** | **6084 / 6084 (100%)** |

Also green: `zig build test` 87/87 (97/97 with `-Dserde=true`), differential
oracle 36/36 nodes, all tree/measure/cache probes equal to pinned Rust Taffy,
and Taffy-compatible serde validated against Rust-generated JSON. `report.md`
documents the remaining API-shape gaps (custom-tree traits, pluggable calc
resolvers, node ids).

## Completed workstreams

1. Core contracts: compute-time measure, Taffy dispatch, cache contract,
   trait-extension helpers, faithful leaf + MaybeMath, Ahem measurement.
2. Flexbox: faithful port (`flexbox_balance`, baselines, content sizes,
   absolute children, RTL) — flex/blockflex/gridflex 100%.
3. Grid: faithful port (intrinsic pipeline, placement, named lines, RTL,
   absolute, percentage reruns, `detailed_layout_info`) — grid/blockgrid 100%.
4. Block/float: faithful port (BFC inheritance, margin collapsing, clearance,
   absolute layout, replaced/table sizing, align/text-align, baselines) —
   block/float/contain 100%.
5. Core gap closures: style parsers, `flow-root`, component grid templates,
   detailed-info lifecycle, calc default resolution, `taffyRound`,
   `Npx` viewport parsing, dirty semantics, exports.
6. Optional Taffy-compatible serde (`-Dserde=true`) built on the pinned
   serde.zig dependency, using Rust-captured wire-format fixtures.
7. Matched Rust-vs-Zig benchmark harness (`tools/bench/`, `zig build
   bench-compare`, contention-immune `zig build bench-cpu`). First
   optimization pass (best of 15, pinned CPU,
   `audit/bench_compare_round1.txt`):

| Scenario | Taffy | Port | Ratio |
|---|---:|---:|---:|
| tree_creation_10k | 6.74 ms | 1.79 ms | 0.26× |
| flex_row_1000 | 672 µs | 537 µs | 0.80× |
| flex_wrap_500 | 241 µs | 235 µs | 0.98× |
| grid_50x50 | 2.12 ms | 2.06 ms | 0.97× |
| block_nested_50 | 7.6 µs | 15.0 µs | 1.96× |
| mixed_flex_grid_block | 641 µs | 953 µs | 1.49× |
| **geometric mean** | | | **0.915×** |

    Optimizations: paged node store, compact measure cache, allocation-free
    occupancy paint, no grid sorts, style pointer passing, packed
    `CompactLength` (16→8 B; `Style` 712→512 B).

8. Second optimization pass (same day): cache `is_empty`/`mark_dirty`
   early-out, in-place `NodeStore.appendLeaf`, per-tree scratch arena
   (`in_layout_pass` epoch), small-child `BufferFirstAllocator` for block item
   lists, flex hidden-child fast path, borrowed `style_ptr` in hot per-child
   loops. Results (`audit/bench_compare.txt`; wall best-of-21 and CPU-time
   best-of-3 agree):

| Scenario | Taffy | Port | Wall ratio | CPU ratio |
|---|---:|---:|---:|---:|
| tree_creation_10k | 11.53 ms | 7.19 ms | 0.62× | 0.48× |
| flex_row_1000 | 555 µs | 607 µs | 1.09× | 0.92× |
| flex_wrap_500 | 197 µs | 226 µs | 1.15× | 0.89× |
| grid_50x50 | 4.62 ms | 3.94 ms | 0.85× | 1.19× |
| block_nested_50 | 7.7 µs | 4.4 µs | 0.57× | 0.68× |
| mixed_flex_grid_block | 929 µs | 1.00 ms | 1.08× | 1.21× |
| **geometric mean** | | | **0.862×** | **0.856×** |

    Profiling (temporarily instrumented port + Taffy reference, both removed)
    showed the port now performs exactly Taffy's work volume on the mixed
    scenario (2,319 child calls, 800 block / 4 grid / 1 flex layouts) with
    fewer measure calls (1,709 vs 2,110). Remaining gaps are per-call overheads
    and are tracked, with research notes, in `report.md` §7 and
    `audit/research-*.md`. Every step kept tests, fixtures and parity green.

## Key implementation notes

1. **Measure ABI** matches Taffy: compute-time callback
   `fn(context, LayoutInput, NodeId, *const Style) -> LayoutOutput`
   (`tree/traits.zig`), installed by `compute_layout_with_measure`.
2. **Dispatch** matches `TaffyView::compute_child_layout`: hidden
   short-circuit, display dispatch, childless → measure (`compute/mod.zig`).
3. **Cache contract**: all algorithm child requests go through
   `compute_cached_layout`; there is no dispatcher pre-pass.
4. **Trait-extension helpers** on `TaffyTree`: `measure_child_size`,
   `measure_child_size_both`, `perform_child_layout`.
5. **Fixture harness**: `tools/fixtures/` XML reader + comparator, build steps
   `fixtures`/`fixtures-bin`, out-of-process driver `run_all.py`.
6. **Rules if algorithm work resumes**: the Rust file is the specification;
   port phase order and formulas exactly (including `content_size` and
   baseline blocks); never lay out children directly; iterate with a named
   fixture as the reproduction.
