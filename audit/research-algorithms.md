# zlay: algorithmic and feature improvements beyond Taffy 0.14

Research date: 2026-09-12.
Scope: `/teamspace/studios/this_studio/zlay` (port of Taffy `1b918ba`, v0.14.0-7)
at full behavioral parity (6,084/6,084 XML fixtures, differential oracle 36/36, geomean
0.915x benchmark ratio). No source file was modified for this report.

Method: read the current port (`src/`, `tools/`) rather than the older
`audit/*.md` snapshots, re-read the pinned reference for the exact upstream behavior,
and consulted current engine implementations and literature (2024-2026) for each topic.
Every design sketch below names real zlay types/functions. Predictions are labeled as
projections; measured facts are cited.

---

## 0. Ground truth from the current code

These are the facts every recommendation builds on.

| Area | Current zlay implementation | Notes / upstream comparison |
|---|---|---|
| Node storage | `TaffyTree.NodeStore` (`src/tree/taffy_tree.zig`): 64-node pages, dense monotonic `u32` ids, `alive` flag | Taffy uses a generational `slotmap`; zlay `tree/node.zig` documents generation as a port-status item. `clear()` resets `nodes.len`, so ids are reused after `clear()`. |
| Node payload | `NodeData`: `Style`, `unrounded_layout`, `final_layout`, `children`, `parent`, `Cache`, `context`/`has_context`, `detailed_layout_info` + deinit fn | NodeStore comment: `NodeData` is ~1.9 KB pre-`CompactLength`; bench README measured `Style` 512 B and `Cache` ~420 B (Taffy ~976 B). |
| Dirty state | `TaffyTree.mark_dirty` walks `id → parent → … → root`, clearing every `Cache` unconditionally; `is_dirty == cache.is_empty()` | Taffy's `mark_dirty_recursive` stops when `Cache::clear()` returns `ClearState::AlreadyEmpty`. zlay's `Cache.clear()` returns `void`; `Cache.clear_state()` exists but is unused by `mark_dirty`. Taffy's `Cache` has an `is_empty` flag (O(1)); zlay scans the ring. |
| Cache | `src/tree/cache.zig`: one `final_layout_entry` (`CacheKey` + `LayoutOutput`) and a 9-entry second-chance clock ring `measure_entries: [9]?MeasureEntry` | Same `CACHE_SIZE = 9` and clock eviction as Taffy. Keys pack `(known_dimensions, available_space)` + `parent_size` + definite bits + requested-axis bits. Measure entries store only `Size(f32)`; results with margin-collapse metadata are not cached. |
| Compute path | `compute_cached_layout` (`src/compute/mod.zig`): `cache_get` → `compute_child_layout` → `cache_store` | Behavior-identical to Taffy's `compute_cached_layout`. |
| Scratch memory | `TaffyTree.scratch: ArenaAllocator` + `in_layout_pass`; `scratchAllocator()`, `resetScratch()` | Flexbox and grid use the scratch arena. **Block does not**: `generate_item_list` appends to `tree_ref.allocator` and `compute_inner` deinits with `tree_ref.allocator` (`src/compute/block.zig`). Grid `NamedLineResolver.init(tree_ref.allocator, …)` also uses the main allocator. |
| Measure callback | `traits.MeasureFunc = fn(context, LayoutInput, NodeId, *const Style) LayoutOutput`; installed for the duration of a `compute_layout_with_measure` run (`measure_function` field) | Same shape as Taffy's measure closure. `compute_leaf_for` returns the callback's `LayoutOutput` directly, so **baselines/overflow from measure already flow through**; zlay's own leaf path returns `.none` baselines. |
| Style | `src/style/mod.zig` `Style` (512 B): physical edges only; `Position = {relative, absolute}`; `Contain.layout/paint` + `_reserved: u6`; no `writing_mode`, no sticky, no `contain: size`, no `contain-intrinsic-size` | Taffy 0.14 changelog: "contain: size is not yet supported"; `writing-mode` open upstream as issue #752. |
| calc() | `CompactLength.calc(pointer)` tag (8-byte packed u64); low-level `LayoutPartialTree.resolve_calc_fn`; but dimension/grid resolution hard-codes `.calc => 0` (`style/dimension.zig`, `style/grid.zig`) and `TaffyTree.resolve_calc_value` returns 0 | Matches Taffy's high-level default (its `TaffyView::resolve_calc_value` also returns 0.0); Taffy exposes real resolvers only through custom `LayoutPartialTree` implementations. |
| Verification | `zig build test`, `zig build fixtures` (6,084 XML cases), `zig build parity` (`tools/parity/run.py`, 0.1 px tolerance), `zig build bench-compare` (6 scenarios, Rust mirror in `tools/bench/rust/src/main.rs`) | Any change below should be gated by all four. |
| Profiling | `src/util/debug.zig` is a stub `DebugLogger` (`enabled=false` by default); `src/compute/block.zig` carries a `TEMP-PROFILE` `rdtsc` block with 16 global counters (`profile_cycles`, `profile_counts`) | Taffy's `debug`/`profile` features only print through `debug_log!` macros; neither engine exposes structured phase timings. |

---

## 1. Incremental / partial invalidation

### 1.1 What zlay does today

- A mutation (`set_style`, `set_children`, `add_child`, `remove`, `set_node_context`, …)
  calls `mark_dirty`, which clears the node's cache and every ancestor's cache, then
  `compute_layout` re-runs from the root. Descendants are not invalidated; they are
  reused through exact cache-key hits. This is Taffy's model and it is the reason
  unchanged subtrees cost only a cache lookup.
- There is no field-level or hint-based invalidation. `set_style` always takes the full
  clear-to-root path, even when only e.g. `flex_grow` changed.
- The upstream performance detail zlay misses: Taffy stops the ancestor walk as soon as
  a node's cache was already empty. zlay re-clears the whole ancestor chain every time
  and detects emptiness by scanning all 10 cache slots.

### 1.2 What other engines do (verified references)

| Engine | Model |
|---|---|
| Taffy 0.14 | `Cache` emptiness is the dirty state; mutation clears node + ancestors; early-out via `ClearState::AlreadyEmpty`. |
| Yoga | `Node::isDirty_` + `markDirtyAndPropagate`; clean nodes are skipped "so long as their parent constraints have not changed". Also ships `hasNewLayout` so consumers walk only updated nodes. |
| Blink / LayoutNG | Layout holds an exact `ConstraintSpace` keyed fragment cache (`CachedLayoutResult`), reused only when the constraint space compares equal, there is no break token, and the object is not `NeedsLayout()`. LayoutNG's *containment* requirement (a layout algorithm may read only the constraint space + its subtree) is what makes this sound. Invalidation under the hood is still the legacy dirty-bit propagation; "over-invalidation and under-invalidation" are named as the core hazards. Pre-paint then walks the immutable fragment tree to compute damage. |
| Servo | Per-flow/fragment damage flags; `restyle_damage.rs` maps which property-change kinds require which layout passes; `IS_DIRTY` + `HAS_DIRTY_DESCENDANTS` summary bits; "restyle hints" coalesce element-state changes. Floats force parts of the block traversal to be sequentialized. |
| Flutter | `markNeedsLayout` + relayout boundaries: propagation stops at the nearest ancestor whose constraints are tight or whose parent does not use its size (`parentUsesSize: false`), so a child size change can be absorbed locally. |
| Slint | Reactive property graph: a change recomputes dependent bindings, and layout runs when geometry-affecting properties changed; no per-node cache keys. |
| Spineless Traversal (PLDI 2025) | Formalizes per-layout-field dirty bits and the double-dirty-bit traversal; replaces tree walks to find dirty nodes with a priority queue + order-maintenance timestamps. Mean 1.80x over 2,216 real-page frames, 2.22x on the 65.6% of frames recomputing ≤1% of fields. |

The last item matters directionally but only partially transfers: zlay has no
separate "find dirty nodes" traversal, because the recursive algorithm itself discovers
dirtiness through cache misses. The paper's auxiliary-node overhead (its main win) is
therefore already avoided structurally. The parts that do transfer are the *granularity*
of invalidation and the consumer-facing change signal.

### 1.3 Recommendations

#### I-1. Adopt Taffy's early-out and an O(1) `is_empty` (faster; parity-neutral)

- **Motivation.** `mark_dirty` is called on every style/content mutation; for a
  UI toolkit that is the hottest tree operation. Walking to the root and blanking
  9 slots per ancestor is pure overhead once the chain is already dirty. zlay is
  currently *slower than its own upstream* here.
- **Design.** In `src/tree/cache.zig`, add `is_empty: bool = true` to `Cache`;
  set it `false` in `store`, `true` in `clear`; make `clear` return `ClearState`
  (merge `clear_state` into it). In `TaffyTree.mark_dirty`, break the loop when
  `clear` reports `.already_empty`. This mirrors Taffy's `NodeData::mark_dirty` +
  `mark_dirty_recursive` exactly. Also make `Cache.is_empty()` read the flag.
- **Impact.** O(depth-to-nearest-dirty) instead of O(depth) per mutation, plus
  O(1) dirty queries. Not visible in the current six cold-tree benchmarks; it is
  the dominant cost in a mutate-relayout loop.
- **Effort.** < 1 day.
- **Parity risk.** None: clearing an already-empty cache is idempotent, and the
  emptiness invariant (a node with an empty cache has empty ancestors) holds
  because every mutation clears upward. Only `Style` and its component value
  types are part of the serde surface (`src/serde_tests.zig` serializes exactly
  those), so the added field is wire-invisible.
- **Verification.** New unit test: lay out, `set_style` a leaf twice, assert the
  root cache is still empty and no extra clear work happens (instrument
  `profile_counts` or a test-only counter). Add a `touch_leaf` benchmark
  scenario to both `tools/bench/main.zig` and `tools/bench/rust/src/main.rs`;
  run `zig build bench-compare -- --repeat 15 --cpu 2`. Existing fixtures and
  oracle must stay green.

#### I-2. Style-diff `set_style` with an optional dirty mask (faster; medium risk)

- **Motivation.** `set_style` clears the *final layout and all 9 measure entries*
  even when the new style is bit-identical, and even when only non-sizing fields
  changed. A ZUI frame that re-sends whole `Style` values (the common builder
  pattern) pays a full invalidation-to-root per node, and the differential oracle
  explicitly exercises style mutation sequences.
- **Design.** Split the cache clear into two masks, expressed as a packed struct
  in `src/tree/cache.zig`:
  - `size_inputs` (padding, border, margin, size/min/max, aspect_ratio, position
    insets, overflow/scrollbar, flex basis/grow/shrink, gap, grid placement):
    clears `measure_entries` + `final_layout_entry`.
  - `layout_only` (alignment, direction, justification, display, float/clear):
    clears only `final_layout_entry`; measured sizes remain usable.
  Add `TaffyTree.set_style_hinted(id, value, mask)` and have `set_style` first do a
  field-wise comparison against the stored `Style` and pick
  `size_inputs | layout_only` only if something actually changed. A conservative
  default (`set_style` = full clear) stays for compatibility. This is the zlay
  analogue of Servo's restyle-damage map.
- **Impact.** Avoids ancestor cache clearing and, more importantly, preserves
  measure entries across alignment/justification changes. Projection: large win for
  interactive restyle loops (hover, focus, selection) where content and sizing are
  unchanged. No gain on the current cold-tree benches.
- **Effort.** ~2-4 days including classification of every `Style` field.
- **Parity risk.** Medium: under-invalidation is the classic layout bug (Blink's
  own docs call it out). The classification must be table-driven and tested; keep
  it opt-in (`set_style_hinted`) so the default path cannot diverge.
- **Verification.** Property test: for random style mutations, compare
  `set_style_hinted` + relayout against `set_style` + relayout node-by-node. Then
  re-run the 6,084 fixtures with a test-only alias of `set_style` routed through
  the hinted API, and add a mutation scenario to the oracle. Add a `restyle_leaf`
  bench scenario.

#### I-3. `has_new_layout` / dirty-descendant summary bits for consumers (more capable; low risk)

- **Motivation.** zlay has no way to tell a painter which nodes changed since the
  last pass. Android/Yoga answer this with `hasNewLayout`; Flutter with
  `PipelineOwner._nodesNeedingLayout`; Blink with prepaint damage. ZUI currently
  has to repaint or diff manually, and the plan's virtualization/damage work
  (plan.md §"Benchmark…", "layout/paint caching, dirty-subtree rendering") needs
  this signal.
- **Design.** Add `layout_generation: u32` to `NodeData` and a tree-level
  `layout_generation: u32`. Bump the tree counter at the start of every top-level
  `compute_layout_impl`; every write to `unrounded_layout`/`final_layout` through
  `set_unrounded_layout`/`set_final_layout`/algorithm commits stamps the node's
  copy with the current counter. Expose:
  - `TaffyTree.has_new_layout(id) bool`
  - `TaffyTree.changed_nodes(allocator) ![]NodeId` (walks the tree once; O(n) but
    cheap and done only when a consumer asks).
  A `dirty_descendants` summary bit can be maintained in `mark_dirty` (set on the
  path to the root when the first non-empty cache is cleared) to let consumers or
  a future partial-round pass skip clean subtrees without walking them.
- **Impact.** Enables damage-rect painting and cheap incremental snapshotting.
  Capability only; no per-layout cost beyond one store per committed node.
- **Effort.** ~2-3 days (the traversal + tests).
- **Parity risk.** None: additive fields, no behavior change.
- **Verification.** Unit test: after relayout with one changed leaf, `changed_nodes`
  contains exactly the path from the leaf to the root plus the leaf's subtree
  nodes that were rewritten; after a no-op relayout it is empty. Existing fixtures
  unaffected.

#### I-4. `mark_dirty` documentation and a debug invariant (low risk)

- **Motivation.** The cache-emptiness invariant is load-bearing and currently
  implicit. A future I-2 change could easily break it.
- **Design.** In debug builds (`builtin.mode == .Debug`), assert in `mark_dirty`
  that after clearing, the chain to the root is empty, and assert in
  `compute_cached_layout` that a returned final-layout entry was stored under the
  identical key. Reference Taffy's `debug` feature gating style.
- **Impact.** Catches the under-invalidation class (I-2, C-3, F-3) at the point of
  violation rather than in a fixture diff.
- **Effort.** < 1 day.
- **Parity risk.** None: assertions only in debug builds.
- **Verification.** `zig build test`; the oracle harness in debug mode.

---

## 2. Caching and measurement

### 2.1 Current design

- `Cache.get` for `compute_size` accepts only entries whose
  `kd_available_space`, definite bits, x-axis parent size, and axis bits all match
  exactly. A measurement performed at available width 300 cannot serve a request at
  320 even when the result is width-independent.
- Measure entries are per node; a node with more than 9 distinct constraint
  combinations during one pass evicts in clock order.
- The ring lives inside every `NodeData`, including containers that never call a
  measure function.
- `compute_leaf_for` (`src/compute/mod.zig`) passes the callback straight through,
  so a callback may already return baselines/overflow/margins; the missing piece is
  a text measurer that computes them (ZUI `src/fonts` shapes through HarfBuzz but
  has no line-breaking/caching layer, and only reports an advance width).

### 2.2 What other engines do

- **Yoga** (`yoga/algorithm/Cache.cpp`, 2026): `canUseCachedMeasurement` is a
  compatibility relation, not equality. It accepts a cached entry when the new
  spec matches exactly, or the cached measurement was taken under
  `MaxContent` and still fits, or the new constraint is *stricter* than the cached
  one and still valid. Yoga also has dedicated min-content values/callbacks
  (`YGMinContentMeasureFunc`, `minContentWidth/Height`) and a subtree analysis
  (`canSkipHeightFitContent`, `isHeightFitContentIndependent`) that proves a
  measurement survives unrelated size changes.
- **Flutter** (`text_painter.dart`, `_TextPainterLayoutCacheWithOffset._resizeToFit`):
  a paragraph laid out at `layoutMaxWidth` is reused without re-breaking when
  `maxWidth >= paragraph.maxIntrinsicWidth` (or the max width is unchanged); it
  only adjusts the paint offset/content width. This is exactly the "max-content
  measurement still fits" rule specialized to text.
- **Blink**: LayoutNG caches fragments by exact `ConstraintSpace`; text has a
  *word cache* whose key includes the string plus font description and the set of
  available fallback fonts (invalidated when fonts change), because "geometric
  operations on text runs are performed over and over during layout".
- **Skia** `ParagraphCache` (128-entry LRU): key is the full paragraph input (text,
  styles, paragraph style, placeholders); value is shaped runs + clusters + bidi
  regions. It deliberately does **not** cache paragraphs that look like active text
  editing (`isPossiblyTextEditing`, 40-char prefix/suffix heuristic) to avoid
  thrashing while typing.
- **Taffy upstream**: cache correctness fixes in 0.14 (#1010, #1155) included
  second-chance eviction and refusing to store margin-collapse metadata; there is no
  compatibility relation beyond exact keys.

### 2.3 Recommendations

#### C-1. A Yoga/Flutter-style compatibility relation for measure entries (faster; medium risk)

- **Motivation.** The dominant real-world cost is text measurement (shaping +
  line breaking) probed at many similar widths during intrinsic sizing, wrapping,
  and window resizes. Taffy/zlay's exact-key cache throws away width-independent
  results the moment a nearby width is requested.
- **Design.**
  - Extend `MeasureEntry` in `src/tree/cache.zig` with the width actually used and
    a `source: enum { definite, max_content, min_content }`, and keep `size`.
  - Add `TaffyTree.measure_contract: MeasureContract` (`exact` default,
    `width_stable` opt-in) set through a new
    `compute_layout_with_measure_contract(tree, root, space, measure, contract)`
    entry point. `exact` preserves today's behavior byte-for-byte.
  - In `Cache.get`'s `compute_size` branch, after exact matching fails, accept an
    entry iff `measure_contract == .width_stable` and one of:
    1. entry was `max_content` and `size.width <= requested_definite_width`
       (the Flutter `maxIntrinsicWidth` rule: a single unwrapped line still fits);
    2. entry was `definite w0`, requested `definite w1 >= w0`, and
       `size.width <= w1` (content did not stretch to fill; the caller's leaf
       sizing will re-apply the definite width anyway).
  - The contract is a promise by the measure callback that its output is a
    function of content + (available width only through soft wrapping), which a
    text measurer satisfies; arbitrary measure callbacks that e.g. read parent
    width do not.
- **Impact.** Projection: subtracts the repeated shape/break work from intrinsic
  passes and small resizes. Yoga has used variants of this for a decade; Flutter
  reports line breaking as "relatively cheap compared to shaping", which suggests
  the win is in avoided *shaping*, i.e. rule 1. zlay's ring (9 entries) also stops
  thrashing when many widths are probed in a pass.
- **Effort.** ~1 week including contract documentation and tests.
- **Parity risk.** None when gated: default `exact` is the current code path; the
  XML fixtures have `measure_*` cases (the runner supplies fixed-size measure
  callbacks), so a bug here is caught immediately if the gate is accidentally on.
  Correctness rests on the callback contract, so it must be explicitly opt-in and
  documented.
- **Verification.** A test measure function that records call counts and returns
  a wrap-dependent size; assert that (a) all layout outputs are identical to the
  exact path, (b) call counts drop for `width_stable`. Add a
  `text_measure_rewrap` bench to both harnesses. Oracle: add a Rust mirror with the
  same measure contract disabled, compare sizes only (behavioral parity).

#### C-2. Sparse measure side-table: less per-node memory, more than 9 slots (faster; low-medium risk)

- **Motivation.** The ring is ~288 B of the ~420 B `Cache` in *every* node, but
  only measured leaves ever use it. Text-heavy trees also routinely exceed 9
  distinct constraints per leaf during intrinsic + final passes, evicting
  entries that would otherwise hit.
- **Design.**
  - Remove `measure_entries`/`recently_used_entries`/`next_measure_entry` from
    `Cache`; keep only `final_layout_entry`.
  - Add `TaffyTree.measure_store: MeasureStore` — a paged open-addressed map
    keyed by `(NodeId, CacheKey)`, with per-node buckets that grow past 9 and a
    global budget (e.g. `max(1024, node_count/4)` entries, 32 B each). Clock or
    LRU eviction happens at the store level.
  - Alternative hybrid if allocation-free operation matters: keep an inline
    ring of 4 and spill the rest. Benchmark both.
- **Impact.** `NodeData` shrinks ~15% (≈288 B/node); 10k-node trees save ~3 MB,
  which shows up in the bench's arena-capacity column and in cache pressure.
  Hit rate improves for text/grid-intrinsic workloads. Risk: one more indirection
  on every measured lookup; the inline ring is very cache-friendly, so keep the
  hot path inline if profiling shows regression.
- **Effort.** ~1 week.
- **Parity risk.** Low: `Cache` is not serialized, and the lookup result set is a
  superset (more hits) only if entries are keyed identically; otherwise behavior
  is unchanged. Must preserve the rule of never caching entries with margin
  metadata.
- **Verification.** `tree_creation_10k` memory proxy should drop; `grid_50x50`
  and `flex_wrap_500` must stay ≤ current ratio; full fixture + oracle gate.

#### C-3. Measure-result fingerprinting against content/font changes (more capable; low risk)

- **Motivation.** The measure contract today is "call `mark_dirty` when content
  changes". This is a known footgun: Yoga's own docs warn about it, and
  `microsoft-ui-reactor#681` documents a real stale cross-axis measure cache that
  survived clean subtrees. zlay's `set_node_context` marks dirty, but content
  stored *behind* the opaque context pointer is invisible to the tree.
- **Design.** Add to `NodeData` a `measure_fingerprint: u64 = 0` and expose
  `TaffyTree.set_measure_fingerprint(id, u64)`. `Cache.get` only accepts a
  measure entry whose stored fingerprint equals the node's current one.
  Consumers (ZUI) compute the fingerprint from whatever the measurement depends on
  — text bytes hash, font id/size, image revision — and update it when content
  changes; layout then self-invalidates even if the caller forgot `mark_dirty`.
  Provide a convenience `new_leaf_with_context_and_fingerprint`.
- **Impact.** Removes a whole bug class, and makes it safe to grow the measure
  cache (C-2) because stale entries can be distinguished. Consumers that maintain
  fingerprints get automatic invalidation on font/size changes without clearing
  the whole tree.
- **Effort.** ~2-3 days.
- **Parity risk.** None when unused (default fingerprint 0 and not consulted).
- **Verification.** Unit test: set context, lay out, change content + fingerprint,
  lay out again, assert re-measure; change nothing, assert no re-measure. Fixtures
  unaffected (no fingerprints set).

#### C-4. Dedicated intrinsic-size slots (faster; low risk)

- **Motivation.** Grid track sizing and flex automatic-minimum sizing repeatedly
  probe min-content/max-content sizes of the same items under the same inputs;
  those probes are exactly the entries most likely to be evicted from the 9-slot
  ring by the intervening definite-width probes.
- **Design.** Add `intrinsic_cache: [2]?MeasureEntry` to `NodeData` keyed by
  `(AvailableSpace.min_content / .max_content, parent_size)` only. Lookup order:
  intrinsic slots → ring/store → compute.
- **Impact.** Avoids repeated deep intrinsic measurements in grid auto/minmax and
  flex `min-width:auto`; upstream Taffy just landed #1177 ("skip contribution
  measurement when no spanned track can receive it"), showing this is still an
  active cost center.
- **Effort.** ~2 days.
- **Parity risk.** Low; identical key semantics, more capacity.
- **Verification.** Add a grid scenario with `minmax(auto, 1fr)` percentage tracks
  and a measure callback; count measure invocations; fixtures + oracle.

#### C-5. Per-pass allocation hygiene in block and grid (faster; low risk)

- **Motivation.** The bench README lists "per-pass scratch reuse" as a remaining
  target, and the code confirms it: `generate_item_list` in `src/compute/block.zig`
  builds a `std.ArrayList(BlockItem)` from `tree_ref.allocator` for every block
  container and `compute_inner` frees it (`defer items.deinit(tree_ref.allocator)`),
  while every child compute can append more items to the same heap. This happens
  on the path that is still 1.96x slower than Taffy (`block_nested_50`) and
  contributes to `mixed_flex_grid_block` (1.49x). Grid's `NamedLineResolver`
  creates and destroys an inner `ArenaAllocator` backed by
  `tree_ref.allocator` per grid container.
- **Design.** Replace `tree_ref.allocator` with `tree_ref.scratchAllocator()` for
  the block item lists (`generate_item_list`, `compute_inner`, and any other
  per-container temporaries in `compute/block.zig`), exactly as flexbox and grid
  already do. The scratch arena is reset only at the top of a top-level pass and
  re-entrant child computes do not reset it, so items remain valid through nested
  layout and are reclaimed wholesale at pass end. For `NamedLineResolver`, either
  keep its inner arena (correct, just churny) or point it at scratch so its buffers
  are recycled across passes. The `TEMP-PROFILE` counters in `block.zig` can be
  used to attribute the win, then generalized per A-1.
- **Impact.** Removes a malloc/free pair per block container per pass; on deep
  chains that is the dominant non-algorithmic cost. The `block_nested_50` memory
  proxy (Zig 119,856 B vs Rust 86,328 B) should move closer to parity. The risk of
  retaining scratch for pass duration is a slightly larger arena high-water mark,
  which the bench memory column will show.
- **Effort.** 1-2 days.
- **Parity risk.** Low: allocation strategy does not affect results; the arena
  free semantics (`free` is a no-op) must simply not be relied on for reclamation
  within a pass.
- **Verification.** `zig build bench-compare -- --repeat 15 --cpu 2` on
  `block_nested_50` and `mixed_flex_grid_block`; fixtures + oracle must stay
  green; watch the arena-capacity column for growth.

#### C-6. A shipped text measurer with shaping/line-break caches and baselines (more capable; large, with ZUI)

- **Motivation.** ZUI's plan §8 wants "a reusable text-layout result with font
  fallback runs, clusters, advances, line breaks, baselines and caret mapping",
  and its layout plan (M3) wants layout and paint to share measured/painted runs.
  Today `src/fonts/shaper.zig` exposes `Shaper.shape()`/`measure()` returning only
  `advance_px`; every layout probe would re-shape, and zlay's leaf path cannot
  produce text baselines for `align-items: baseline`.
- **Design.**
  - Add a `zlay`-side or ZUI-side `TextMeasurer` that implements `MeasureFunc`
    (it can already return `LayoutOutput.baselines` and `scrollable_overflow_rect`).
  - Cache layers, mirroring the engines above: (1) shaped-run cache keyed by
    `(font_id, px_size, tracking, direction, hash(text))` (Blink word cache / Skia
    paragraph cache); (2) wrap cache keyed by `(run, available_width)`; (3) expose
    `max_intrinsic_width` and `min_intrinsic_width` so C-1's rule 1 is usable.
  - Baseline output: first baseline = ascent of the first line, last baseline =
    descent+height of the last; this makes flex/grid baseline alignment work for
    text nodes for the first time.
  - Keep shaped output owned (copy advances) because `Shaper.storage` is reused
    and `ShapeResult.glyphs` aliases it.
- **Impact.** Capability plus performance: avoids HarfBuzz re-shaping across the
  multiple constraint probes a leaf sees; deterministic font-size changes only
  invalidate matching entries. Enables proper baseline alignment, caret/line-box
  output for painting/selection.
- **Effort.** Large (weeks) because line breaking, bidi/fallback runs, and cache
  ownership live in ZUI's text layer; the zlay part (contract + baseline pass
  through) is small.
- **Parity risk.** None for zlay (consumer-side), provided the default
  `compute_layout` path is untouched.
- **Verification.** Text-specific unit tests (advance/baseline equality between
  measure and paint); a `text_heavy` benchmark with a synthetic measurer; fixture
  suite must remain green; oracle parity requires no zlay change unless C-1 is
  enabled.

---

## 3. Parallel layout

### 3.1 Safety analysis against the actual zlay state

What a worker would touch during layout, and its current hazard level:

| State | Written by layout? | Parallel hazard |
|---|---|---|
| `NodeData.style`, `children`, `parent` | No (mutations happen between passes) | None if the tree is quiescent and mutations are not concurrent with layout. |
| `NodeData.unrounded_layout` / `final_layout` | Yes, by the subtree owner | Disjoint if each task owns a disjoint subtree. Alias only at boundaries (parent positions children after they return). |
| `NodeData.cache` (`recently_used_entries`, ring cursor) | Yes | Disjoint per node; concurrent tasks must not compute the same node (they don't, in a tree). |
| `TaffyTree.scratch` arena | Yes, from flex/grid (and block uses the main allocator) | **Single shared, not thread-safe.** `ArenaAllocator.allocator()` is not synchronized. Must become per-worker. Also `in_layout_pass`/`resetScratch` are plain globals on the tree. |
| `TaffyTree.measure_function` | Read-only during a run | Function pointer + user context; the callback must itself be thread-safe. ZUI's `Shaper` reuses one `hb_buffer` per font and `Collection.shaperFor` returns a shared object — **not** thread-safe; workers need per-thread shapers or a lock. |
| `NodeStore.pages` | Read-only during layout (nodes are not created) | Safe if insertion never races layout; `ArrayList` growth is otherwise unsynchronized. |
| `profile_cycles` globals (`block.zig`) | Yes (TEMP-PROFILE `rdtsc`) | Racy; must be thread-local or compiled out before parallelism. |
| `TaffyTree.allocator` | Used by block (`generate_item_list`) and grid (`NamedLineResolver`) | Must be a thread-safe allocator or replaced by per-worker arenas. |
| `detailed_layout_info` | Allocated with `tree_ref.allocator` | Per node, owner-written; grid detail allocation should also come from a worker-local allocator if parallelized. |

Structural observations:

- zlay's algorithms read only the current node's style and its immediate
  children's styles (`tree_ref.style_of(child)`, `get_*_child_style`), and write
  only child layouts. That is exactly the Blink LayoutNG containment precondition:
  a task for a subtree needs its input constraints and the subtree. This is good
  news for eventual subtree parallelism.
- Block layout is inherently sequential where floats/margin collapse are involved:
  `BlockContext` threads `y_offset`, active floats, and margin-strut state from
  sibling to sibling (`src/compute/block.zig`, `sub_context`, `commit_strut`,
  `adjoining_floats`). Servo makes the same observation and defers block size for
  flows that may interact with floats.
- Flexbox line construction and grid track sizing are iterative phases whose
  results feed each other; the safe unit of parallelism inside them is *independent
  child measurement* (all items in a line, all items contributing to a track),
  not the phase itself.

### 3.2 Published approaches

- **Servo** (historical wiki + 2023-2025 status): rayon work queues; each traversal
  is split into a pre-order step, recursive child spawns, then a post-order step,
  so different subtrees and even different passes overlap. Absolute/fixed boxes are
  given a restricted containing-block wrapper precisely because unrestricted reads
  would race. Parallel table layout (2024) distributes rows/columns over cores.
  Servo has shipped incremental layout and improved it through 2025 (Nov 2025:
  "improved the performance of incremental layout").
- **Meyerovich & Bodík, "Fast and Parallel Webpage Layout" (WWW 2010)**: formalizes
  CSS layout as attribute grammars; parallel tree traversals make layout span
  O(log n) with no reflow; reports large speedups on selector matching, layout and
  font rendering.
- **Blink**: layout itself runs on the main thread; LayoutNG's contribution to
  parallelism is architectural — an immutable physical fragment tree (output of
  layout, input to paint) that enables paint/composite work off the main thread.
  There is no production parallel layout in Chrome.
- **"Kastrup's parallel layout work"**: I could not locate any published work under
  this name through web search (DBLP blocked by bot protection; Semantic Scholar
  and general searches returned only unrelated results). I did not find evidence for
  it and have not cited it. The verifiable references are the Servo work and
  Meyerovich & Bodík above.

### 3.3 Recommendations

#### P-1. Window-level parallelism today (faster; no engine change)

- **Motivation.** The safest parallelism is across independent `TaffyTree`s (one
  per window in ZUI; plan.md already treats windows as separate). The only shared
  resource is the allocator.
- **Design.** Document the contract: `TaffyTree` is single-threaded; each window
  owns its tree. Require the allocator passed to `TaffyTree.init` to be
  thread-safe when trees are used from multiple threads
  (`std.heap.ThreadSafeAllocator`, or per-window arenas). Add a compile-time/docs
  marker and a Zig test that lays out two trees on two `std.Thread`s.
- **Impact.** Near-linear scaling for multi-window UIs; zero risk to the engine.
- **Effort.** ~1 day (docs + test). Add a `windows_4` bench.
- **Verification.** Determinism test: layouts produced concurrently equal layouts
  produced sequentially.

#### P-2. Consumer-provided parallel measure batches (faster; high effort, medium risk)

- **Motivation.** In text-heavy UIs the measure callback dominates. Item
  measurements within a flex line or grid item list are independent.
- **Design.** Do not thread the engine itself. Add an injection point so the
  embedding owns the thread pool:
  `TaffyTree.parallel_for: ?*const fn(ctx, count, *const fn(i, *anyopaque) void, *anyopaque)`.
  Flex (`flexbox.zig`, item sizing) and grid (item contribution measurement) call
  it for the batch when present; each item task must use a worker-local scratch
  arena and a worker-local measure context. That requires:
  - `scratchAllocator()` becoming worker-aware: a `ParallelSession` value holding
    per-worker arenas, passed down (or returned by `parallel_for`). The algorithms
    currently capture `tree_ref.scratchAllocator()` at function entry, so the
    session must be threaded through `compute_child_layout` — this is the invasive
    part.
  - An ordered reduction of `LayoutOutput`s so results are independent of
    scheduling; tasks write only their own child's cache/layout.
  - Documenting `MeasureFunc` as "may be invoked concurrently when a parallel
    session is active"; ZUI must give each worker its own `Shaper` (its
    `hb_buffer` is shared per font today).
- **Impact.** Projection: depends entirely on callback cost; a 1 µs measure
  function over 1000 flex items is the kind of workload that scales ~cores.
  Cache-only workloads (current benches) will not scale and may regress from
  scheduling overhead — so it must be opt-in per batch or enabled by a size/price
  heuristic.
- **Effort.** 2-4 weeks including a purpose-built test harness.
- **Parity risk.** None when off; on, results must match the sequential path
  bit-for-bit (f32 reductions are order-sensitive, so reductions must be
  index-ordered).
- **Verification.** Run the full 6,084-fixture suite and the oracle with the
  parallel path enabled and compare against sequential goldens; add
  `flex_row_1000_measure` with a synthetic callback to the bench.

#### P-3. Full subtree parallelism (not recommended now)

- **Assessment.** Requires immutable input snapshots (styles, constraints), a
  context-free child-compute API, per-worker caches/arenas, and resolving
  absolute/float/containing-block cross-subtree reads the way Servo's wrapper
  types do. Block's mutable `BlockContext` makes in-flow siblings genuinely
  sequential. This is a multi-month rewrite of the compute layer with real risk to
  the 36/36 oracle; defer until P-2 data justifies it.
- **Alternative that preserves determinism cheaply.** Because the cache already
  skips clean subtrees, maintaining *correctness of invalidation* (I-1/I-2) buys
  more on interactivity than parallel layout would at typical UI tree sizes.

---

## 4. Feature gaps worth closing

Order within this section is roughly by value/effort, not by implementation order.

#### F-1. `contain: size` and content-visibility-style skipping (more capable; medium)

- **Why.** Taffy 0.14 explicitly does not support `contain: size`; zlay inherited
  that. Long lists / virtualization need the "lay out as empty, keep a placeholder
  size" behavior that `content-visibility: auto` + `contain-intrinsic-size`
  provides in browsers (Blink: when contents are skipped, size containment is
  applied and `contain-intrinsic-size` supplies the size; `auto` remembers the last
  rendered size).
- **Design.** Two additive pieces that do not touch the `Style` wire format:
  1. `Contain` gains a `size` bit using the existing `_reserved: u6` (serialized
     byte changes only when the bit is set; fixture defaults stay 0). In sizing
     paths (`leaf.zig`, container intrinsic sizing, block's
     `determine_content_based_container_width`), a `size`-contained node ignores
     descendant contributions and uses style size/min/max (or 0) as the content
     contribution.
  2. A skip mechanism reusing `RunMode.perform_hidden_layout`: currently
     `compute_hidden_layout` zeroes the node itself. Add
     `compute_skipped_layout` that keeps the node's styled size and only zeroes
     non-contained descendants, plus a side-channel
     `TaffyTree.set_content_skipped(id, ?Size(f32))` for the remembered intrinsic
     size (so the substitution is explicit, not a new `Style` field). Skipping can
     be driven by the embedding's viewport test.
- **Impact.** Large for long scrolling UIs: offscreen subtrees cost a cached
  output instead of full layout. Capability first, speed second.
- **Effort.** ~1-2 weeks.
- **Parity risk.** Medium: new `Contain` semantics when `size` is set; default is
  bit-for-bit as today. The serde tests in `src/serde_tests.zig` explicitly cover
  `Contain` bit encoding; new bit must be added there and the Rust oracle kept
  green (fixtures never set it).
- **Verification.** New XML/JSON fixtures with `contain: size` expectations derived
  from Chrome/Servo; existing 6,084 must stay green; oracle unaffected unless the
  Rust reference is extended.

#### F-2. Sticky positioning as a post-layout helper (more capable; medium)

- **Why.** Taffy's issue #771 is open; the Taffy maintainer's own position is that
  sticky is scroll-dependent and "doesn't make sense as part of the main layout
  phase" — it should be a helper that computes the adjusted position given
  scrollport/containing-block/insets. Servo landed early sticky support in 2024.
- **Design.** Do not add a `Position` variant (it would alter the `Style` enum
  serde surface). Add:
  - `NodeData.sticky_insets: ?Rect(LengthPercentageAuto)` with
    `TaffyTree.set_sticky(id, insets)`;
  - `TaffyTree.compute_sticky_offset(id, scrollport: Rect(f32), containing_block: Rect(f32), border_box: Rect(f32)) ?Point(f32)`
    implementing the CSS clamp: adjusted position = clamp(static position relative
    to scrollport, inset-adjusted limits), with the over-constrained case resolved
    per axis and RTL mirrored via `style.direction`.
  - A `StickyConstraint` output struct so a scroll compositor can recompute at
    paint time without relayout.
- **Impact.** Enables sticky headers/columns in ZUI scrollables; no layout cost.
- **Effort.** ~1 week including the over-constrained cases.
- **Parity risk.** None (additive; not serialized).
- **Verification.** Unit tests for (a) pinned at start, (b) pinned at end,
  (c) scrolling between, (d) container smaller than sticky box, (e) both insets.
  Cross-checked against browser behavior; fixtures untouched.

#### F-3. A real `calc()` resolver on the high-level tree (more capable; medium)

- **Why.** zlay has all the plumbing (`CompactLength.calc(pointer)`,
  `LayoutPartialTree.resolve_calc_fn`, `resolve_calc_value`), but the high-level
  `TaffyTree.resolve_calc_value` returns 0 and `style/dimension.zig` /
  `style/grid.zig` hard-code `.calc => 0`. Taffy's high-level API has the same
  limitation; exposing a resolver would be a genuine step beyond Taffy.
- **Design.**
  - Add `TaffyTree.calc_resolver: ?struct { ctx, fn }` and
    `TaffyTree.set_calc_resolver(ctx, fn)`; make `resolve_calc_value` consult it
    and fall back to 0.
  - Thread a resolver parameter through the hard-coded resolution sites
    (`Dimension.resolve`, `LengthPercentage(Auto).resolve*`,
    `TrackSizingFunction` definite value/limit helpers, `explicit_grid.zig` gap
    resolution). Those helpers currently have no access to the tree; the cleanest
    shape is an explicit `resolver: ?*const fn(?*const anyopaque, f32) f32`
    argument, matching Taffy's own `resolve_calc_value` closures.
  - Optionally ship a small owned expression type (`CalcExpr` with
    `length/percent/add/sub/mul/div`) so consumers do not hand-roll opaque
    pointers; keep serde rejecting calc exactly as Taffy does.
  - Cache interaction: resolver output must be stable for a given pointer and
    basis. Document that mutating a calc handle requires `mark_dirty`, or add a
    `calc_epoch` byte to `CacheKey` bumped on resolver mutation.
- **Impact.** Unlocks `calc(100% - 16px)`-style UI without a separate resolution
  layer; capability parity-plus with Taffy's high-level tree.
- **Effort.** ~1 week (threading + tests) plus optional expression type.
- **Parity risk.** Low: only active when a resolver is installed; fixtures use no
  calc values (serde rejects them), so all gates stay green. The epoch must be
  correct or caches can go stale (same class as C-3).
- **Verification.** Unit tests per dimension/grid path; a differential oracle
  scenario with a Rust resolver mirror; fixtures unchanged.

#### F-4. Layout diffing (more capable; low-medium)

- **Why.** Consumers that paint need changed geometry, not a full tree. Yoga's
  `hasNewLayout`, Flutter's relayout queues, and Blink's prepaint damage are all
  versions of this. Taffy offers nothing.
- **Design.** Build on I-3's generation stamps:
  - `TaffyTree.layout_snapshot(allocator) !LayoutSnapshot` (dense `[]Layout` +
    generation, or reuse serde JSON);
  - `LayoutSnapshot.diff(new: *const LayoutSnapshot, out: *ArrayList(LayoutChange))`
    producing `{id, old: ?Rect, new: ?Rect}` for nodes whose final layout differs;
  - an incremental variant that uses `has_new_layout` to visit only stamped nodes.
- **Impact.** Enables damage-rect painting, transition detection, and cheap test
  assertions. Capability, with a small memory cost if snapshots are retained.
- **Effort.** ~4-5 days.
- **Verification.** Property test: snapshot-based diff equals brute-force compare
  on random mutation sequences; run the fixtures twice (identical => empty diff)
  and once with a mutated leaf (expected path diff).

#### F-5. Subgrid (more capable; large)

- **Why.** Taffy #468 is open with a draft AI-generated PR (#985, 2026-07-22, not
  ready); CSS Grid L2 subgrid is shipped in Blink/WebKit. Nested grids are common
  in UI toolkits.
- **Design.** Requires access to parent track data, which the current dispatch
  (each container computes independently) forbids. The shape that fits zlay is a
  `GridContext` parameter threaded parent→child, analogous to `BlockContext`:
  parent passes its resolved track sizes/line names for the axes the child
  declares `subgrid`; `GridTemplateComponent` gains a `subgrid` variant
  (serialization gated); `NamedLineResolver` merges inherited names.
- **Impact.** Capability; large code surface in `compute/grid/*`.
- **Effort.** Weeks.
- **Parity risk.** Medium-high; new style variant, and Taffy fixtures cannot
  validate it. Only pursue if a consumer needs it.
- **Verification.** WPT subgrid cases adapted to the XML runner; no Taffy oracle
  exists.

#### F-6. Grid lanes / masonry (more capable; large)

- **Why.** Taffy #910 (2026-01); WebKit's January 2026 post ("When will CSS Grid Lanes
  arrive?") says the finalized syntax is available in Safari Technology Preview and
  that Chrome/Edge and Firefox have implementations behind flags; third-party
  trackers report Safari 26 as the first shipping release. A UI toolkit card grid is
  the main use case.
- **Design.** New `Display` variant (`grid-lanes`, gated in serde). Reuse the grid
  explicit track sizing for the lane axis; on the stacking axis, place each item at
  the current minimum offset lane (`CellOccupancy`-style interval scan already
  exists) and grow the container. Track sizing and placement can share most of
  `compute/grid/track_sizing.zig` and `placement.zig`.
- **Impact.** Capability; no parity impact when unset.
- **Effort.** Weeks.
- **Verification.** Cross-check against WebKit/Chromium dumps; no Taffy oracle.

#### F-7. Vertical writing modes / logical properties (more capable; very large)

- **Why.** Taffy #752 is open ("add `WritingMode` style", flex/grid/block support
  below it). zlay and Taffy both hard-code horizontal assumptions: `geometry.zig`'s
  `AbstractAxis` comment says so explicitly; `flexbox.zig` has TODOs at the
  main/cross mapping and baseline code; `leaf.zig` resolves all edges against
  `parent_size.width`.
- **Staged design.**
  1. Logical properties without vertical modes (cheap, useful): a resolution pass
     that maps `margin-inline-start` etc. to physical edges using `direction`
     only. This is a `Style` adapter/helper outside the wire format.
  2. Full vertical modes: add `WritingMode` (gated serde) and route every
     abstract↔absolute axis decision through helpers (`style.abstract_to_absolute`,
     main/cross mapping in flex, block flow axis, grid inline/block aliases,
     baseline selection). Expect to touch alignment, scrollable overflow, and
     rotation of physical rects for output.
- **Impact.** Capability only; correctness-critical for CJK vertical UIs.
- **Effort.** Very large (multiple weeks); no upstream fixtures to compare with —
  validation must come from WPT/Servo behavior.
- **Parity risk.** High if any horizontal-mode code path is refactored
  incorrectly; every step must keep the 6,084 fixtures and oracle green.

#### F-8. Out-of-flow containing-block hoisting (watch upstream; parity break)

- **Why.** Taffy upstream has post-pin work (#1140 `Position::Static/Fixed`,
  #1170 "Hoist out-of-flow (absolute/fixed) boxes to their containing block")
  moving toward the Blink model, where absolute boxes are laid out by their
  nearest positioned ancestor and `Layout.location` is relative to it. zlay/pinned
  Taffy 0.14 lay absolute children relative to their DOM parent.
- **Assessment.** Adopting this changes layout results and breaks the pinned
  fixture expectations; it should be done only when zlay rebases to a newer Taffy
  and the oracle is regenerated. I list it to flag the divergence, not to
  recommend porting it now.

---

## 5. API and productivity features

#### A-1. Structured phase metrics (more capable; low-medium)

- **Why.** `src/util/debug.zig`'s logger is a stub (`enabled=false`, no
  indentation/printing semantics), and the only real instrumentation is the
  `TEMP-PROFILE` block in `block.zig` (16 global `rdtsc` counters). Consumers
  cannot answer "where did this frame go" or "how many measure calls".
- **Design.** Promote the block counters into a feature-gated `zlay.metrics`
  module: a comptime-off zero-cost API (`Metrics.begin(.flex_sizing)`,
  `Metrics.count(.measure_calls)`, per-phase cycles) with counters for cache
  get/hit/miss, measure calls, nodes visited, mark_dirty depth, and
  round_layout time. Follow Yoga's `LayoutPassReason`/event instrumentation as the
  naming precedent; keep counters thread-local.
- **Impact.** Makes the other items measurable (measure-call counters are the
  verification vehicle for C-1/C-2/C-4); enables frame-budget dashboards.
- **Effort.** ~1 week.
- **Parity risk.** None when compiled out; counters are not part of any wire
  format and are thread-local.
- **Verification.** Bench harness prints a phase table; assert counter
  invariants in tests.

#### A-2. Deterministic snapshot / replay CLI for consumers (more capable; low-medium)

- **Why.** The package already has a Taffy-compatible JSON serde surface and an
  XML fixture runner, but consumers have no way to capture a live tree + layout
  and re-run it. This is the classic "reduce a bug to a fixture" workflow.
- **Design.** A `zlay` executable (installed alongside `fixtures-bin`) with:
  - `zlay run <tree.json> [--measure <width,height>]` → layout JSON;
  - `zlay snapshot` mode in-process for apps (build via serde) and
    `zlay replay` that re-computes and diffs;
  - `zlay diff a.json b.json` using F-4;
  - stable ordering and no timing output by default, so diffs are deterministic.
- **Impact.** Turns every consumer bug into an engine fixture; enables CI
  regression tests for ZUI scenes.
- **Effort.** ~1 week (most serialization already exists in
  `src/serde_hooks.zig`/`src/serde_support.zig`).
- **Parity risk.** None: a new executable, no library behavior change.
- **Verification.** Round-trip: `snapshot → replay` produces identical layouts on
  the fixture suite; add to CI.

#### A-3. Debug invariants (more capable; low)

- **Why.** The parity contract is enforced only by tests; a debug build running
  consumer scenes should catch contract violations where they happen.
- **Design.** A `zlay.debug.validate(tree)` routine (debug builds only) checking:
  cache entries are consistent with stored layouts; the emptiness invariant from
  I-1; `round_layout` is idempotent; no `Style` aliasing (styles are values, so
  check that node count vs. allocated pages is consistent); and for
  `perform_layout` calls, every non-hidden node was written. Reference Taffy's
  `debug` feature and `debug_log!` macro gating.
- **Impact.** Catches under-invalidation/aliasing regressions from I-1/I-2/C-1
  early.
- **Effort.** ~2-3 days.
- **Parity risk.** None: validation runs only when explicitly enabled.
- **Verification.** Run the fixture suite in `Debug` with validation on (might
  need a `-Dvalidate=true` flag); run the oracle debug build.

#### A-4. Node identity generations (more capable; medium)

- **Why.** `NodeStore` ids are dense and monotonic, except `clear()` resets
  `nodes.len = 0`, silently aliasing old ids to new nodes; `tree/node.zig` records
  generation semantics as a port-status item. ZUI's plan explicitly asks for
  "generation-checked IDs or equivalent checked handles for callbacks that may
  outlive their targets".
- **Design.** Keep `NodeId = u32` for compatibility but add a parallel
  `generations: []u32` in `NodeStore` and a checked handle type
  (`NodeHandle { index: u32, generation: u32 }`) returned by an opt-in API; bump
  the generation on `clear()`/`remove()`. Errors become `InvalidInputNode` for
  stale handles.
- **Impact.** API safety, not speed; matters for async/event consumers.
- **Parity risk.** Low for new APIs; do not change `TaffyTree`'s existing
  error-on-dead-id behavior (which already covers `remove`, just not `clear`).
- **Verification.** Unit tests for stale handle after `clear`/`remove`.

#### A-5. Make the low-level `LayoutPartialTree` API actually usable (more capable; large)

- **Why.** Taffy's headline embedding feature is implementing the trait set
  (`TraversePartialTree`, `LayoutPartialTree`, `CacheTree`, `RoundTree`) for a
  custom tree. zlay has the vtable records in `src/tree/traits.zig` and
  `resolve_calc_fn`/`set_detailed_grid_info_fn` hooks, but the algorithms are
  hard-wired to `*tree.TaffyTree` (`compute/flexbox.zig`, `grid/mod.zig`,
  `block.zig`), so the records are not exercised. ZUI's adapter (M3) otherwise
  needs a parallel `TaffyTree` representation just to use the engine.
- **Design.** Either (a) make the algorithm entry points generic over a comptime
  tree interface (`anytype`) with `*TaffyTree` as one instantiation — Zig's
  comptime generics specialize without dyn-call overhead — or (b) route the ~8
  trait calls through the existing function tables and measure the vtable cost in
  the benchmark. Option (a) is the performance-safe path but a large refactor;
  option (b) is closer to Taffy's design and can start with flexbox only.
- **Impact.** Capability/API parity with Taffy's low-level surface; enables ZUI to
  keep one element tree. No speed impact for the default `TaffyTree` path under (a).
- **Effort.** Weeks; schedule after the faster wins.
- **Parity risk.** Medium: the algorithms are the parity core; option (a) must
  instantiate the default path identically (verified by the full gates), and option
  (b) must not regress the six benchmark scenarios.
- **Verification.** Port one Taffy `examples/custom_tree_*` shape as a Zig test and
  run the same scenario against both tree implementations, comparing layouts; keep
  the full fixture/bench gates on the default path.

---

## 6. Cross-cutting verification plan

- **Behavioral gate (every change).** `zig build test`, `zig build fixtures`
  (6,084), `zig build parity` (`tools/parity/run.py`, 21 scenarios / 36 nodes,
  0.1 px). `audit/parity_results.txt` records the current 36/36 baseline.
- **Performance gate.** `zig build bench-compare -- --repeat 15 --cpu 2` for the
  existing six scenarios; `--strict` once the port is at parity on all of them.
  Add mutation scenarios (`touch_leaf`, `restyle_leaf`) and a measure-heavy
  scenario (`grid_intrinsic_*`, `text_measure_rewrap`) to *both* harnesses:
  `tools/bench/main.zig` and `tools/bench/rust/src/main.rs`.
- **Differential experiments.** For C-1/C-2/C-4, build a compiled "exact" engine
  variant and a contract-enabled variant and compare all node outputs across the
  fixture corpus plus randomized trees; only then compare call counts.
- **Concurrency.** Sequential-vs-parallel output equality over the full fixture
  suite; race detection with ThreadSanitizer if the toolchain supports it;
  deterministic reductions (index-ordered accumulation).
- **Feature fixtures without upstream.** New features (`contain: size`, sticky,
  calc, grid-lanes, subgrid) have no Taffy oracle. Add hand-written XML/JSON cases
  with expectations generated from Chromium/Servo/WebKit outputs, and keep them in
  a separate group so the Taffy-parity count stays meaningful.

---

## 7. Ordered shortlist

### Faster (same semantics, lower cost)

| Rank | Idea | Confidence | Effort | Where it shows |
|---|---|---|---|---|
| F1 | **I-1 early-out dirty propagation + O(1) `is_empty`** (adopt upstream behavior zlay missed) | High | < 1 day | mutate/restyle loops; new `touch_leaf` bench |
| F2 | **C-5 per-pass allocation hygiene**: move block/grid per-container allocations to the scratch arena (`generate_item_list` and `NamedLineResolver` still use `tree_ref.allocator`) | High | 1-2 days | `block_nested_50` (1.96x) and `mixed_flex_grid_block` (1.49x) |
| F3 | **C-4 intrinsic-size slots** + **C-2 sparse measure store** (capacity and NodeData shrink) | Medium | ~1 week | grid intrinsic sizing, memory column in bench, text-heavy trees |
| F4 | **C-1 measure compatibility relation** (Yoga/Flutter rules, opt-in contract) | Medium | ~1 week | width-probing text/image measure; new measure bench |
| F5 | **P-1 window-level parallelism** (docs + contract, no engine change) | High | ~1 day | multi-window ZUI |

### More capable (new behavior/API)

| Rank | Idea | Confidence | Effort | Notes |
|---|---|---|---|---|
| C1 | **F-3 calc resolver on the high-level `TaffyTree`** + optional expression type | High | ~1 week | Beyond Taffy's high-level API; requires un-hardcoding `.calc => 0` in dimension/grid paths |
| C2 | **C-3 measure fingerprints** (content/font-hash-driven invalidation) | High | 2-3 days | Closes a known stale-measure bug class; enabler for C-1/C-2 |
| C3 | **F-1 `contain: size` + content-skip with placeholder size** | Medium | 1-2 weeks | Taffy lacks it; enables list virtualization |
| C4 | **F-2 sticky-position helper + F-4 layout diffing** (damage tracking) | High | ~1.5 weeks total | Both are post-layout helpers; zero parity risk |
| C5 | **C-6/ZUI first-class text measurer** with shaping/wrap caches, line boxes, baselines | Medium | Weeks (mostly text layer) | Required for shared layout/paint runs and baseline alignment; enabler for C-1/C-4 |
| C6 | **A-1 metrics + A-2 replay CLI + A-3 debug invariants** (tooling) | High | ~2-3 weeks total | Makes everything else measurable and testable |

### Deliberately deferred

- **P-2 parallel measure batches** — only worth it once ZUI has per-thread
  shapers and a text measurer to amortize; invasive session threading through
  `compute_child_layout`. **P-3 full subtree parallelism** — multi-month rewrite.
- **F-7 vertical writing modes** — largest possible capability win, highest risk,
  no upstream fixtures; do the logical-property adapter first.
- **F-5 subgrid / F-6 grid-lanes** — multi-week each; no Taffy oracle; WebKit has
  the most complete Grid Lanes implementation (Technology Preview at the time of its
  January 2026 post), while Chrome/Firefox are behind flags and the spec is still
  settling.
- **F-8 containing-block hoisting** — wait for the upstream Taffy rebase; porting
  it now would break the pinned fixture contract.

### The single most defensible sequence

1. I-1 + block/grid scratch + A-1 metrics (days; measurable, zero risk).
2. C-3 fingerprints + C-2/C-4 cache capacity (about a week; closes bugs and
   improves text/grid hit rates).
3. F-3 calc resolver + F-2 sticky + F-4 diff (about two weeks; capabilities Taffy
   does not have at this API level).
4. C-6 text measurer, built on the ZUI fonts work, then revisit C-1 and P-2 with
   real call-count and scaling data.
