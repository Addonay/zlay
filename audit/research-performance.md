# zlay low-level performance research

**Scope:** techniques for making the Zig port substantially faster than the current
matched baseline (`audit/bench_compare.txt`: geomean **0.915×**, outliers
`block_nested_50` 1.96× and `mixed_flex_grid_block` 1.49×), plus a profiling
methodology that works on this host (no `perf`, no `valgrind`, 4 shared CPUs).

**Baseline source state:** package revision documented in `report.md` §2.4/§2.5
(bench baseline saved 2026-09-12). All first-hand measurements below were taken
on 2026-09-12 between ~10:40 and ~11:00 UTC from scratch programs in
`/tmp/opencode/zprobe` that import the package **read-only** — no package source
file was modified. Note: the working tree is being actively edited by another
session (`src/compute/block.zig` changed at 10:59 and currently contains temporary
`profTsc`/`profAdd` instrumentation); line numbers may have moved, function
names/structures did not.

---

## 0. TL;DR — prioritized shortlist

| # | Idea | Expected payoff | Effort | Risk |
|---|---|---|---|---|
| 1 | Bitmask cache entries + O(1) `is_empty` + Taffy-style early-stop `mark_dirty` | `block_nested_50` 1.96× → ≈1.0×; −80 B (`−6.4%`) per `NodeData`; 1–3% elsewhere | S (~100 LOC in `tree/cache.zig`, `tree/taffy_tree.zig`) | Low |
| 2 | Per-container scratch allocator + preallocated item arrays | `mixed_flex_grid_block` 1.49× → ≈1.2–1.3×; removes 700 alloc/free pairs per mixed layout and the 2→1229 capacity chain (up to 14 allocations) per 1000-child list | S–M (~80 LOC) | Low–medium (lifetimes) |
| 3 | In-place node construction (`appendEmpty`) | `tree_creation_10k` build ~2× faster (ratio 0.26× → ~0.13×); small win in every build phase | S (~30 LOC) | Low |
| 4 | Skip hidden-children post-pass when no `display:none` child; iterate `children.items` slices directly | Removes one full O(children) pass with 512 B style reads per container (1000 per `flex_row_1000`); ~2–5% flex/block | S (~30 LOC per algorithm) | Low |
| 5 | Inline/branch-hint audit + comptime axis specialization; batched SIMD only after 1–4 | 0–3% (hints/inlining) + 2–5% (axis specialization) + 0–5% (SIMD, high verification burden) | M | Low–medium |

Everything else (SoA conversion, full subtree parallelism, sparse caches) is
analyzed below and **not recommended now**; the evidence does not support the
cost/risk.

---

## 1. Measured facts first (so the ideas are grounded)

### 1.1 Structure sizes and layout map

Measured with a scratch program (`@sizeOf`, `@offsetOf`) compiled `-OReleaseFast`
against the package:

| Type | Size | Notes |
|---|---:|---|
| `NodeData` | **1248 B** | page of 64 nodes = **79,872 B** (78 KiB) |
| ├ `style` | 512 B | at offset **0** |
| ├ `children` (`ArrayList(u32)`) | 24 B | at offset **512** |
| ├ `cache` | **464 B** | at offset **536** |
| ├ `unrounded_layout` | 100 B | at offset 1032 |
| ├ `final_layout` | 100 B | at offset 1132 |
| └ `parent`/flags/context/detailed info | ~16 B | parent at 1232 |
| `Cache` | **464 B** | = 96 (`?CacheEntry`) + 9×40 (`?MeasureEntry`) + 3 + pad |
| ├ `CacheEntry` | 88 B | key 24 + `LayoutOutput` 60 + pad |
| ├ `MeasureEntry` | 32 B | key 24 + `Size(f32)` 8 |
| └ `?MeasureEntry` / `?CacheEntry` | **40 / 96 B** | optionals add a full word each |
| `Layout` / `LayoutOutput` / `LayoutInput` | 100 / 60 / 56 B | equal to Taffy per `report.md` |
| `Style` | 512 B | Taffy 560 B (report §2.5) |
| `FlexItem` / `FlexLine` / `AlgoConstants` | 248 / 24 / 168 B | |
| `GridItem` / `GridTrack` / `TrackSizingFunction` / `GridTemplateComponent` | 280 / 48 / 16 / 48 B | |
| `CellOccupancyMatrix` / `DetailedGridInfo` | 80 / 176 B | |
| `PlacedFloatedBox` / `Segment` / `ContentSlot` | 16 / 20 / 32 B | |
| `BlockItem` (private; mirror) | **~312 B** | inferred exactly: `generate_item_list` capacity-2 allocation is **624 B** (see stack traces in §1.3) |

Important compiler fact, verified on this toolchain (Zig `0.17.0-dev.2122`):
**non-`extern` struct fields are automatically reordered** (`struct { a: u8, b: f64, c: u32 }`
measures `b@0, c@8, a@12`). That is why `Style` landed at offset 0 and the `cache`
next to `children` even though they are declared in a different order. Consequences:

* "Put hot fields first" advice is moot for plain structs; control only via
  `extern struct` or explicit padding.
* The compiler already minimization-packs `NodeData`, so remaining size wins must
  come from **representation changes**, not field order.

### 1.2 Where the time goes (build vs compute)

Scratch harness replicating `tools/bench/main.zig`, best-of-15, `taskset -c 2`,
`std.Io.Clock` wall time; host noise is ±2× between sessions, so treat as ranges
(two sessions, 10:50 and 10:57 UTC):

| Scenario | tree build | layout | total (range) | baseline ratio |
|---|---:|---:|---:|---:|
| `tree_creation_10k` | 1.17–2.44 ms | ~0 | 1.17–2.44 ms | 0.26× |
| `flex_row_1000` | 72–80 µs | 290–372 µs | 368–452 µs | 0.80× |
| `flex_wrap_500` | 28–34 µs | 133 µs | 162–167 µs | 0.98× |
| `grid_50x50` | 203–272 µs | 851–930 µs | 1.05–1.20 ms | 0.97× |
| `block_nested_50` | **13.3–14.1 µs** | 0.73–0.75 µs | 14.0–14.8 µs | **1.96×** |
| `mixed_flex_grid_block` | 15 µs | **740–790 µs** | 755–805 µs | **1.49×** |

Key reading: `block_nested_50` is a **tree-construction** problem, not a block
algorithm problem; `mixed` is a layout problem.

### 1.3 Allocation profile (counting allocator over `page_allocator`)

Layout phase only (deterministic counts, one run; my wrapper forces
alloc+copy on growth, so real arena `remap` may amalgamate some flex growth
allocations, but the call sites and sizes are exact). **Caveat: `flexbox.zig` was
modified by the concurrent optimization session at 10:42 UTC, during this
measurement window; the `mixed` allocation storm was reproduced across two builds
and traced to source, the smaller scenarios' exact counts are a snapshot.**

| Scenario | allocs | frees | bytes | notable buckets |
|---|---:|---:|---:|---|
| `flex_row_1000` | 6 | 0 | 740 KB | one ~264 KB `FlexItem` array plus larger buffers; growth shape depends on whether the allocator can `remap` |
| `flex_wrap_500` | 5 | 0 | 208 KB | `FlexLine` list + 151 KB `FlexItem` array |
| `grid_50x50` | 4 | 0 | 1.66 MB | one 1.61 MB `GridItem` array |
| `block_nested_50` | 1 | 1 | 624 B | single 624 B `BlockItem` list |
| `mixed_flex_grid_block` | **709** | **700** | 970 KB | **701 × 624 B** plus 3×~2 KB |

The 700 allocations were attributed with a frame-pointer walk from inside the
allocator + `addr2line` (frame pointers are kept in `ReleaseFast`; verified
`push rbp`):

```
alloc 624 B
  compute.block.compute_block_layout      (block.zig, generate_item_list path)
  compute.compute_child_layout / compute_cached_layout
  TaffyTree.compute_child_layout
  grid.types.GridItem.min_content_contribution_cached
  grid.types.GridItem.minimum_contribution_cached
  grid.track_sizing.track_sizing_algorithm
  grid.compute_grid_layout
  flexbox.compute_flexbox_layout
```

So the 700 × 624 B are **one `ArrayList(BlockItem)` per intrinsic-measurement
pass of each of the 100 grid items** (a 1-child block wrapper). Why 624 B for one
element: `std.ArrayList.growCapacity` adds an `init_capacity` term
(`minimum + minimum/2 + max(1, 64/sizeOf(T))`), so the first append allocates
**capacity 2** for a one-child list (`2 × 312 B`). `BlockItem` is moreover built
by-value field-by-field from a 512 B `Style`.

Allocation cost measured (624 B, `-OReleaseFast`, pinned):

| Allocator | ns / alloc+free |
|---|---:|
| `ArenaAllocator` over `page_allocator` | 38 ns |
| `BufferFirstAllocator` (4 KiB stack buffer) over arena | **2 ns** |
| `page_allocator` directly (syscall path) | 3,414 ns |

### 1.4 Cache and dirty-marking micro (this explains the 1.96× outlier)

Measured directly against `tree/cache.zig` compiled from the same source copy:

| Operation | ns/call |
|---|---:|
| `Cache.clear()` on a **full** cache (456 B of state) | 20.2 |
| `Cache.clear()` on an **empty** cache (still `@memset`s 360 B) | **6.65** |
| bitmask-style clear (`valid = 0; final_valid = false; …`) | **1.83** |
| `Cache.is_empty()` (scans 9 optional entries + final) | 4.13 |
| walk of a 50-deep ancestor chain calling `clear()` (empty caches) | **432** |
| same walk with Taffy-style early stop at first empty cache | **1.02** |

The port's `TaffyTree.mark_dirty` walks every ancestor unconditionally and calls
`cache.clear()` on each. Taffy's does not: its `Cache` keeps an `is_empty: bool`,
`clear()` returns `AlreadyEmpty` without touching memory, and `mark_dirty`
recursion stops at the first `AlreadyEmpty` node
(`.references/taffy/src/tree/cache.rs:239-275`, `tree/taffy_tree.rs:865-888`).
The port has `ClearState`/`clear_state()` but **never uses it in `mark_dirty`**.

`block_nested_50` construction performs 50 `add_child` calls on a growing chain
(plus one `set_children` on the root), i.e. Σ depth ≈ **1,275 cache clears**:
at the measured 6.65 ns/empty-clear plus ancestor-walk overhead this is
≈ **10–11 µs** of the 14 µs build phase — almost exactly the 7.4 µs gap that
makes the scenario 1.96×. This is the single highest-confidence finding in this
report.

### 1.5 Style-copy hypothesis: measured and rejected (for ReleaseFast)

`style_of` returns `Style` **by value** and per-child hot loops in
`flexbox.zig` call it (`generate_anonymous_flex_items`, `determine_flex_base_size`,
`determine_used_cross_size`, hidden pass; `block.zig` hidden pass). Naively that
is a 512 B copy per child. Microbenchmark over 1000 children × 200 reps:

```
style_of by value : 1.2 ns/call
&node.style       : 1.2 ns/call
```

LLVM inlines `style_of` and forward-substitutes only the fields actually read, so
the copy never materialises in `ReleaseFast`. Do **not** prioritise pointer
conversion on these grounds (it still matters in Debug/`ReleaseSafe`, where
inlining is weaker — optional cleanup, not a speed project).

### 1.6 SIMD status and micro-results

Disassembly of the built binary (`objdump`, symbol-scoped):

| Function | scalar FP insns | packed FP insns |
|---|---:|---:|
| `compute.grid.track_sizing.resolve_intrinsic_track_sizes` | 1,718 | 204 |
| `compute.flexbox.compute_flexbox_layout` | 43 | 10 |
| `compute.block.compute_block_layout` | 33 | 13 |

The port contains **no explicit SIMD anywhere** (grep for `@Vector`/`std.simd`: 0
hits). The packed instructions above are incidental auto-vectorisation
(memcpy/zeroing/simple loops); the algorithms are effectively scalar.

Microbenchmark (pinned, `-OReleaseFast`) of the reductions that would matter,
scalar vs `@Vector(4/8/16, f32)`, 200k reps:

| N | scalar | v4 | v8 | v16 | v8 speedup |
|---:|---:|---:|---:|---:|---:|
| 4 | 631 µs | 548 µs | 917 µs | 3,967 µs | **0.69×** |
| 8 | 613 µs | 575 µs | 637 µs | 8,997 µs | **0.96×** |
| 16 | 1,065 µs | 662 µs | 774 µs | 3,240 µs | **1.38×** |
| 50 | 9.6 µs | 2.0 µs | 4.4 µs | 2.3 µs | 2.2× |
| 100 | 19.9 µs | 5.5 µs | 2.2 µs | 2.5 µs | **8.9×** |
| 500 | 158.8 µs | 44.9 µs | 26.8 µs | 16.1 µs | 5.9× |
| 1000 | 504.9 µs | 138.2 µs | 91.9 µs | 38.0 µs | 5.4× |

(Values are totals over 200k reps; compare columns within a row.) Rect-union
batched `@Vector(4,f32)` achieved 2.8×/10.7×/5.3×/4.6×/3.1× at N = 4/16/64/256/1024.

Rule that falls out of this data:

* **N ≤ 8 per call: SIMD loses or breaks even.** At N=16 a 4-wide vector wins
  ~1.6× (8-wide marginal, 16-wide loses badly); from N≈50 upward 8/16-wide
  batches win 2–9×. Per-item work with 1–8 scalars (the common layout case)
  cannot be vectorised profitably; the `@reduce`/tail overhead dominates and
  lane utilisation is 6–50%.
* **N ≥ 64 batched floats: 3–9× on the reduction itself**, but reductions are a
  small share of layout time (grid time is dominated by recursive child
  measurement, not track arithmetic). Amdahl keeps the end-to-end win at a few
  percent.
* `@Vector(16,f32)` is sometimes *faster* than v8/v4 at large N (2× 256-bit ops
  on this AVX2 host), but catastrophically slower at small N. Any use must be
  batched across items or sized `std.simd.suggestVectorLength(f32)` at comptime
  and selected per call size.
* Zig guidance from the ecosystem matches the measurements: explicit vectors can
  beat auto-vectorisation only on large, well-aligned, batchable loops; for
  everything else "let LLVM do it" (ziggit: vector best practices; Zig 0.17
  `std.simd.suggestVectorLength` returns *lanes*, not bytes).

### 1.7 What the engines do (survey)

* **Blink / LayoutNG** — no SIMD in layout math. The win was architectural:
  immutable fragment tree, explicit inputs, cache keyed on parent constraints,
  which restores O(n) on nested two-pass flex/grid (developer.chrome.com
  "RenderingNG deep-dive: LayoutNG"). Blink is still single-threaded for layout.
* **Yoga** — no SIMD. Its documented wins are exactly the categories in this
  report: removing `Style`/`Layout` copies (issue #734: "unnecessary copies all
  over the place" caused 2–4× regressions in 2019-era refactors), removing an
  iterator from pixel rounding plus branch hints and shrinking the iterator
  6→3 pointers (#1736: 4–10% on affected benchmarks), and deleting redundant
  `fmod` calls (#1775: ~1%).
* **Servo** — parallel layout with Rayon, but history is a cautionary tale:
  Layout 2013's eager parallelism made floats/margin collapsing nearly
  unimplementable; Layout 2020 switched to opportunistic parallelism and the
  report says the speed benefit is "difficult to observe". Recent tuning adds
  job-size thresholds (subtree ≥16 boxes, ≥4 jobs) because thread-management
  overhead (`sched_yield` 29% → 14%) dominated on small work
  (servo/servo#45593). Subtree-size heuristic read costs ~8 ns/node there.
* **Taffy** — single-threaded by design (issue #823); current work is
  incremental/dirty-scoped layout (#904 `has_new_layout`, #917 `contain` and
  absolute-subtree scoping), not SIMD or parallelism.

Conclusion: the field's evidence says prefer fewer passes, smaller structures,
cheaper mutation invalidation and better allocation hygiene over SIMD.

---

## 2. Memory layout

### 2.1 Current layout vs access patterns

* **`NodeData` = 1248 B (19.5 cache lines).** One node's hot span is touched in
  this order during a compute: `style` (512 B @0), `children` (@512),
  `cache` (@536..1000), then output writes into `unrounded_layout`/`final_layout`
  (@1032..1232). Every line of the node is touched per compute; for a wide
  container with 1000 children, one full flex compute touches up to 1.25 MB of
  node data per pass and typically 2–3 passes per child (measure + final layout
  + the hidden post-pass), i.e. ~3–4 MB. `flex_row_1000` layout of ~300 µs implies
  ~10–13 GB/s sustained on this Xeon, i.e. **the scenario is memory-traffic
  bound**; total bytes touched, not FLOPs, is the lever.
* **Node traversal order is id-ascending for wide containers** (children are
  appended consecutively, and children lists are dense), so AoS access is
  already sequential/streaming. This is why an SoA split would *not* reduce
  bytes moved; it only helps SIMD or random access, neither of which is the
  current bottleneck.
* **Cache is 37% of `NodeData`**, and 78% of that is the 9 optional measure
  entries. Optionals cost 8 B each in this compiler (`?MeasureEntry` = 40 vs 32)
  for zero benefit.
* **Splitting hot/cold fields**: `context`/`has_context`/`detailed_layout_info`/
  `detailed_info_deinit` (~40 B) are cold in the common case (no context, no grid
  detail reads) but sit inside the same 20-line span. Moving them to side tables
  saves ~3% of bytes; because they're in the same lines already evicted by the
  hot fields, the direct payoff is near zero unless the side arrays become
  sparse. Not recommended before the cache representation fix, which saves more
  for less risk.
* **Page strategy** is good: 64 × 1248 B pages allocate once and never move
  (docstring in `tree/taffy_tree.zig`), so node pointers are stable within their
  lifetime. `NodeStore.at` costs one extra dependent load (`pages.items[id >> 6]`)
  vs a flat array; at 78 KiB/page this is 2.6% of a 3 MB working set in page
  tables and is not measurable at current sizes. Larger pages would slightly
  reduce page-table pressure for very large trees; not a priority.

### 2.2 Idea card — shrink `Cache`, kill the memset, stop early (P0)

**Change.** Replace `[max_entries]?MeasureEntry` with `[max_entries]MeasureEntry`
+ `valid_entries: u16`; replace `final_layout_entry: ?CacheEntry` with
`final_valid: bool` + `final: CacheEntry`; make `is_empty` O(1); make `clear()`
return `ClearState` based on the bits and operate in O(1); make `mark_dirty` use
`clear_state()` and stop at `AlreadyEmpty` exactly like Taffy.

**Expected payoff (reasoned).**
* `Cache` 464 → ~384 B (`?CacheEntry` 96→88, 9×40→9×32, +3 B of masks): `NodeData`
  1248 → ~1168 B, −6.4%. On memory-bound scenarios (`flex_row`, `grid`, `mixed`)
  this is a ~1–3% whole-layout win, and it matches Taffy's 384 B measured in
  `report.md` §2.5.
* `clear()` on empty: 6.65 → 1.83 ns; lookup scans can test a 2-byte mask first
  instead of loading up to 360 B of tags (`is_empty` 4.13 → ~1 ns).
* `block_nested_50`: construction drops ~10 µs (Σ1,275 clears), from ~14 µs to
  ~3–4 µs, i.e. the 1.96× outlier becomes ≈1.0× or slightly better.
* `tree_creation_10k`/`mixed` build phases lose their dirty-chain clears too.
* Risk of *regression* is nil: liveness semantics (which entry is valid, eviction
  order, `recently_used_entries`) are unchanged; this is a representation change
  plus the early-stop that Taffy already has.

**Effort.** ~100 LOC in `tree/cache.zig` + a 6-line change in
`TaffyTree.mark_dirty`; all call sites of `Cache` use methods.

**Risk.** Low. The one subtlety: `compute_size` entries are skipped for outputs
with margin metadata in `store`; keep that condition. `ClearState` must reflect
the same state the old scan would have reported.

**Verification.**
1. `zig build test --summary all` (87/87).
2. `zig build fixtures-bin && python3 tools/fixtures/run_all.py --jobs 12`
   (6,084/6,084).
3. `zig build parity -- --report` (36/36) — cache hits/misses must not change
   observable values.
4. Tree probes (`audit/tree_probes_zig.txt`) — measure-call counts and dirty
   flags must match Rust.
5. `zig build bench-compare -- --repeat 15 --cpu 2 --out audit/bench_compare.txt`
   with focus on `block_nested_50` (expect ≈7–8 µs) and no regression elsewhere.

### 2.3 Idea card — SoA/cache-array split (evaluated, defer)

Separate `styles: []Style`, `caches: []Cache`, `layouts: []Layout` arrays indexed
by node id would let `mark_dirty` scan a dense cache array and make a
"validate all" pass sequential. But: (a) the current AoS traversal is already
sequential in id order; (b) it breaks the public `node()`/`node_const()` pointer
contract in `tree/taffy_tree.zig`; (c) every algorithm would need a second
dereference; (d) the expected win is dominated by the byte-count reductions in
§2.2, which are far cheaper. Revisit only if a cache-miss-bound profile (via the
methodology in §7) shows AoS stride as the limiter. **Payoff uncertain (0–3%),
effort L, risk medium-high. Not recommended now.**

### 2.4 Alignment and false sharing

* `NodeData` is 1248 B (not a multiple of 64); consecutive nodes share cache
  lines. Single-threaded this is harmless-to-helpful (adjacent node writes are
  sequential).
* For any future parallelism (or a cached `cache` array), pad to 1280 B
  (20 × 64 B) and allocate pages `@align(64)` so each node starts on a cache
  line: this removes cross-node false sharing at +2.6% memory. Cheap to try
  behind the same A/B harness; no benefit single-threaded.
* Arena allocations of `Style` copies (only in Debug builds) would benefit from
  64 B alignment; do not bother for `ReleaseFast`.

---

## 3. SIMD

### 3.1 Where layout math genuinely vectorises

Candidate reductions and verdicts (using measured lane economics from §1.6):

| Site | Vectorisable? | End-to-end value |
|---|---|---|
| Grid track sums (`track_sizes += track.base_size`, `crossed_flex_factor_sum`, `used_space` in `maximise_tracks`/`expand_flexible_tracks`) | Yes if `GridTrack` were SoA or after collecting a `[]f32` scratch | Track counts are ≤50 in the benchmark; scalar version is a few ns. ≤0.5% |
| Fixed-track distribution (`stretch_auto_tracks`, `distribute_space_up_to_limits`) | Partially — per-track branch/limit logic dominates | Low |
| Flex per-line sums (`resolve_flexible_lengths`'s 5 passes over `line.items`) | Only with SoA deinterleave of 248 B structs | Not worth it |
| Gap accumulation (`sum_axis_gaps`) | Trivially `gap * (n-1)`, already O(1) | None |
| Scrollable-overflow rect union (block/flex `final_layout_pass`, align-content pass) | Yes in batch: gather `Rect` into scratch, 4 lanes | 3–5× on the reduction, maybe 1–3% of block |
| Alignment offsets (`alignment.zig`) | No — one-shot scalar, branchy | None |
| `round_layout_inner` | No — recursive, dependent on cumulative offsets | None |
| Intrinsic-size reductions over items | Vector input from child measurements is scattered/allocated | No |

Architectural finding: `resolve_intrinsic_track_sizes` spends its time in
recursive `compute_child_layout` calls, not in track arithmetic; the scalar FP
counts in §1.6 are mostly one-off per-item formulas. Any SIMD plan must target
*batched arrays that already exist*, and the only ones with enough N are
`GridItem[]` (280 B stride, gathered) and `FlexItem[]` (248 B). Gathering 280 B
structs into vectors costs more than the arithmetic saved at these N.

### 3.2 If you do it, do it like this (Zig notes)

* Choose lanes at comptime from `std.simd.suggestVectorLength(f32)` (returns
  **lanes**, e.g. 8 on AVX2); guard with a scalar tail.
* Batch across *items*, not within one item: process 8 grid items' contributions
  at a time from a pre-collected `[]f32` scratch array (`GridTrack`'s AoS fields
  force a deinterleave anyway).
* Prefer `@reduce(.Max/.Min/.Add, v)` once per batch, never per item.
* `@select` for min/max with NaN semantics is safe; plain `@min/@max` on vectors
  matches scalar `@min/@max` (no NaN surprises).
* Verify by disassembly (`objdump -d`, grep `vaddps`/`vmaxps`) — auto-vectorised
  loops already exist, and explicit vectors can *disable* LLVM's better layout
  (ziggit consensus; measured here: v8 slower at N=8).
* **Correctness constraint:** all current reductions are left-to-right. A vector
  reduction changes FP summation order, which can perturb last-bit results.
  Fixtures tolerate 0.1 px and the differential oracle compares unrounded
  layouts — assume exact equality is required until proven otherwise; SIMD work
  must be tested with the full oracle, not just fixtures.

**Payoff** ≤2–5% overall; **effort M–L**; **risk medium** (FP order, plus
distraction from bigger wins). Defer until §2.2–§2.3 and §4 are done and
re-profiled.

---

## 4. Allocation strategy

### 4.1 What the profile says

* With the benchmark's arena allocator, `alloc`+`free` of a 624 B block is 38 ns;
  with a 4 KiB `BufferFirstAllocator` it is **2 ns**; with the page allocator it
  is 3.4 µs. `mixed` does 700 of these, and any real embedder uses a
  general-purpose allocator where per-op cost is 30–80 ns. Separately, a
  1000-element `ArrayList(FlexItem)` (248 B each) grows through 14 capacities
  (`2 → 5 → 10 → … → 1229`) whenever the allocator cannot `remap`, re-copying up
  to ~300 KB (verified standalone against `std.ArrayList` on this toolchain).
* The tree allocates **per container** (`generate_item_list`,
  `generate_anonymous_flex_items`, `collect_flex_lines`, `placement`'s
  `placements`/`styles`, `CellOccupancyMatrix`, float context lists) and frees on
  exit. None of it survives the call; all of it could come from a scratch
  allocator that is reset per root compute (or per container).

### 4.2 Idea card — per-container scratch + preallocation (P0/P1)

**Change A (local, safest):** in `compute_inner` (block) and
`compute_preliminary` (flex), wrap the tree allocator once per call:

```zig
var scratch_buf: [4096]u8 = undefined;
var scratch = std.heap.BufferFirstAllocator.init(&scratch_buf, tree_ref.allocator);
const alloc = scratch.allocator();
// pass `alloc` into generate_item_list / collect_flex_lines / FlexItem list
```

`BufferFirstAllocator` (new in this std, replaces the old `stackFallback`) serves
allocations from the stack buffer and falls back to the tree allocator; the fixed
buffer needs no explicit free, which keeps `std.testing.allocator` leak checks
happy as long as the fallback allocations are freed as today.

**Change B (cheap and complementary):** size the lists once:
`items.ensureTotalCapacityPrecise(alloc, child_ids.len)` / `lines.ensureTotalCapacityPrecise(flex_items.len)`,
and use `appendAssumeCapacity`. This removes the capacity chain
(`2 → 5 → 10 → … → 1229`, 14 allocations and ~300 KB of copying for a 1000-child
248-byte item list, verified standalone) and leaves exactly one allocation per
list.

**Expected payoff (reasoned).** `mixed`: removes all ~700 624 B alloc/free pairs
(≈25 µs measured with arena, more with production allocators) plus 1-pass
`BlockItem` growth copies; `flex_row_1000`: 14 allocations → 1 per array and no
copying of 264 KB; `flex_wrap_500`/`grid` similar. Allocation counter should drop
from 709 to single digits for `mixed`. Estimated `mixed` 1.49× → ≈1.2–1.3× and
`flex_*` few percent.

**Effort.** S–M (~80 LOC): thread an `allocator` argument through the three
generators, or locally shadow `tree_ref.allocator` (the algorithms already take
`allocator` parameters in the flex collectors).

**Risk.** Low–medium. Lifetimes: nothing allocated by the generators may escape
the algorithm call (true today: they are `defer`-freed or copied into outputs).
`BufferFirstAllocator.free` on a fixed-buffer pointer is a no-op, so double-free
or leak mistakes inside the scope are safe; real leaks still surface via the
fallback path under `std.testing.allocator`.

**Verification.**
1. Re-run the allocation-count harness (scratch program in §7.2): assert layout
   phase allocations for `mixed` drop from 709/701×624 B to <10, and `flex_row`
   drops to 1–2 per list.
2. `zig build test`, fixtures, parity.
3. `bench-compare --repeat 15 --cpu 2` for `mixed`, `flex_row`, `grid`.

### 4.3 Per-pass arena vs per-container stack buffers

A single arena reset per `compute_root_layout` would catch deeper-nested
temporaries, but requires a place to store it (tree field) and interacts with
embedders' allocators (`TaffyTree` currently allocates everything from the
caller's allocator — a deliberate parity property). Per-container stack buffers
give most of the win with zero API change. If a pass arena is added later:
`deinit` must free it (testing allocator), and `ArenaAllocator.reset(.retain_capacity)`
should be used so retained capacity is available to the next recompute.

### 4.4 Zeroing audit (there is no `nozero` switch to find)

Zig's allocator interface never zeroes: `allocator.alloc` returns
uninitialised memory, and there is no `nozero` option in `std.heap`. All zeroing
in zlay is explicit and should be audited individually:

| Site | Cost | Action |
|---|---|---|
| `Cache.clear()` memset of 9 entries | 6.65 ns empty, 20 ns full; 1,275 calls in `block_nested_50` build | bitmask representation (§2.2) |
| `NodeStore.append` writes `NodeData` by value after building a temporary | 2 × 1248 B per node; the whole `tree_creation_10k` build (1.2–2.4 ms for 10k nodes) is consistent with memory bandwidth | in-place `appendEmpty` (§5.1) |
| `compute_hidden_layout` clears cache and zeroes both layouts per hidden node | only on hidden subtrees | fine |
| `std.mem.zeroes` for caches in `remove`/`clear` | bulk teardown | fine |

`std.testing.allocator` is unaffected by these changes: it checks frees and
leaks, not zeroing; `BufferFirstAllocator` fallback allocations are freed through
the same defer paths.

---

## 5. Algorithmic micro-optimizations

### 5.1 Idea card — in-place node construction (P0, cheap)

`TaffyTree.new_leaf` builds a `NodeData` temporary (defaults zeroed + 512 B
style copied) and `NodeStore.append` copies the whole 1248 B again into the page.
Add `NodeStore.appendEmpty() !*NodeData` that reserves the slot and returns a
pointer, then initialise once in place:

```zig
const id = tree.nodes.reserve();
tree.nodes.at(id).* = .{ .style = value, .children = .empty };
```

**Payoff:** removes one 1248 B write per node (and the temp's zero-fill), i.e.
~12.5 MB of the ~25 MB written for `tree_creation_10k`; build should approach the
memory-bandwidth floor (~0.6–1.2 ms vs 1.17–2.44 ms measured), improving the
0.26× ratio further. Small win in every build phase (block_nested 52 nodes,
mixed/grid 2.5k+ nodes).
**Effort:** ~30 LOC. **Risk:** low (no semantic change; pages are uninitialised
so no read-before-write hazard as long as errdefer paths keep `len` consistent).
**Verification:** `tree_creation_10k`/`block_nested_50` in `bench-compare`,
fixtures + oracle (node identity/order unchanged), allocation counter unchanged.

### 5.2 Idea card — remove the unconditional hidden-children post-pass (P1)

At the end of `compute_preliminary` (flex) and `compute_inner` (block), a loop
walks **all** children: `get_child_id` (bounds + alive + page lookup),
`style_of`/`get_block_child_style` (512 B style read), `box_generation_mode()`;
if nothing is hidden it does nothing. The item-generation pass already visits the
same children and knows whether it skipped any `display:none` child. Record
`had_hidden` there and guard the post-pass. Also iterate
`node_data.children.items` directly instead of `child_count`/`get_child_id` per
index (3 lookups → 1).

**Payoff:** flex_row_1000 eliminates ~1000 style reads + ~2000 `get_node` calls
per compute; block/mixed gain similarly on every container. Estimate 2–5% on
flex/block-heavy scenarios. **Effort:** ~30 LOC per algorithm. **Risk:** low —
must include children skipped for other reasons? No: only `display:none`
children take the hidden path; absolute children still get absolute layout.
Verify hidden/display:none fixtures explicitly (`block 948`, `flex 2664`
include them), plus `display none recursively hides descendants` unit test.

### 5.3 Cache-key and lookup costs

`cache_key()` is computed twice on a miss (`get` + `store`). Compute once in
`compute_cached_layout` and pass it down (small API addition to `Cache`).
`CacheKey` is 24 B; the per-field comparisons in `get` can use the `valid_entries`
mask from §2.2 to skip empty slots entirely. Expected: tens of ns per child
request; low single-digit % on measurement-heavy grids. **Effort:** S.
**Risk:** none semantic (key equality is unchanged). **Verification:** tree
probes' measure-call counts, fixtures, then `bench-compare` for `grid_50x50` and
`mixed`.

### 5.4 Inlining and branch hints

* The port applies Zig's **mandatory** `inline fn` to ~30 functions copied from
  Rust's advisory `#[inline]`, including large ones
  (`final_layout_pass`, `perform_absolute_layout_on_absolute_children` — the
  latter is hundreds of lines). Forced inlining of very large bodies bloats the
  caller, can defeat LLVM's better placement decisions and hurts I-cache.
  Experiment: drop `inline` from the five largest (let LLVM decide), rebuild,
  measure; keep only if neutral-to-better.
* Zig has `@branchHint(.likely/.unlikely/.cold)` (used throughout `std`). Likely
  sites: `compute_cached_layout`'s cache-hit branch, the `perform_layout` vs
  `compute_size` run-mode splits, `display != .none`; cold: every
  `orelse return error.*`, `display == .none`, `overflow == .scroll`, float
  branches in block. Yoga measured 4–10% on affected benchmarks from this class
  of cleanup (#1736), though confounded with copy removal; on zlay expect 0–3%.
  **Effort:** S. **Risk:** low (hints are advisory; forced-inline removal cannot
  change semantics). **Verification:** `bench-compare --repeat 15 --cpu 2` per
  cluster, fixtures/oracle unchanged, and an assembly size check
  (`objdump --size-sort`) to confirm the intended code-size effect.

### 5.5 Comptime axis specialization

Flex/grid inner loops repeatedly dispatch on `constants.dir`/`axis` and call
`main(dir)`/`cross(dir)` accessors. Making `resolve_flexible_lengths`,
`determine_hypothetical_cross_size`, `final_layout_pass` and the grid
distribution helpers comptime-generic over `dir`/`axis` (2 instantiations)
removes those branches and constant-folds the accessors. Taffy is runtime-typed
here, so this is a way to beat parity. **Payoff:** 2–5% on flex/grid;
**effort:** M; **risk:** low (pure code motion, but watch code size).
**Verification:** fixtures + differential oracle must be byte-identical
(specialisation must not reorder any FP operation), then `bench-compare` for
`flex_row_1000`, `flex_wrap_500`, `grid_50x50`.

### 5.6 Fast paths (fully-definite flex/grid)

Taffy has exactly the short-circuits the port ports (compute-size with known
dimensions, duplicate block in flexbox is faithful). Adding new special cases
(e.g. "single-line, all-definite, no baseline" fast path) risks behavioral
divergence and is hard to certify against 6,084 fixtures + oracle. The current
evidence says fixed overheads (allocations, cache clears, extra passes) dominate
over algorithmic branchiness, so **don't** add new fast paths; remove fixed
overheads instead.

### 5.7 Reduced passes summary

Passes over children in the current code: (1) item generation, (2) measure /
base size, (3) final layout, (4) hidden scan, (5) absolute scan (flexbox), plus
grid's intrinsic pipeline. Items 4–5 can be skipped when there is nothing to do
(absolutes present is already known from item generation — `FlexItem` only
includes non-absolute children; record a `has_absolute` bit; likewise
`has_hidden`). Removing 1–2 whole passes per container is the best remaining
algorithmic lever and is semantics-preserving.

---

## 6. Parallelism

### 6.1 What is already shared-nothing

* Each `TaffyTree` owns its `NodeStore`; there are no globals. **Multi-window
  layout parallelises trivially**: run N trees on N threads with per-thread
  allocators. No zlay change is needed except documenting that `TaffyTree` is not
  internally synchronised.
* Within one compute, sibling subtrees are disjoint: caches and layouts are
  per-node; pages never move; no `mark_dirty` runs during compute; the parent
  reads child results only after `perform_child_layout` returns.

### 6.2 What blocks subtree parallelism in zlay

1. **Allocator.** All algorithm temporaries come from `tree_ref.allocator`.
   Taffy's algorithms are already parameterised over the tree but not the
   allocator; zlay would need a per-task allocator threaded through
   `compute_child_layout` (or a worker-local arena in the tree).
2. **Measure callback.** `tree_ref.measure_function` is a single function
   pointer + opaque contexts; embedder callbacks must be declared thread-safe.
   Taffy has the same issue and is single-threaded today (issue #823).
3. **Dirty/incremental state.** A parallel worker must not observe a partially
   updated cache from another worker; since node sets are disjoint this is
   currently fine, but any *incremental* scheme needs per-node version counters
   and parent-side validation (Blink's parent-constraints key is the proven
   design).
4. **False sharing.** `NodeData` is 1248 B, not a multiple of 64, so two workers
   laying out adjacent siblings write each other's cache lines (cache writes,
   layout writes). Fix: pad/align NodeData to 1280 B per §2.4 **only if**
   parallelism lands.
5. **Job sizing.** Servo needed subtree-size thresholds (≥16 boxes, ≥4 jobs)
   before parallelism beat thread overhead, and still found the win hard to
   observe overall. zlay's benchmark trees (50–10,000 nodes) are small; at 4
   shared CPUs, expected speedups are ≪4× and possibly negative below a few
   thousand nodes.

### 6.3 Recommendation

* **Do now:** nothing in the library; enable multi-window users to run trees in
  parallel (per-thread allocators) — that is where the practical 4× lives.
* **Later, if a large-tree workspace exists:** parallelise only the top-level
  sibling loops of flex/grid/block with an explicit `std.Thread.Pool`
  (work-stealing queue), a per-task `ArenaAllocator`, a thread-safe measure
  contract, and a job-size threshold proportional to subtree node count. Keep
  the existing serial path as the default and gate on subtree size.
* **Do not:** parallelise track sizing, sorting, or per-item loops; they are
  dependent or too small.

**Verification path:** a scratch harness that lays out two independent subtrees
and asserts byte-identical results to the serial run; then `zig build fixtures`
with a `--jobs` runner (already out-of-process parallel!) is *not* a substitute
for in-process thread-safety testing — add a dedicated multithreaded test with
`std.Thread` and a shared immutable tree, plus a ThreadSanitizer-style run if a
Zig build supports it (currently not; keep the surface small).

---

## 7. Profiling methodology for this environment

No `perf`, no `valgrind`, shared 4-CPU host with 2× session-to-session variance.
Use three complementary tools, all buildable from scratch programs in
`/tmp/opencode` against a **copy** of `src/` (never modify the package for
measurement):

### 7.1 Phase counters (wall or thread CPU time)

External phase timing (tree build vs `compute_layout`) is already enough to show
`block_nested` is a build problem and `mixed` a layout problem (§1.2). For
in-library phase attribution, copy `src/` to `/tmp`, insert a tiny recorder at
phase boundaries, and print at the end:

```zig
const linux = std.os.linux;
fn nowNs() u64 {                      // thread CPU time: immune to other tenants
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
var phase_ns: [8]u64 = @splat(0);
var phase_calls: [8]u64 = @splat(0);
// in compute_child_layout: const t = nowNs(); defer { phase_ns[k] += nowNs() - t; ... }
```

`std.os.linux.clock_gettime` exists on this toolchain; `std.Io.Clock` exposes the
same clocks when an `Io` instance is available in the harness. Overhead is
~20 ns/call; use counters only around phases >1 µs, or subtract an empty-probe
baseline. `CLOCK_THREAD_CPUTIME_ID` cuts shared-host noise substantially versus
wall time and is the recommended primary signal here.

### 7.2 Allocation counting and attribution

The counting allocator used for §1.3 (`alloc/free/resize/remap` vtable, 16-byte
header, size histogram, live/peak) answers "how many, how big, when". Add
`ret_addr` capture and — because `ReleaseFast` keeps frame pointers — a manual
`rbp` walk to recover call stacks; then symbolize offline:

```
addr2line -e ./bench -f -C -i 0x...      # inlined call chains included
```

This is how the 700 × 624 B `BlockItem` allocations were tied to grid intrinsic
measurement without `perf`. Cost: only enable stack capture for a bounded number
of allocations (4 × 12 frames here); counters themselves are ~2–5 ns.

### 7.3 Statistical practice on a noisy shared host

* One warm-up run per side, then `--repeat 15`, take **min** (compare.py already
  does best-of-N) and record median; treat differences <5% as noise.
* Pin with `taskset -c N` / `bench-compare --cpu 2`; keep both sides on the same
  core and interleave A/B within one time window; re-run in a second window to
  confirm.
* Prefer thread CPU time over wall time when comparing micro-changes; when wall
  time is unavoidable, report ratios only.
* Never trust a single run: the same binary varied 1.17–4.0 ms on
  `tree_creation_10k` across ~10 minutes on this host.
* Keep the correctness gates (unit tests, 6,084 fixtures, 36/36 oracle, tree
  probes) in the loop for every change; performance work here is only safe
  because those gates are strong.
* When SIMD/FP-order is involved, additionally diff the oracle's *unrounded*
  values exactly, not just fixtures' 0.1 px tolerance.

---

## 8. Prioritized shortlist (ordered by expected payoff / effort)

1. **Bitmask `Cache` + O(1) `is_empty` + Taffy-style early-stop `mark_dirty`.**
   Recovers ~11 µs/iteration on `block_nested_50` (1.96× → ≈1.0×), shrinks
   `NodeData` 6.4% (memory-bound scenarios −1–3%), and is a representation
   change with an upstream-proven design. *S, low risk.*
2. **Scratch allocator + preallocated per-container item arrays.**
   Kills the 700 × 624 B alloc/free storm in `mixed` (and array growth everywhere);
   measured 38→2 ns per allocation. *S–M, low–medium risk.*
3. **In-place node construction.** Halves `tree_creation_10k` write traffic
   (0.26× → ~0.13×) and trims every build phase. *S, low risk.*
4. **Skip the hidden post-pass when nothing is hidden; iterate children slices.**
   Removes a full O(children) style-reading pass per container. *S per algorithm,
   low risk.*
5. **Micro-polish with measurement discipline:** drop `inline` from oversized
   functions, add `@branchHint`, compute cache keys once, then (only if a phase
   profile still justifies it) add batched `@Vector` helpers for ≥64-element
   reductions with full FP-order verification.

Deferred / not recommended: SoA conversions (§2.3), full subtree parallelism
(§6), sparse caches, new algorithm-specific fast paths (§5.6).

---

## Appendix A — measurement programs

Standalone scratch programs used for every number above live in
`/tmp/opencode/zprobe/` (not part of the package):

| File | Purpose |
|---|---|
| `probe.zig` | `@sizeOf`/`@offsetOf` report for all structures |
| `bench_probe.zig` | six scenarios: phase timing, counting allocator, ret-addr + frame walk, SIMD micro |
| `cachebench.zig`, `cachebench2.zig` | `Cache` clear/is_empty, ancestor-walk, alloc 624 B across allocators |
| `sizeprobe.zig`, `reorder.zig` | targeted size/layout checks (`?MeasureEntry` = 40, field reordering) |

Build pattern (module deps declared before the dependent module):

```sh
ZIG=/teamspace/studios/this_studio/.zvm/master/zig
$ZIG build-exe -OReleaseFast \
  --dep zlay -Mroot=bench_probe.zig \
  --dep build_options -Mzlay=/path/to/zlay/src/root.zig \
  -Mbuild_options=bo.zig
taskset -c 2 ./root
```

## Appendix B — key sources consulted

* Taffy pinned source: `tree/cache.rs` (`is_empty`, `clear` early return),
  `tree/taffy_tree.rs::mark_dirty` (recursion stops on `AlreadyEmpty`),
  `compute/block.rs::generate_item_list` (one `Vec` per container).
* `audit/bench_compare.txt`, `report.md` §2.4/§2.5 (baseline ratios and sizes).
* Blink "RenderingNG deep-dive: LayoutNG" — fragment caching restores O(n);
  no SIMD claims.
* Yoga issue #734 (Style/Layout copies caused 2–4× regressions), PR #1736
  (copy removal + branch hints + smaller iterator, 4–10%), PR #1775 (`fmod`
  removal ~1%).
* Servo Layout Overview wiki, "Servo Layout Engines Report" (2023), PR #45593
  (job-size thresholds; parallel-layout benefit hard to observe), 8 ns/node
  subtree-size heuristic estimate.
* Zig `std/simd.zig`, `std/heap/BufferFirstAllocator.zig`, `std/array_list.zig`
  (`growCapacity`), `@branchHint` usage in std; ziggit threads on explicit
  vectors vs auto-vectorisation.
* Taffy issues #917 (scoped invalidation/`contain`), #904 (incremental apply),
  #823 (single-threaded, Send/Sync).
