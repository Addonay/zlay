# zlay benchmarks: matched Taffy (Rust) vs Zig port

Two harnesses run the same six scenarios with the same iteration counts, so
`compare.py` can print a direct ratio table:

| Scenario | What it stresses |
| --- | --- |
| `tree_creation_10k` | node insertion, storage growth, style init |
| `flex_row_1000` | single-line flex with grow/shrink and margins |
| `flex_wrap_500` | multi-line flex with gaps and align-content |
| `grid_50x50` | 2,500 items, fixed tracks, placement + occupancy |
| `block_nested_50` | 50-deep block chain with vertical margins |
| `mixed_flex_grid_block` | nested flex > grid > block tree |

Both measure **build + layout per iteration** with a fresh tree (Rust drops the
tree at the end of each call; Zig resets a layout arena), after a warm-up call.

## Running

```sh
zig build bench                              # Zig only (defaults to ReleaseFast)
zig build bench-rust                         # Rust mirror only (LTO build)
zig build bench-compare                      # ratio table, both harnesses
zig build bench-compare -- --filter grid     # one scenario
zig build bench-compare -- --repeat 3 --out audit/bench_compare.txt
zig build bench-compare -- --strict          # non-zero if the port is slower
zig build bench-cpu                          # CPU-time mode (wall-clock immune)
zig build bench-cpu -- --repeat 5 --cpu 2    # best-of-5 CPU-time ratio table
```

The Zig binary is built by the build system and its path is passed to the
comparison script, so `bench-compare` never nests a `zig build` invocation.
`--bench-optimize=debug|safe|fast|small` overrides the default `fast` for the
Zig side; the Rust side always uses its `release` profile
(`opt-level = 3`, `lto = true`, `codegen-units = 1`) so Taffy is measured at
its best.

## Output format

```
bench|<scenario>|<iters>|<ns_per_iter>|<bytes>
```

`bytes` is a memory proxy, not an identical metric:

- Rust: peak live bytes during the measured iterations, tracked by a counting
  `GlobalAlloc`.
- Zig: the layout arena's capacity (high-water, retained across iterations by
  `reset(.retain_capacity)`).

Use it for order-of-magnitude comparisons; the timing columns are the primary
signal.

## Baselines

### Round 2 (2026-09-12, current)

Two independent methods were used because the host (shared 4-CPU) is heavily
loaded, and wall-clock single runs can vary by 2×:

- **CPU time** (`zig build bench-cpu -- --repeat 3 --cpu 2`): each scenario runs
  as its own child process; the ratio uses the child's `user+sys` time from
  `getrusage(RUSAGE_CHILDREN)`. Immune to descheduling.
- **Interleaved wall clock** (`zig build bench-compare -- --repeat 21 --cpu 2`):
  Rust and Zig alternate, best-of-21 per side. Agrees closely with CPU time.

| Scenario | Taffy | Port | Wall ratio | CPU ratio | Note |
|---|---:|---:|---:|---:|---|
| tree_creation_10k | 11.53 ms | 7.19 ms | **0.62×** | **0.48×** | paged store + in-place leaf append |
| flex_row_1000 | 555 µs | 607 µs | 1.09× | **0.92×** | near parity |
| flex_wrap_500 | 197 µs | 226 µs | 1.15× | **0.89×** | near parity |
| grid_50x50 | 4.62 ms | 3.94 ms | **0.85×** | 1.19× | roughly parity under load |
| block_nested_50 | 7.7 µs | 4.4 µs | **0.57×** | **0.68×** | was 1.96× before round 2 |
| mixed_flex_grid_block | 929 µs | 1.00 ms | 1.08× | 1.21× | was 1.49× before round 2 |
| **geometric mean** | | | **0.862×** | **0.856×** | port is faster overall |

The dominant round-2 win is the block chain: Taffy's `Cache::clear` returns
`AlreadyEmpty` and `mark_dirty` stops at the first already-dirty ancestor, which
the port now mirrors (plus an in-place `NodeStore.appendLeaf` and small-child
`BufferFirstAllocator`). See `report.md` §2.4 for the technique list.

### Round 1 (2026-09-12, before round 2; kept for reference)

`audit/bench_compare_round1.txt` — best of 15 runs per side, pinned to one CPU
(`zig build bench-compare -- --repeat 15 --cpu 2`). The host is shared and
noisy, so best-of-N is the meaningful statistic; single runs can vary by 2×.

| Scenario | Taffy | Port | Ratio | Note |
|---|---:|---:|---:|---|
| tree_creation_10k | 6.74 ms | 1.79 ms | **0.26×** | paged node store + packed style |
| flex_row_1000 | 672 µs | 537 µs | **0.80×** | faster |
| flex_wrap_500 | 241 µs | 235 µs | **0.98×** | parity |
| grid_50x50 | 2.12 ms | 2.06 ms | **0.97×** | parity |
| block_nested_50 | 7.6 µs | 15.0 µs | **1.96×** | remaining outlier |
| mixed_flex_grid_block | 641 µs | 953 µs | **1.49×** | block-heavy grid children |
| **geometric mean** | | | **0.915×** | port is faster overall |

Memory proxies (Rust peak live vs Zig arena capacity): tree creation
21.2 MB → 15.8 MB, flex row 1.60 MB → 2.04 MB, grid 6.73 MB → 7.97 MB.

Round-1 optimizations (all behavior-gated by the 6,084 fixtures and the
differential oracle):

1. **Paged node store** (`NodeStore`, 64 nodes/page): O(1) insertion with no
   doubling memcpy of ~1.5 KB nodes; tree creation and memory use dropped 4×.
2. **Compact measure-cache entries**: measurement cache stores `Size<f32>`
   only, matching Taffy (`Cache` 976 B → ~420 B).
3. **Allocation-free occupancy paint**: grid `TrackIntervals.paint` merges
   in place instead of rebuilding a scratch list on every mark.
4. **No sorts in grid placement**: items carry `source_order`; the baseline
   row scan is O(n) instead of two full sorts of 424-byte structs.
5. **Style pointer passing**: hot grid/block/flex helpers take
   `*const Style` instead of copying ~500-byte values per child/container.
6. **Packed `CompactLength`**: 16 B tagged union → 8 B packed u64
   (`Style` 712 → 512 B, `GridItem` 424 → 280 B); serde wire format
   unchanged.

Round-2 optimizations:

7. **Dirty-propagation early-out**: `Cache` carries Taffy's `is_empty` flag;
   `clear` reports `already_empty` and `mark_dirty` stops at the first dirty
   ancestor. This alone removed ~10 µs of per-build cache clearing and closed
   the block-chain gap (1.96× → 0.57×).
8. **In-place leaf construction**: `NodeStore.appendLeaf` writes a new node
   directly into its page slot instead of building and copying a ~1.2 KB
   temporary.
9. **Borrowed styles**: `TaffyTree.style_ptr`; per-child `style_of` copies
   removed from flex item generation, hidden-child passes and grid in-flow
   collection.
10. **Hidden-children fast path**: flex tracks whether any child is
    `display: none` during item generation and skips the full 512-byte-per-child
    hidden post-pass when there is none.
11. **Per-tree scratch arena**: layout-pass temporaries (flex lines/items, grid
    placement/tracks/occupancy, balance buffers) come from
    `TaffyTree.scratchAllocator()`, reset at each top-level compute with
    capacity retained; re-entrant child computes keep the outer epoch alive.
12. **Small-list stack buffer**: block item lists use
    `std.heap.BufferFirstAllocator` and only spill to the tree allocator for
    large child lists; flex item lists reserve capacity once.

Profiling notes (temporary instrumentation, since removed): for the mixed
scenario the port now performs exactly Taffy's work volume — 2,319 child
layout calls, 800 block layouts, 4 grid layouts, 1 flex layout per iteration —
and does *fewer* measure calls (1,709 vs 2,110). Remaining wall gaps in
flex/grid/mixed are small per-call overheads rather than extra work.

Remaining targets (from `audit/research-algorithms.md` and
`audit/research-performance.md`): measure-result fingerprinting plus a larger
sparse measure store, a consumer-supplied `calc()` resolver, field-level dirty
tracking, parallel subtree layout, and batch SIMD helpers (measured to be a
0–5% end-to-end opportunity, so it follows the structural items).

