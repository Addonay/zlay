# Tree + compute parity audit

## Verdict

**No — the tree/compute layer is not at complete feature parity.** The data contracts
(`LayoutInput`/`LayoutOutput`/`Layout`/`RunMode`/`SizingMode`, the 9-entry `Cache` keyed
like Taffy's, dirty propagation, `round_layout` arithmetic, `CollapsibleMarginSet`,
`scrollable_overflow` math, hidden-layout recursion, root RTL placement) are largely
present and in several places byte-for-byte faithful. But three headline gaps remain:
(1) the measure model is different and smaller — Zig stores a per-node
`fn(context, known_dimensions, available_space) Size(f32)` instead of Taffy's
compute-time closure `FnMut(LayoutInput, NodeId, Option<&mut NodeContext>, &Style) ->
LayoutOutput`, so there is no global measure pass, no baselines/overflow/margins from
measure, and `compute_layout_with_measure` is an alias of `compute_layout`;
(2) the low-level custom-tree API does not exist in usable form — the algorithm entry
points are hard-wired to `*TaffyTree` and the trait vtable structs in `tree/traits.zig`
are dead, so the documented Taffy headline feature (implement `LayoutPartialTree` for
your own tree) cannot be exercised; (3) `compute/mod.zig` replaces Taffy's
algorithm-directed child measurement with a dispatcher pre-pass that performs a full
`PerformLayout` of every child before each container runs, while kernel child calls
bypass `compute_cached_layout` entirely. That pre-pass is load-bearing (flex/block read
`child.unrounded_layout.size` as the measured size) and produces concrete wrong results
in at least one verified case (block absolute child with `left`+`right` insets:
Zig 100px/grandchild 50px vs Rust 80px/grandchild 40px), plus different measure counts
and dead cache behavior. Verified with the pinned Rust reference and the Zig build:
Zig `zig build test` passes, but Taffy's 6,084 XML fixtures are not run against it.

## Covered and behaviorally aligned

- `LayoutInput`, `LayoutOutput`, `Layout`, `Baselines`, `CollapsibleMarginSet`,
  `RequestedAxis`, `RunMode` (`perform_layout`/`compute_size`/`perform_hidden_layout`),
  `SizingMode` (`content_size`/`inherent_size`), `LayoutInput.HIDDEN`
  (`src/tree/layout.zig:6-106` vs `.references/taffy/src/tree/layout.rs:10-258`). The
  static audit's claim that `RunMode` is missing `ContentSize`/`InherentSize` is a
  name-merge false positive; those are `SizingMode` variants and are present.
- `Cache` storage: 9 measure entries, single final-layout entry, recently-used
  bitmask/eviction cursor, store rejection for margin-collapse metadata, per-run-mode
  get/store, `ClearState` (`src/tree/cache.zig:94-165` vs `tree/cache.rs:157-284`).
  `CacheKey` packing (f32 bits, x-axis parent-size mask, axis sign bits,
  `size_is_valid_for`) matches (`cache.zig:16-39,78-92` vs `cache.rs:26-142`).
- `CollapsibleMarginSet` operators and `from_margin`/`collapse_with_*`/`resolve`
  (`tree/layout.zig:22-46` vs `layout.rs:31-75`).
- `compute_scrollable_overflow_contribution` is a faithful port, including the
  unreachable-region clip and containment rules (`src/compute/common/scrollable_overflow.zig:10-43`
  vs `compute/common/scrollable_overflow.rs:25-62`).
- `round_layout`: cumulative-coordinate rounding, border/padding edge differences
  computed from rounded cumulative extents, scrollbar rounding, scrollable-overflow
  rounding, same traversal order (`src/compute/mod.zig:139-169` vs
  `compute/mod.rs:219-281`).
- Hidden layout: cache clear, `Layout::with_order(0)`, recursive hiding
  (`src/compute/mod.zig:130-137` vs `compute/mod.rs:285-297`); probe confirms
  descendants are zeroed.
- Root RTL placement and root layout skeleton (`compute/mod.zig:94-128` vs
  `compute/mod.rs:64-168`) — modulo the missing fields listed below.
- `TaffyTree` mutation/query surface is broadly present including
  `new/new_with_capacity`, `new_leaf`, `new_leaf_with_context`, `new_with_children`,
  `add_child`, `insert_child_at_index`, `remove_child`, `remove_child_at_index`,
  `remove_children_range`, `replace_child_at_index`, `set_children`, `child_count`,
  `child_at_index`, `children`, `parent`, `remove`, `total_node_count`, `clear`,
  `set_style`, `style`, `layout`, `unrounded_layout`, `set_unrounded_layout`,
  `set_final_layout`, `detailed_layout_info`, `mark_dirty`, `dirty`/`is_dirty`,
  `compute_layout`, `print_tree`, `enable_rounding`, `disable_rounding`
  (`src/tree/taffy_tree.zig:51-433` vs `tree/taffy_tree.rs:532-926`).
  `remove_last_node` is an extra Zig-only API (`taffy_tree.zig:402-409`; Rust 0.14 has
  only a test of that name at `taffy_tree.rs:1051`).
- `TaffyConfig` does exist in Taffy 0.14 but is `pub(crate)` (`taffy_tree.rs:80-89`);
  Zig publishes it plus `init_with_config`/`new_with_config` (`taffy_tree.zig:17-23,59-65`)
  — a superset, not a gap. There is no `tracing` feature in 0.14 (only `debug`,
  `profile`).

## Missing or unimplemented

1. **Compute-time measure closure / `LayoutOutput`-returning measure.**
   Rust: `compute_layout_with_measure(node, available_space, FnMut(LayoutInput, NodeId,
   Option<&mut NodeContext>, &Style) -> LayoutOutput)`; the closure can size every leaf,
   including nodes with no context, and can return baselines, scrollable overflow and
   collapsible margins (`tree/taffy_tree.rs:897-913`, dispatch at `:320-326`,
   `compute/leaf.rs:17-25,138-145`). Zig: measure is a per-node function pointer
   `fn(?*anyopaque, Size(?f32), Size(AvailableSpace)) Size(f32)`
   (`tree/traits.zig:12-16`); `compute_layout_with_measure` ignores any closure and is
   literally an alias of `compute_layout` (`taffy_tree.zig:365-372`);
   `new_leaf_with_context` requires a function (`taffy_tree.zig:107-112`).
   Impact: cannot port the normal Taffy measure pattern; baselines are always
   `Baselines.none` (`compute/leaf.zig:74,118`; no other producer), so flex baseline
   alignment can never use measured baselines; measured scrollable overflow and measured
   collapsible margins cannot be expressed. Empirical: Rust `compute_layout` on a
   context-bearing leaf returns `(0,0)` (contexts ignored), Zig returns the function's
   `(50,20)`. **Severity: BLOCKER.**
2. **Generic/custom-tree low-level API.**
   Rust: `TraversePartialTree`, `TraverseTree`, `LayoutPartialTree`, `CacheTree`,
   `RoundTree`, `PrintTree`, `LayoutFlexboxContainer`, `LayoutGridContainer`,
   `LayoutBlockContainer` are real traits; every algorithm is
   `compute_flexbox_layout<Tree: LayoutFlexboxContainer>(tree: &mut Tree, ...)`,
   `round_layout(&mut impl RoundTree)`, etc. (`tree/traits.rs:148-315`,
   `compute/flexbox.rs:230`, `compute/grid/mod.rs:50`, `compute/block.rs:348`,
   `compute/mod.rs:64,174,219,285`). Zig: all compute entry points take
   `*tree.TaffyTree` (`compute/mod.zig:23,62,94,130,139`; `flexbox.zig:113`,
   `grid/mod.zig:174`, `block.zig:158`); the vtable structs in `tree/traits.zig:18-185`
   are never constructed or used (grep shows zero uses outside the file), and
   `LayoutFlexboxContainer`/`LayoutGridContainer`/`LayoutBlockContainer` are empty
   wrapper structs (`traits.zig:183-185`). Impact: users cannot lay out their own node
   storage; the documented low-level API examples cannot be written. **Severity: BLOCKER.**
3. **`get_disjoint_node_context_mut`.** Rust returns `[&mut NodeContext; N]`
   (`taffy_tree.rs:662-667`). Zig has no equivalent (only `get_node_context_mut`,
   `taffy_tree.zig:361-363`). Impact: no disjoint mutable context access; with opaque
   `?*anyopaque` there is no typed safe analogue. **Severity: MINOR.**
4. **`set_detailed_grid_info` / `detailed_layout_info` feature.**
   Rust: `LayoutGridContainer::set_detailed_grid_info` (`tree/traits.rs:280-283`),
   `TaffyView` impl stores `DetailedLayoutInfo::Grid(Box<...>)`
   (`taffy_tree.rs:503-507`), public getter `taffy_tree.rs:858-862`. Zig:
   `DetailedLayoutInfo` exists (`tree/layout.zig:156`) but the only setter is an unused
   vtable stub (`tree/traits.zig:110-112`); nothing in `compute/grid` ever calls it, and
   `detailed_layout_info` therefore always returns `.none` (`taffy_tree.zig:260-262`).
   Impact: the default `detailed_layout_info` feature is silently inert (grid track/item
   detail is unavailable). **Severity: MAJOR.**
5. **Block context plumbing.** Rust: `compute_block_layout(tree, node, inputs,
   Option<&mut BlockContext>)` and `LayoutBlockContainer::compute_block_child_layout`
   let block layout pass margin-collapsing context down to children
   (`tree/traits.rs:286-315`, `compute/block.rs:1306`). Zig: the dispatcher has no
   `block_ctx` and `compute_block_layout` discards it (`compute/mod.zig:88`,
   `block.zig:158-161`); no `compute_block_child_layout` exists on
   the tree. Impact: nested block margin-collapse-through behavior cannot match Taffy at
   container boundaries. **Severity: MAJOR** (detailed impact belongs to the block
   audit; this is the missing glue contract).
6. **Block-root pre-sizing in `compute_root_layout`.** Rust resolves block-root
   size/min/max/aspect ratio, content-box adjustment, margin subtraction and
   available-space width into `known_dimensions` before calling the root layout
   (`compute/mod.rs:67-121`). Zig passes `known_dimensions = null` and lets each
   container kernel re-derive sizes (`compute/mod.zig:94-104`, e.g. `block.zig:188-196`,
   `flexbox.zig:139-147`). Impact: block/flex root sizing depends on kernel-local
   reimplementation; edge cases (min=max definite size, content-box roots, margins) can
   diverge; not fixture-verified here. **Severity: MAJOR (uncertain exact blast radius).**
7. **Root `Layout.margin` and `Layout.scrollbar_size`.** Rust computes both for the
   root after layout (`compute/mod.rs:132-163` sets `scrollbar_size` from transposed
   overflow and `margin` from style). Zig sets padding/border/location only
   (`compute/mod.zig:106-126`); no algorithm writes `Layout.margin`/`scrollbar_size`
   anywhere (grep: only defaults and `round_layout`). Probe: styled root (margin 5/6/7/8,
   overflow scroll, `scrollbar_width:15`) → Rust `margin=(5,6,7,8) scrollbar=(15,15)`,
   Zig `(0,0,0,0)`/`(0,0)`. Impact: `layout(node).margin`, `.scrollbar_size`,
   `scroll_width()`/`scroll_height()` are wrong for roots and all nodes.
   **Severity: MAJOR.**
8. **`RunMode::PerformHiddenLayout` early return in the dispatcher.** Rust
   `TaffyView::compute_child_layout` returns hidden layout before anything else when
   `inputs.run_mode == PerformHiddenLayout` (`taffy_tree.rs:292-295`). Zig
   `compute_child_layout` has no such check (`compute/mod.zig:62-91`). Probe:
   `compute_child_layout(visible_leaf, LayoutInput.HIDDEN)` returns the normal
   `(10,11)` instead of a zeroed hidden output. Internal paths avoid this today, but the
   public `LayoutInput.HIDDEN` contract is broken. **Severity: MINOR.**
9. **`print_tree`/debug output parity.** Rust prints
   `{display_label} [x: … overflow: … border: … padding: …] ({key:?})` with correct
   indentation and `PrintTree::get_debug_label` labels (`util/print.rs:14-79`);
   `TaffyTree::print_tree` uses it (`taffy_tree.rs:924-926`). Zig prints
   `{id}: x=… y=… w=… h=…` with no label, no overflow/border/padding, and recursion
   never extends the prefix, so every level is at the same indent
   (`taffy_tree.zig:411-421`, `util/print.zig:10-35`); `get_debug_label` always returns
   `"node"` (`taffy_tree.zig:298-302`). **Severity: MINOR.**
10. **`debug`/`profile` machinery.** Rust macros are wired through flex/grid/block/leaf
    (`util/debug.rs:70-143`; ~40 call sites in `flexbox.rs`/`block.rs`/`grid/mod.rs`).
    Zig `util/debug.zig` defines a logger/flags but has zero call sites and
    `node_logger.enabled` is never set (`debug.zig:37-43`). **Severity: MINOR.**
11. **`util/sys.zig` no-alloc constants.** `MAX_NODE_COUNT=256`, `MAX_CHILD_COUNT=16`,
    `MAX_GRID_TRACKS=16` (`util/sys.rs:160-166`) are absent (`util/sys.zig:1-41`).
    Only relevant to the no-alloc/no-std build, which Zig does not provide.
    **Severity: MINOR.**
12. **Root export surface.** Rust `lib.rs` re-exports `pub use tree::*`, `compute::*`,
    `util::*` (incl. `print_tree`/`write_tree`, `Baselines`, `CollapsibleMarginSet`,
    `RequestedAxis`, `RunMode`, `SizingMode`, `Cache`, `ClearState`, `TaffyError`,
    `TaffyResult`, `MaybeMath`/`MaybeResolve`) (`lib.rs:100-132`). Zig `root.zig:1-92`
    exposes only a curated subset (no `print_tree`/`write_tree`, no mode/axis/baseline
    types, no error/cache types). Accessible via nested modules but not path-compatible.
    **Severity: MINOR.**

## Present but behaviorally divergent

1. **Dispatcher pre-pass replaces Taffy's algorithm-directed child measurement
   (BLOCKER).** Zig: before dispatching a container, `compute_child_layout` calls
   `compute_cached_layout` on *every* child with `run_mode=.perform_layout`,
   `known_dimensions=null`, `axis=.both`, `sizing_mode=parent's sizing_mode`, and a
   derived parent size (`compute/mod.zig:67-84`). The kernels then read the resulting
   `child.unrounded_layout.size` as if it were the measured size: flex box items
   (`flexbox.zig:255` "measured = child.unrounded_layout.size", item basis
   `:259`; comment `:119-121` says children were measured by the dispatcher), flex
   natural sizes, block natural width/height (`block.zig:177-185`), grid stretch/auto
   fallbacks (`grid/mod.zig:487-488`), and block absolute children, which are never
   laid out again (`block.zig:321-341`). Rust measures children through
   `measure_child_size`/`perform_child_layout` with algorithm-specific
   `RunMode`/`SizingMode`/known dimensions inside each algorithm, cached through
   `TaffyView::compute_child_layout` (`taffy_tree.rs:284-329`). Verified divergence:
   block root 100x100, absolute child `left:10,right:10,top:10`, block grandchild
   `width:50%` → Rust abs size `(80,10)`, grandchild width `40`; Zig abs size
   `(100,10)`, grandchild width `50`. Measure counts also differ: single measured leaf
   under a flex root → Rust 1 call, Zig 2 calls; nested flex (root>mid>leaf) → Rust 5,
   Zig 4. Results for common cases may coincide, but the measurement semantics
   (`ComputeSize` vs full layout, content-size vs inherent-size, known-dimension
   definiteness) no longer match Taffy.
2. **Kernel child-layout calls bypass the cache contract (MAJOR).** Rust's
   `LayoutPartialTree::compute_child_layout` always goes through
   `compute_cached_layout` (get/compute/store) (`compute/mod.rs:174-205`,
   `taffy_tree.rs:302-328`). Zig's algorithm call sites invoke
   `TaffyTree.compute_child_layout` -> `compute_child_layout`, which never touches
   `Cache` (`taffy_tree.zig:331-333`, `compute/mod.zig:62-91`); e.g. `flexbox.zig:730`,
   `block.zig:261,281`, `grid/mod.zig:434,498`. Only the root call and the pre-pass use
   `compute_cached_layout` (`compute/mod.zig:23-36,74,105`), and the pre-pass always
   stores `PerformLayout` inputs, so `Cache.measure_entries` are never written by real
   algorithm requests and grid/flex repeated measurements are never reuse-cached.
   Additionally the cached `LayoutOutput` for a child is the *pre-pass* output while the
   node's stored layout was overwritten by the kernel's recomputation — cache and layout
   state can disagree. Impact: the per-node cache feature is effectively dead, and
   stateful measure functions are invoked where Taffy would have hit its measure cache.
3. **Cache `known_dimensions_are_definite` normalization inverted (MINOR now; would be
   MAJOR if the cache were restored).** Rust normalizes to `is_definite || kd.is_none()`
   — true when the axis has *no* known dimension (`cache.rs:137-139`, documented
   `layout.rs:138`). Zig writes `is_definite or kd != null` — true when a known
   dimension *is present* (`cache.zig:87-90`). Probe: store a `compute_size` entry with
   `known_dimensions.width=Some(100)`, flags `{false,false}`, then look up with flags
   `{true,false}` → Zig returns a hit; the Rust key normalization makes these distinct,
   so Rust is a miss. Impact: cached measurements computed with indefinite known
   dimensions can be returned for definite ones (and vice versa).
4. **Extra full layout work during `ComputeSize` (MAJOR).** Zig's pre-pass hard-codes
   `run_mode = .perform_layout` even when the container itself is being computed in
   `compute_size` mode (`compute/mod.zig:74-83`); Taffy's `ComputeSize` exists so
   "layout steps that aren't necessary … can be skipped" (`layout.rs:13-15`). Impact:
   intrinsic-sizing passes (grid track sizing, flex basis) fully lay out and mutate
   descendant `unrounded_layout`/`final_layout` state, with measure functions invoked in
   perform mode.
5. **`Layout` metadata fields are not written (MAJOR).** Rust algorithms write
   `order`, `padding`, `border`, `margin`, `scrollbar_size` for every child
   (`flexbox.rs:2493-2515`, `block.rs:1513-1530,1845-1862`, `grid/mod.rs` placement) and
   `compute/leaf.rs` resolves padding/border for leaves. Zig kernels write only
   `location`/`size` (+ `padding`/`border` for a container onto itself); flex final pass
   (`flexbox.zig:777-782`) and grid placement (`grid/mod.zig:510-512`) never write
   `order`, `padding`, `border` or `margin` for the child. Probe: leaf with
   padding `(2,3,4,5)`, border `(1,1,1,1)`, margin `(6,6,6,6)` → Rust
   `pad=(2,3,4,5) border=(1,1,1,1) margin=(6,6,6,6)`, Zig all zeros. Only `size` and
   location matched. Impact: consumers reading layout metadata (margins for spacing,
   borders/padding for drawing, order for stacking) get wrong data for every
   non-container node.
6. **`content_size`/scrollable-overflow semantics diverged (MAJOR).**
   `compute_cached_layout` overwrites the algorithm's returned
   `output.scrollable_overflow_rect` with a global recomputation from children's
   `unrounded_layout` (`compute/mod.zig:27,38-58`). For leaves this replaces the
   measured-content + padding rect that `leaf.zig:106-114` computes with the full box
   `{0..size}`; for containers it duplicates/replaces the per-algorithm union Taffy
   builds during layout (`block.rs:765-768`, `flexbox.rs` inflow+absolute union). The
   global recomputation also has no RTL mirroring. Additionally
   `LayoutOutput.from_sizes` lost its rect parameter (`tree/layout.zig:99-105` vs
   `layout.rs:249-252`). Impact: `Layout.scrollable_overflow_rect`,
   `scroll_width`/`scroll_height` can differ from Taffy.
7. **Node identity/storage model (MAJOR).** Rust uses `slotmap::SlotMap` generational
   keys (`taffy_tree.rs:147-166`, `node.rs:12-59`); `remove` drops slots and
   `total_node_count` is `nodes.len()` (`:609-630,806-808`). Zig uses dense `u32`
   indices with an `alive` flag (`node.zig:5`, `taffy_tree.zig:28-44`): `new_leaf`
   always appends and reuses `items.len` (`:99-103`), `remove` sets `alive=false` but
   never reclaims the node or its children's capacity (`:374-397`), and `clear` resets
   the array so indices are reissued (`:94-97`). Impact: (a) long-lived trees that
   add/remove nodes grow memory without bound; (b) after `clear()`, a stale `NodeId`
   silently aliases a new node (Rust slotmap is generational; I could not verify
   slotmap's post-`clear` version bump locally because slotmap is not vendored — mark
   as likely-but-unverified); (c) `node()`/`node_const()` expose `*NodeData` pointers
   that are invalidated by any append (`taffy_tree.zig:423-433`). Invalid-id handling
   also differs: Rust panics in several paths (`remove_child` `.unwrap()`
   `taffy_tree.rs:727`; indexing in `add_child`/`parent`/`style`) while Zig returns
   `error.InvalidParentNode`/`InvalidChildNode`/`InvalidInputNode` (`taffy_tree.zig:14`).
8. **`replace_child_at_index`/`add_child` reparenting semantics (MINOR, Zig stricter).**
   Rust `replace_child_at_index` does not detach `new_child` from a previous parent and
   does not dirty that previous parent (`taffy_tree.rs:770-790`); `add_child` likewise
   leaves the old parent's child list intact (`:670-678`). Zig detaches first and marks
   the old parent dirty (`taffy_tree.zig:154-171,200-205,435-447`). This is an
   intentional-looking divergence (Zig's own tests rely on it) but is not Taffy 0.14
   behavior.
9. **`children()`/context accessor aliasing (MINOR).** Rust `children` returns an owned
   `Vec<NodeId>` (`taffy_tree.rs:820-822`); Zig returns a slice into the node's
   `ArrayList` (`taffy_tree.zig:221-231`) that is invalidated by any mutation.
   `get_node_context`/`_mut` return `?*anyopaque` instead of typed references, with no
   `Send`/lifetime guarantees.
10. **Rounding of negative half-values (MINOR).** Rust std `round` is
    `(v+0.5).floor()` (`util/sys.rs:53-55`), i.e. ties toward +infinity (`-2.5 → -2`);
    Zig `@round` is ties-away-from-zero (`-2.5 → -3`) (`util/sys.zig:13-15`,
    `compute/mod.zig:149-166`). `ceil`/`floor` match. Also `fract` differs
    (`% 1.0` vs `x - floor(x)`, `sys.rs:214-220` vs `sys.zig:31-33`) but appears unused.
11. **`compute_root_layout` details (MINOR).** RTL location is clamped at 0
    (`@max(0, width - output.width)`, `compute/mod.zig:121`) whereas Rust allows negative
    (`compute/mod.rs:143-150`); root padding/border percentages fall back to the root's
    own width when available space has no width (`mod.zig:108-120`) whereas Rust resolves
    against `available_space.width.into_option()` only (`mod.rs:132-142`).
12. **`compute_leaf_layout` has extra 0.14-inconsistent logic (MINOR-MAJOR, uncertain).**
    Zig adds `min_max_definite`/`styled_based_known_dimensions` and uses them for the
    ComputeSize early return (`leaf.zig:55-75`), which Rust 0.14 leaf does not
    (`leaf.rs:39-111`); Zig returns collapsible `top_margin`/`bottom_margin` from style
    where Rust always returns `ZERO` (`leaf.zig:119-121` vs `leaf.rs:178-182`) — no Zig
    consumer reads them, so this is dead data with a different contract; Zig's
    `available_for_axis` clamps and drops min/max for known/styled axes differently
    (`leaf.zig:186-194` vs `leaf.rs:113-135`). I did not find a failing fixture by
    inspection; treat as unverified risk.
13. **Test-support Ahem wrapping diverges (MINOR, test-only).** Zig wraps the total
    character count continuously (`test.zig:55-69`); Rust wraps per U+200B-delimited
    line (`test.rs:152-167`). Fixture parity for multiline text would differ.
14. **`dirty()` is a separate flag, not `cache.is_empty()` (MINOR).**
    Rust `dirty` == `cache.is_empty()` (`taffy_tree.rs:892-894`); Zig maintains
    `NodeData.dirty` (`taffy_tree.zig:35`) and sets it false after any computation even
    when `Cache.store` refused the entry (margin metadata) or the node was hidden
    (`compute/mod.zig:28-34`). `is_dirty` can therefore report `false` for uncached
    nodes.

## Test coverage comparison (counts/categories; which Rust behaviors have no Zig test)

- Rust in-scope unit tests: `taffy_tree.rs` 29, `cache.rs` 4, `compute/mod.rs` 1
  (hidden recursion), `leaf.rs` 0, `layout.rs` 0, `node.rs` 0, `traits.rs` 0.
  Plus the fixture suites: 6,084 XML files under `.references/taffy/tests/xml` and one
  generated `hand_written.rs` entry point. Zig: 86 `test` blocks across `src`
  (`zig build test` passes with Zig 0.17.0-dev), including `taffy_tree.zig` 4,
  `cache.zig` 1, `compute/mod.zig` 9 (mostly dispatcher smoke tests), `leaf.zig` 2,
  `layout.zig` 2, `scrollable_overflow.zig` 1, `test.zig` 1. There is no Zig fixture
  runner (no `tests/` directory, no XML parser harness), so port ledger gate #3
  ("Taffy XML/HTML fixture families are executable") is unmet.
- Rust `taffy_tree` categories with **no Zig equivalent**: capacity checks;
  `new_leaf`/`new_leaf_with_context` child-count; `set_measure` +
  `set_measure_of_previously_unmeasured_node` (context change invalidates layout);
  `remove_node_should_detach_hierarchy`; `remove_last_node`; `remove_node_marks_parent_dirty`;
  `remove_child_updates_parents` (issue #510); `insert_child_at_index`;
  `remove_children_range`; `replace_child_at_index`; `child_at_index`/`child_count`/
  `children`; `set_style`/`style`; `mark_dirty` three-way dirty assertions;
  `compute_layout_should_produce_valid_result`; `make_sure_layout_location_is_top_left`
  (padding offsets); `set_children_reparents`. Zig has 4 mutation tests (child
  creation/dirty, reparenting across mutation APIs, `set_children` invalidation,
  validate-before-mutate) — good but far narrower.
- Rust `cache.rs` categories with no Zig test: recently-used measure entries get a
  second chance; storing an existing measurement updates in place; retrieving a
  measurement only marks its slot as used. Zig has the margin-metadata rejection case
  and axis/intrinsic key distinction.
- No Zig test covers: measure invocation counts vs Taffy; cache hit/miss behavior
  through the algorithm path (the dispatcher pre-pass/caching divergence is untested);
  baselines from measure; `Layout.margin`/`border`/`padding`/`scrollbar_size`/`order`
  values; `disable_rounding`; `LayoutInput.HIDDEN` on a visible node;
  `detailed_layout_info`; `print_tree` format; error-vs-panic behavior; node
  identity after `remove`/`clear`; memory reclamation.
- Empirical probes (run for this audit, external to the repo): Rust 1 vs Zig 2 measure
  calls for one measured flex child; Rust 5 vs Zig 4 for the nested case; Zig child
  padding/border/margin all zero vs Rust resolved; Zig root margin/scrollbar zero vs
  Rust `(5,6,7,8)`/`(15,15)`; Zig `compute_layout` uses stored measure (50,20) vs Rust
  (0,0); block absolute `left+right` case Zig 100/50 vs Rust 80/40; Zig cache
  definite-flag lookup hit vs Rust miss; Zig returns normal layout for `LayoutInput.HIDDEN`.

## Feature flags / API surface affected

- The Zig package has no feature system: `build.zig:10-38` exposes only `test`/`check`/
  `audit`, and all modules are compiled unconditionally. Taffy's `taffy_tree`,
  `flexbox`, `grid`, `block_layout`, `float_layout`, `flexbox_balance`, `calc`,
  `content_size`, `detailed_layout_info`, `std`/`alloc`, `parse`, `serde` gates
  (`Cargo.toml` [features]) have no Zig equivalent; `debug`/`profile` exist only as
  inert stubs; `tracing` is not a 0.14 feature.
- Silent no-ops caused by this: `detailed_layout_info` returns `.none` because nothing
  sets it; `content_size` overflow is recomputed by the dispatcher rather than produced
  by algorithms; `debug`/`profile` logging is unwired; `calc` values panic on
  conversion (`style/dimension.zig:358`) or resolve to 0 through
  `TaffyTree.resolve_calc_value` (`taffy_tree.zig:326-329`, matching TaffyTree's own
  0.0 default at `taffy_tree.rs:387-389`, but leaving no way for custom trees to
  resolve calc).
- API surface: measure is per-node (`new_leaf_with_context(style, ctx, fn)` /
  `set_measure`), not a compute-time closure (`taffy_tree.zig:107-119` vs
  `taffy_tree.rs:897-905`); contexts are `?*anyopaque` with no disjoint access; the
  low-level trait API is exported but unusable (`root.zig:78-83`); root re-exports miss
  many `pub use` names from `lib.rs:100-132`; `TaffyConfig` is public in Zig but
  `pub(crate)` in Rust; `remove_last_node` is Zig-only; `Layout` carries an extra unused
  `content_size` field (`tree/layout.zig:112`) and `LayoutOutput::from_sizes` has a
  reduced signature vs Rust.

## Evidence notes

- Commands run: `zig build test` (and `--summary all`) in
  `/teamspace/studios/this_studio/zlay` with
  `/teamspace/studios/this_studio/.zvm/master/zig` (0.17.0-dev.2122+3e15e99e6):
  success, 86 tests, no failures. `cargo run` in `/tmp/opencode/rustprobe` against
  `taffy = { path = ".references/taffy" }` (Rust 1.98.1) produced the reference
  numbers. `/tmp/opencode/probe` (build.zig + probe.zig importing `src/root.zig` as a
  module) produced the Zig numbers. No repo file was modified; only
  `/teamspace/studios/this_studio/zlay/audit/tree-compute.md` was written.
- Files read in full: reference `tree/{mod,cache,layout,node,taffy_tree,traits}.rs`,
  `compute/{mod,leaf}.rs`, `compute/common/scrollable_overflow.rs`,
  `util/{debug,print,sys,mod}.rs`, `test.rs`, `lib.rs`, `prelude.rs`, `Cargo.toml`;
  Zig `tree/*.zig`, `compute/{mod,leaf}.zig`,
  `compute/common/{mod,scrollable_overflow,sizing_keyword}.zig`, `util/{debug,print,sys,mod}.zig`,
  `test.zig`, `root.zig`, `prelude.zig`, `build.zig`, `port.md`, plus targeted reads of
  `compute/{flexbox,block,grid/mod}.zig` and the static `audit/api_audit.md`.
- Could not verify: exact result deltas on the 6,084 XML fixtures (no Zig fixture
  runner; the probe cases above are hand-written); slotmap's generation behavior after
  `clear()` (crate not vendored, so the post-`clear` stale-id aliasing claim is marked
  likely-unverified); runtime profiling of the dispatcher (no benchmarks run); full
  behavioral equivalence of the global `compute_node_scrollable_overflow` recomputation
  vs Taffy's per-algorithm unions (code inspection only).
- The static `api_audit.md` overstates some gaps (trait boilerplate, `RunMode` variant
  false positive, `const fn`/`Debug` noise) and understates several semantic ones
  (measure closure, cache contract, layout metadata, pre-pass); this report is based on
  code reading plus the probes above.
