# Block + float parity audit

## Verdict

**No — there is not complete feature parity.** The Zig `compute/block.zig` is a simplified sibling-stack approximation of Taffy's block algorithm, not a port: it ignores the inherited `BlockContext` (`block.zig:158-161`) and creates a fresh `BlockFormattingContext` per block (`block.zig:202-205`), so floats never cross a block boundary; it never reads the item data it collects (replaced/table/overflow/contain/static_position/can_be_collapsed_through are dead, `block.zig:216-247`); it never reads `aspect_ratio`, `text_align`, `align_content`, `contain`, `scrollbar_width`, sizing keywords, or the `LayoutOutput` margins/baselines produced by leaves; absolute children are only re-positioned, never laid out (`block.zig:301-341`); and the float height contribution is summed additively into the intrinsic height rather than maxed (`block.zig:174-186`). `compute/float.zig` implements a plausible but different placement heuristic (`next_obstacle_y`, `float.zig:250-294`) and leaves `FloatIntrinsicWidthCalculator` (`float.zig:403-432`) and `find_bfc_slot` (`float.zig:382-400`) unused. The shared helpers (`common/alignment.zig`, `common/scrollable_overflow.zig`, `common/sizing_keyword.zig`'s `resolve_sizing_keyword`) are close to line-for-line, but `resolve_absolute_sizing_keywords` is a stub. The static audit understates this dramatically: `compute/block.rs` does not appear in `api_audit.md` at all because every name exists in Zig.

## Covered and behaviorally aligned

- `style/float.zig:6-47` `Float`/`Clear`/`FloatDirection` values, `from_str`, `is_floated`, `float_direction` match `style/float.rs:9-80`.
- `style/block.zig:6-24` `TextAlign` values and `is_legacy`; parse additionally accepts `-moz-left/right/center` (Rust `style/block.rs:58-63` only lists `-webkit-*`). Extension, not a regression.
- `compute/common/alignment.zig:7-61` `resolve_self_alignment_safety`, `apply_alignment_fallback`, `compute_alignment_offset` are semantically identical to `alignment.rs:11-117`.
- `compute/common/scrollable_overflow.zig:10-43` matches `scrollable_overflow.rs:25-62` including the `parent_is_scroll_container` unreachable-region clip.
- `compute/common/sizing_keyword.zig:15-25` `resolve_sizing_keyword` matches `sizing_keyword.rs:28-47` for all six keywords; `is_intrinsic` is extra.
- `tree/layout.zig:22-46` `CollapsibleMarginSet` (positive + most-negative) matches Taffy's margin-set algebra.
- `float.zig:74-85` `float_fits_horizontally` is equivalent to `float.rs:134-149` (rules 1/3/7) for the cases reachable here.
- `float.zig:156-161` `has_active_floats`, `float.zig:276-279` `clear_bottoms`/`float_ceiling`, and the zero-height-float clearance bookkeeping follow `float.rs:268-269,311-342,466-478` observably.
- `float.zig:413-431` `FloatIntrinsicWidthCalculator.add_float/result` is a faithful transcription of `float.rs:765-796` — but it is never called (see D-16).
- Simple float placement cases are compatible: by trace, the four `tests/hand_written/floats.rs` scenarios (rule-5 ordering, zero-width clear, oversized float, rule-3/7 push-down) appear to pass because `float_ceiling` plus the side-inset scan reproduce them.
- `block.zig:343-370` tests 1-2 and `float.zig:434-455` assert aligned behavior.

## Missing or unimplemented

### B-1. Block formatting context inheritance / shared float context — **BLOCKER**
- **Rust:** `compute_block_layout` reuses the passed `BlockContext` unless the node establishes a new BFC (scroll container, `align-content`, `contain`) and propagates child float contributions and adjoining-float flags back to the parent (`block.rs:365-366,421-440,1286-1318`).
- **Zig:** `block_context` is discarded (`block.zig:158-161`); `compute_inner` always allocates a new BFC (`block.zig:202-205`); `compute/mod.zig:88` always passes `null`; `BlockContext.sub_context` (`block.zig:48-58`) and `find_bfc_slot` are never called.
- **Impact:** floats in a nested block are invisible to siblings and to the parent. `float_bfc_avoids_float_from_sibling_subtree`, `float_new_fc_separates`, `contain_layout_block_avoids_float`, `contain_*_block_contains_floats` cannot pass. Float height is not propagated to the containing BFC root (`block.rs:621-625`).
- **Severity:** BLOCKER

### B-2. Margin collapsing semantics — **BLOCKER**
- **Rust:** parent/child top/bottom collapse (`block.rs:533-555,638-640,708-727`), empty-block collapse-through (`block.rs:546-555,698-706`), clearance cancels collapsing (`block.rs:1373-1406,1584-1594`), self-collapsing-with-clearance does not escape the parent (`block.rs:1604-1618`), child `LayoutOutput.top_margin/bottom_margin/margins_can_collapse_through` are consumed (`block.rs:1325-1326,1560-1571`).
- **Zig:** only adjacent-sibling top/bottom collapse in a running `previous_bottom_margin` (`block.zig:174-186,252-297`). `can_be_collapsed_through` is assigned (`block.zig:235`) and never read; `measured.top_margin/bottom_margin/margins_can_collapse_through` from `leaf.zig:115-122` are ignored; the block's own output is `LayoutOutput.from_outer_size` with zero margins (`block.zig:213`).
- **Impact:** ~128 `block_margin_*` fixtures, `float_between_collapsing_margins`, `float_clear_*`, `float_forced_clearance_adjoining_float` fail. Any parent algorithm consuming child margins sees zero.
- **Severity:** BLOCKER

### B-3. Absolute positioning algorithm — **BLOCKER**
- **Rust:** resolves style/min/max/box-sizing/aspect-ratio, fills size from insets, measures via `measure_child_size_both`/`perform_child_layout` with `SizingMode::ContentSize`, expands auto margins, handles RTL/static position, writes padding/border/margin and overflow (`block.rs:1621-1888`).
- **Zig:** `place_absolute_child` only resolves sizing keywords, then sets `location`/`size` on the pre-walk layout (`block.zig:321-341`); no child layout call, no style-size clamp, no inset-fill (`left+right`), no auto margins, no aspect ratio, no min/max, no static position (`BlockItem.static_position` is never assigned), no RTL. Containing block is the content box, not the padding box (`block.zig:208`), so offsets are wrong by padding.
- **Impact:** ~64 `block_absolute_*` fixtures + `absolute/absolute_correct_cross_child_size_with_percentage` fail. E.g. `block_absolute_layout_within_border` expects x/y=10; Zig produces 20. `block_absolute_no_styles` expects y=10 (static position); Zig produces 0.
- **Severity:** BLOCKER

### B-4. Float height contribution and float-in-collapsing-margins placement — **BLOCKER**
- **Rust:** floats contribute to the BFC root height via `floated_content_height_contribution` maxed against content (`block.rs:621-625`); a float between collapsing margins is positioned at `committed_y_offset + active_collapsible_margin_set.resolve()` (`block.rs:1084-1098`).
- **Zig:** floats are added to `natural_height` as ordinary stacked children (`block.zig:174-186`), so float heights are summed with in-flow content instead of maxed; float `min_y` is the raw `cursor_y` with pending sibling margins ignored (`block.zig:260`).
- **Impact:** e.g. `float_after_sibling_bottom_margin` expects container 200x86 with float at y=36 and block at y=36 x=0; Zig yields height 116, float y=20, block x=50 width=150. `float_clear_negative_clearance` expects height 150; Zig sums to 225.
- **Severity:** BLOCKER

### B-5. Aspect ratio not applied by block — **BLOCKER**
- **Rust:** applied to container size, min/max, known dimensions, items, floats and absolute children (`block.rs:367,374-393,496-518,805-810,1646-1716`).
- **Zig:** `block.zig` never mentions `aspect_ratio`; only `leaf.zig:44-102` handles it for childless nodes.
- **Impact:** 21 `block_aspect_ratio_*` fixtures plus 9 absolute aspect fixtures fail whenever the node has children or is a container.
- **Severity:** BLOCKER

### B-6. Sizing keywords (min-content/max-content/fit-content/stretch/content) and stretch height — **BLOCKER**
- **Rust:** resolves keywords for items/floats/absolute via `resolve_sizing_keyword` + measure (`block.rs:887-900,922-936,1050-1058,1239-1271`).
- **Zig:** `resolve_stretch_height` (`block.zig:241-243`) is dead; child width is `style.size.width.resolve(...) orelse stretch` (`block.zig:280`), so every keyword degrades to auto/stretch; `resolve_sizing_keyword` is only reachable through the absolute stub.
- **Impact:** ~80 xml files named for intrinsic sizing (`block_width_keywords`, `block_absolute_width_keywords`, `block_intrinsic_*`); flex/grid keyword children also differ, but block-internal handling is the direct gap.
- **Severity:** BLOCKER

### B-7. Replaced elements and tables — **BLOCKER**
- **Rust:** `is_replaced`/`is_table` items are exempt from stretch sizing and keep intrinsic sizes (`block.rs:825,829-834,1233-1234,1296`).
- **Zig:** fields are populated (`block.zig:224-225`) and never used; width is forced to the stretch width after layout (`block.zig:280,293-294`).
- **Impact:** all 5 `block_replaced.rs` tests fail (`auto_width_uses_intrinsic_size` would return 600, not 142; `auto_margins_center_replaced_child` cannot center because auto margins resolve to 0 at `block.zig:313-315`).
- **Severity:** BLOCKER

### B-8. `align-content` and `text-align` passes — **BLOCKER**
- **Rust:** group-shift pass over in-flow items (`block.rs:650-695`) and legacy `TextAlign` shift (`block.rs:1472-1491`); `align-content != normal` also establishes a BFC (`block.rs:361-366`).
- **Zig:** neither style is read anywhere in `block.zig`; `BlockItem.final_layout` deferral exists but no post-loop pass.
- **Impact:** 20 `block_align_content_*` and 4 `block_text_align_*` fixtures fail; alignment inside blocks is always start/left.
- **Severity:** BLOCKER

### B-9. Baselines — **BLOCKER**
- **Rust:** first in-flow child baseline propagation, scroll-container clamping/synthesis, containment suppression (`block.rs:442-445,708-727,1493-1514`).
- **Zig:** `LayoutOutput.from_outer_size` (`block.zig:213`) never sets `baselines`; block never reads child `baselines`.
- **Impact:** 7 `block_align_baseline_*` fixtures and all `blockflex_baseline_*` fail when the baseline comes from a block child.
- **Severity:** BLOCKER

### B-10. Block-specific scrollable overflow — **MAJOR**
- **Rust:** computes the in-flow/absolute overflow rect with RTL mirroring, scroll-container padding extension, and unions it into the output (`block.rs:758-769,1530-1548,1865-1884`).
- **Zig:** a generic post-pass unions child border boxes (`compute/mod.zig:38-58`); it does not mirror RTL, does not subtract border from the scroll origin, does not extend scroll-container padding, and does not include absolute-item overflow separately.
- **Impact:** `scrollable_overflow`, `scroll_size`, `block_overflow_*` fixtures diverge.
- **Severity:** MAJOR

### B-11. Hidden children (`display:none`) item filtering/order and hidden-layout pass — **MAJOR**
- **Rust:** filters `BoxGenerationMode::None` before enumerating item order (`block.rs:802`) and runs hidden layout on them at the end (`block.rs:771-788`).
- **Zig:** includes all children in `generate_item_list` with raw index order (`block.zig:216-239`); hidden layouts happen only via the dispatcher pre-walk (`compute/mod.zig:64,130-137`) with order 0.
- **Impact:** `Layout.order` and paint order diverge for trees with hidden children; hidden children are laid out by the pre-walk rather than by the block phase.
- **Severity:** MAJOR

### B-12. `RunMode`/`ComputeSize`/requested-axis short-circuits — **MAJOR**
- **Rust:** early returns for fully known size, horizontal-only requests, and `ComputeSize` output carrying margins (`block.rs:406-419,572-580,729-735`).
- **Zig:** `compute_inner` ignores `run_mode`/`axis` entirely; the dispatcher always performs full layout.
- **Impact:** extra work and different measure-call counts; margin outputs absent when parents probe sizes (compounds B-2).
- **Severity:** MAJOR

### B-13. `resolve_absolute_sizing_keywords` is a stub — **MAJOR**
- **Rust:** up to three measure calls with correct available spaces, single both-axis measure, sizing mode, then aspect-ratio + clamp (`sizing_keyword.rs:58-151`).
- **Zig:** no tree/measure callback; `measure` resolutions are just `space.into_option()` and min-content/max-content resolve to nothing (`sizing_keyword.zig:39-60`).
- **Impact:** absolute min/max/fit-content sizing cannot work; also only the block caller exists.
- **Severity:** MAJOR

### B-14. Percentage height resolution for children — **MAJOR**
- **Rust:** `container_percentage_resolution_height` from definite height or style height, passed as `parent_size.height` (`block.rs:582-583,977-979`).
- **Zig:** always `parent_size = { .width = content_slot.width, .height = null }` (`block.zig:287`).
- **Impact:** `block_percentage_height_*`, `block_absolute_layout_percentage_height` fail; child `height: %` resolves as auto.
- **Severity:** MAJOR

### B-15. Min/max box-sizing adjustment, aspect ratio, and percentage basis — **MAJOR**
- **Rust:** min/max get `maybe_apply_aspect_ratio(...).maybe_add(box_sizing_adjustment)` and resolve against `parent_size` (`block.rs:374-393,498-507`).
- **Zig:** `clamp_resolved_size` gets raw min/max and resolves percentages against a fallback basis (available/own height) even when the parent axis is indefinite (`block.zig:194-195`; `dimension.zig:290-296`); children's min/max are resolved against basis 0 and dropped (`block.zig:227-228`).
- **Impact:** content-box min/max, percentage min/max at the root, and min/max overrides diverge.
- **Severity:** MAJOR

### B-16. Intrinsic width/height use stale pre-walk layouts, no measure, no float contribution — **MAJOR**
- **Rust:** `determine_content_based_container_width` measures each item under the correct constraint and adds `FloatIntrinsicWidthCalculator` (`block.rs:904-955`); height comes from final child layout (`block.rs:585-631`).
- **Zig:** natural sizes read `child.unrounded_layout` produced by the dispatcher pre-walk (`block.zig:174-186`), before the container knows the final width; `FloatIntrinsicWidthCalculator` is never instantiated; parent height is fixed before final child layout (`block.zig:193-198`).
- **Impact:** auto-width/auto-height containers with measures, percentages, wrapped text, or float rows compute the wrong size; `float_shrink_to_fit_*`, `xfloat_max_content` fail.
- **Severity:** MAJOR

### B-17. Float avoidance applied to all in-flow children (inverted BFC rule) — **MAJOR**
- **Rust:** normal in-flow blocks (`is_in_same_bfc`) stretch to the container and may overlap floats; only tables/replaced/BFC-establishing boxes use `find_bfc_slot` (`block.rs:1162-1228`).
- **Zig:** every non-floated child uses `find_content_slot` and is narrowed/offset beside floats (`block.zig:278-280`); the port's own test at `block.zig:384-395` codifies this (expects x=60 width=40).
- **Impact:** all normal block children beside floats are misplaced relative to Taffy (`float_after_sibling_bottom_margin` expects x=0 width=200), while BFC children happen to look right.
- **Severity:** MAJOR

### B-18. `find_bfc_slot` divergent and unused — **MAJOR**
- **Rust:** distinguishes `has_float` per side and handles positive/negative lead/trail margins (`float.rs:667-743`).
- **Zig:** always `max(insets, margin)` and has no `has_float` use (`float.zig:382-400`); dead because block never calls it.
- **Impact:** the whole `float_bfc_*_margin_*` fixture family cannot be reproduced even if plumbing is added.
- **Severity:** MAJOR

### B-19. Root block handling missing in `compute_root_layout` — **MAJOR**
- **Rust:** root block known dimensions include margin subtraction, `min_max_definite_size`, clamped style size, aspect ratio, and root `margin`/`scrollbar_size` are stored (`compute/mod.rs:67-121,132-167`).
- **Zig:** passes known dimensions `null` and stores only padding/border/scrollable overflow (`compute/mod.zig:94-128`); no margin/scrollbar size on the root layout.
- **Impact:** root percentage margins, aspect-ratio roots, and `layout(root).margin` diverge.
- **Severity:** MAJOR

### B-20. Cache contract bypassed; children laid out twice — **MAJOR**
- **Rust:** every child request goes through `compute_cached_layout` (`taffy_tree.rs:284-302`).
- **Zig:** only the root uses the cache (`compute/mod.zig:105`); every container first pre-walks all children through `compute_cached_layout` (`compute/mod.zig:73-84`) and then lays them out again with direct `compute_child_layout` calls (`block.zig:261,281`), which never consult or store cache.
- **Impact:** measure callbacks can fire extra times (observable in `TestNodeContext.count`), caches are effectively dead for descendants, and layout is O(repeated subtree work).
- **Severity:** MAJOR

### B-21. Minor omissions
- `find_content_slot` ignores `after` and the cleared-segment high-water mark (`float.zig:371-380` vs `float.rs:594-645`). **MINOR**
- Zero-height floats update `last_placed_floats` through `range_for_float` (`float.zig:273-274,296-305`) where Rust deliberately does not (`float.rs:466-478`). **MINOR**
- `next_obstacle_y` can overshoot: a tall right float blocked by a short left float advances by its own height, not to the obstacle bottom (`float.zig:250-264`); Rust's segment walk lands at the float bottom. **MAJOR** (wrong y in mixed-width float rows).
- `TaffyTree.compute_layout_with_measure` drops the measure-function parameter (`taffy_tree.zig:370-372` vs `taffy_tree.rs:897-905`). **MINOR/MAJOR** for measured block content.
- `LayoutInput.HIDDEN` / `RunMode.perform_hidden_layout` is never handled by the Zig dispatcher (`compute/mod.zig:62-91`). **MINOR**

## Present but behaviorally divergent

- `compute_block_layout` / `compute_inner` (`block.zig:158-214`): same names as `block.rs:348-791`, but the phase order is item-gen → pre-walk-derived natural size → sibling stack → abs offset; Taffy's style resolution, BFC selection, final-layout, alignment, hidden, and overflow phases are absent.
- `generate_item_list` (`block.zig:216-239`): same name, but no `box_generation_mode` filter, no style/min/max/aspect/box-sizing resolution, and it populates fields the rest of the file never reads.
- `perform_final_layout_on_in_flow_children` (`block.zig:249-299`): same name, but sibling-stack only; ignores `is_in_same_bfc`, clearance, adjoining floats, keyword widths, replaced/tables, insets, auto margins, text-align, baselines and margin sets.
- `perform_absolute_layout_on_absolute_children` (`block.zig:301-341`): same name, location-only, no layout/measure.
- `determine_content_based_container_width` (`block.zig:245-247`): same name; no measurement, no float intrinsic contribution, double-adds insets relative to Rust's `block.rs:904-955`.
- `resolve_stretch_height` (`block.zig:241-243`): same name, dead and parameterised differently (`block.rs:887-900`).
- `FloatContext.place_floated_box_inner` (`float.zig:282-294`): heuristic scan vs Taffy's segment/high-water-mark model (`float.rs:345-564`); simple cases match, complex ones do not.
- `find_content_slot` (`float.zig:371-380`): same name; no `after`, no `cleared_segment` hwm, no zero-width float segment seeding (`float.rs:594-645`).
- `resolve_absolute_sizing_keywords` (`sizing_keyword.zig:39-60`): same name/signature minus tree; stub (B-13).
- `TextAlign.from_str` (`style/block.zig:16-23`) accepts extra `-moz-*` spellings.
- `compute/mod.zig:38-58` generic overflow vs block-local overflow (B-10).
- `compute/block.zig:269,289` always pass `vertical_margins_are_collapsible = {false,false}`, so even a corrected leaf margin output could not collapse with a block parent.

## Test coverage comparison

- Rust in-file tests: 144 total; `compute/block.rs` 0, `compute/float.rs` 0.
- Rust hand-written suites: `tests/hand_written/floats.rs` 4, `block_replaced.rs` 5, `border_and_padding.rs` 4 (all `#[ignore]`), plus baseline (5), scrollable_overflow (9), scroll_size (10), relayout (8), caching (4), measure (16) that exercise block/float behavior.
- Rust XML fixture families: `tests/xml/block` 948 files (237 unique), `xml/float` 92 (23 unique), `xml/blockflex` 44 (11), `xml/blockgrid` 56 (14), `xml/contain` 32 (8). HTML fixtures: `test_fixtures/block` 237, `float` 27 (includes 4 `xfloat_*`), `blockflex` 11, `blockgrid` 14, `contain` 8, `absolute` 1.
- Zig: 86 `test` blocks total; `compute/block.zig` 5, `compute/float.zig` 1, plus a leaf margin test and a generic overflow test. There is **no XML/HTML fixture runner** anywhere in the port; `port.md:91` still lists "Taffy XML/HTML fixture families are executable against the Zig tree" as an open gate.
- No Zig test exists for: margin collapse through empty blocks, parent/child margin collapse, clearance (positive/negative/forced/adjoining), BFC establishment (`overflow`/`contain`/`align-content`), absolute layout (any fixture family), aspect ratio in block containers, align-content/text-align, baselines, replaced/table sizing, sizing keywords, percentage heights, auto margins, root block margins, or block-specific scrollable overflow.
- Zig's float-related tests are 5 block tests + 1 float-context test; `block.zig:384-395` asserts behavior opposite to Taffy for in-flow content beside floats.

## Feature flags / API surface affected

- Rust gates block/float/content_size behind `block_layout`, `float_layout`, `content_size`; the Zig port has no feature flags, so `float_layout`-off behavior (floats ignored, zero contribution) and `content_size`-off behavior cannot be selected.
- `compute_layout_with_measure` signature lacks the measure function (`taffy_tree.zig:370-372`); this blocks Taffy's replaced/measured block-child tests.
- `BlockContext`, `BlockFormattingContext`, `ContentSlot`, `BfcSlot`, `FloatContext`, `FloatIntrinsicWidthCalculator` are exported (`compute/mod.zig:5-9`) but the BFC/slot/intrinsic paths are unreachable from block layout.
- `style/block.zig:26-27` `BlockContainerStyle`/`BlockItemStyle` are empty structs; the real accessors live in `style/mod.zig:291-318` (the static audit's missing-method entries here are false positives).
- The static audit's `compute/float.rs` gap entry (`ContentSlot` missing `border_width`/`stretch_width`) and `Float` missing `Left`/`Right` are false positives: those fields belong to `BfcSlot`, and Zig has all three variants (`float.zig:27-33`, `style/float.zig:6-9`). Conversely, the audit has **no `compute/block.rs` section**, because name matching is complete.

## Evidence notes

- Read: `src/compute/block.zig`, `float.zig`, `compute/mod.zig`, `compute/common/{alignment,scrollable_overflow,sizing_keyword}.zig`, `compute/leaf.zig`, `tree/taffy_tree.zig`, `tree/layout.zig`, `style/{mod,block,float,dimension}.zig`, `port.md`, `audit/api_audit.md`; Rust `src/compute/block.rs`, `float.rs`, `compute/mod.rs`, `compute/common/*`, `style/{block,float}.rs`, `tests/hand_written/{floats,block_replaced,border_and_padding}.rs`, representative `tests/xml/{block,float,blockflex,contain}` and `test_fixtures/*`.
- Commands: `wc -l`, `grep -n` for symbol reachability (e.g. proving `item.*`, `aspect_ratio`, `text_align`, `align_content`, `resolve_stretch_height`, `FloatIntrinsicWidthCalculator` are unused in `block.zig`), `find`/`ls` fixture counts, `diff -q` (port copy is byte-identical to `zui/src/layout`).
- Not verified by execution: `zig` is not installed in this environment (`which zig` fails), so no `zig build test`; all behavioral claims are from code reading plus hand-tracing of representative fixtures (`float_after_sibling_bottom_margin`, `float_clear_negative_clearance`, `float_bfc_narrows_beside_float`, `block_absolute_layout_within_border`, `block_absolute_no_styles`, `block_replaced` scenarios). Claims about the four `floats.rs` tests are trace-based, marked accordingly.
- Could not exhaustively check all 237 block / 27 float fixtures; counts and categories are exact, per-fixture outcomes are illustrative, not exhaustive.
