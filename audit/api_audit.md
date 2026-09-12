# Static public-surface audit

Pinned Taffy: `/teamspace/studios/this_studio/zlay/.references/taffy/src`; port: `/teamspace/studios/this_studio/zlay/src`. Rust: 51 files / 26794 lines. Zig: 51 files / 18978 lines.

Names absent from Zig (production code only): 28 items, 16 types, 26 type members (fields/variants), 123 functions (public or private).

Unit tests in the same files: Taffy 144 `#[test]` fns vs port 88 `test` blocks (the port also has tests in files Taffy keeps untested).

## `compute/block.rs` -> `src/compute/block.zig` (1888 Rust / 2023 Zig lines; tests 0/13)

**Functions not found in Zig**

- `float_content_contribution`

## `compute/float.rs` -> `src/compute/float.zig` (797 Rust / 763 Zig lines; tests 0/3)

**Types with missing members (fields/variants)**

- `ContentSlot` (struct): `border_width`, `stretch_width` [Rust 5 / Zig 5]

## `compute/grid/track_sizing.rs` -> `src/compute/grid/track_sizing.zig` (1537 Rust / 1216 Zig lines; tests 0/2)

**Functions not found in Zig**

- `calc`
- `cmp_by_cross_flex_then_span_then_start`
- `grid_area_size`
- `has_auto_min_track_sizing_function`
- `has_max_content_min_track_sizing_function`
- `margins_axis_sums_with_baseline_shims`
- `max_content_contribution`
- `min_content_contribution`
- `minimum_contribution`

## `compute/grid/types/cell_occupancy.rs` -> `src/compute/grid/types/cell_occupancy.zig` (525 Rust / 292 Zig lines; tests 10/1)

**Functions not found in Zig**

- `fmt`

## `compute/grid/types/named.rs` -> `src/compute/grid/types/named.zig` (769 Rust / 375 Zig lines; tests 3/2)

**Types not found in Zig**

- `struct GridLineNames`
- `struct GridLineNamesIter`

**Functions not found in Zig**

- `borrow`
- `cmp`
- `eq`
- `fmt`
- `hash`
- `into_iter`
- `new`
- `partial_cmp`
- `populate_detailed_line_resolvers`

## `compute/grid/util/test_helpers.rs` -> `src/compute/grid/util/test_helpers.zig` (43 Rust / 9 Zig lines; tests 0/0)

**Functions not found in Zig**

- `into_grid`
- `into_grid_child`
- `into_oz`

## `compute/mod.rs` -> `src/compute/mod.zig` (346 Rust / 282 Zig lines; tests 1/6)

**Declarations not found in Zig**

- `mod detailed_info`

**Functions not found in Zig**

- `round_scrollable_overflow_rect`

## `geometry.rs` -> `src/geometry.zig` (754 Rust / 596 Zig lines; tests 0/2)

**Types not found in Zig**

- `struct Line`
- `struct MinMax`
- `struct Point`
- `struct Rect`
- `struct Size`

**Declarations not found in Zig**

- `const FALSE`
- `const NONE`
- `const TRUE`
- `const ZERO`
- `fn from_cross`
- `fn or`
- `fn union`

**Functions not found in Zig**

- `from`
- `from_cross`
- `or`
- `union`

## `style/alignment.rs` -> `src/style/alignment.zig` (850 Rust / 193 Zig lines; tests 20/2)

**Types with missing members (fields/variants)**

- `AlignItemsKeyword` (enum): `Start`, `End`, `FlexStart`, `FlexEnd`, `Center`, `Stretch`, `SpaceBetween`, `SpaceEvenly`, `SpaceAround` [Rust 9 / Zig 9]

**Declarations not found in Zig**

- `fn keyword`

**Functions not found in Zig**

- `deserialize`
- `expecting`
- `from_css`
- `keyword`
- `serialize`
- `visit_str`

## `style/available_space.rs` -> `src/style/available_space.zig` (163 Rust / 106 Zig lines; tests 0/1)

**Declarations not found in Zig**

- `fn or`

**Functions not found in Zig**

- `or`

## `style/block.rs` -> `src/style/block.zig` (64 Rust / 27 Zig lines; tests 0/0)

**Functions not found in Zig**

- `align_content`
- `clear`
- `float`
- `is_table`
- `text_align`

## `style/dimension.rs` -> `src/style/dimension.zig` (730 Rust / 413 Zig lines; tests 4/3)

**Declarations not found in Zig**

- `fn value`

**Functions not found in Zig**

- `deserialize`
- `from_css`
- `value`

## `style/flex.rs` -> `src/style/flex.zig` (293 Rust / 128 Zig lines; tests 3/1)

**Declarations not found in Zig**

- `trait FlexboxContainerStyle`
- `trait FlexboxItemStyle`

**Functions not found in Zig**

- `align_content`
- `align_items`
- `align_self`
- `flex_basis`
- `flex_direction`
- `flex_grow`
- `flex_line_count`
- `flex_shrink`
- `flex_wrap`
- `from_css`
- `gap`
- `justify_content`

## `style/float.rs` -> `src/style/float.zig` (80 Rust / 47 Zig lines; tests 0/0)

**Types with missing members (fields/variants)**

- `Float` (enum): `Left`, `Right` [Rust 2 / Zig 3]

## `style/grid.rs` -> `src/style/grid.zig` (1916 Rust / 1092 Zig lines; tests 6/3)

**Types not found in Zig**

- `enum GenericGridPlacement`
- `struct GridAutoTracks`
- `enum GridTemplateComponent`
- `struct InvalidStringRepetitionValue`

**Types with missing members (fields/variants)**

- `GenericGridTemplateComponent` (enum): `Single`, `Repeat` [Rust 2 / Zig 2]
- `GridAutoFlow` (enum): `Err` [Rust 1 / Zig 4]
- `GridTemplateAreas` (struct): `name`, `row_start`, `row_end`, `column_start`, `column_end` [Rust 5 / Zig 3]

**Declarations not found in Zig**

- `fn fit_content_px`
- `fn from_raw`
- `fn into_origin_zero`
- `fn resolve_absolutely_positioned_grid_tracks`
- `fn resolve_definite_grid_lines`
- `fn resolve_indefinite_grid_tracks`
- `trait GenericRepetition`
- `trait GridContainerStyle`
- `trait GridItemStyle`
- `trait TemplateLineNames`

**Functions not found in Zig**

- `align_content`
- `align_items`
- `align_self`
- `auto`
- `count`
- `default`
- `deserialize`
- `fit_content_px`
- `fmt`
- `from`
- `from_css`
- `from_raw`
- `gap`
- `grid_align_content`
- `grid_auto_columns`
- `grid_auto_flow`
- `grid_auto_rows`
- `grid_column`
- `grid_placement`
- `grid_placement_parser_saturates_numeric_values`
- `grid_row`
- `grid_template_area_column_count`
- `grid_template_area_row_count`
- `grid_template_areas`
- `grid_template_column_names`
- `grid_template_columns`
- `grid_template_row_names`
- `grid_template_rows`
- `grid_template_tracks`
- `into_origin_zero`
- `justify_content`
- `justify_items`
- `justify_self`
- `lines_names`
- `max_content`
- `min_content`
- `repetition_parser_saturates_numeric_values`
- `repetition_track_count_saturates`
- `resolve_absolutely_positioned_grid_tracks`
- `resolve_definite_grid_lines`
- `resolve_indefinite_grid_tracks`
- `tracks`
- `try_from`
- `try_parse_line_names`

## `style/mod.rs` -> `src/style/mod.zig` (1603 Rust / 742 Zig lines; tests 2/2)

**Types not found in Zig**

- `struct Contain`

**Types with missing members (fields/variants)**

- `Position` (enum): `BorderBox`, `ContentBox` [Rust 2 / Zig 2]

**Functions not found in Zig**

- `bitor`
- `bitor_assign`
- `default`
- `fmt`
- `from_css`

## `test.rs` -> `src/test.zig` (174 Rust / 153 Zig lines; tests 0/1)

**Types with missing members (fields/variants)**

- `TestMeasureData` (enum): `Size` [Rust 1 / Zig 4]

## `tree/cache.rs` -> `src/tree/cache.zig` (362 Rust / 222 Zig lines; tests 4/1)

**Declarations not found in Zig**

- `fn new`

**Functions not found in Zig**

- `from`
- `new`
- `parent_size`

## `tree/layout.rs` -> `src/tree/layout.zig` (408 Rust / 173 Zig lines; tests 0/2)

**Types with missing members (fields/variants)**

- `RunMode` (enum): `ContentSize`, `InherentSize` [Rust 2 / Zig 1]

**Functions not found in Zig**

- `try_from`

## `tree/node.rs` -> `src/tree/node.zig` (60 Rust / 12 Zig lines; tests 0/0)

**Types not found in Zig**

- `struct NodeId`

**Functions not found in Zig**

- `from`

## `tree/taffy_tree.rs` -> `src/tree/taffy_tree.zig` (1431 Rust / 634 Zig lines; tests 29/4)

**Types not found in Zig**

- `enum TaffyError`
- `struct TaffyTreeChildIter`

**Declarations not found in Zig**

- `fn get_disjoint_node_context_mut`

**Functions not found in Zig**

- `compute_block_child_layout`
- `fmt`
- `get_disjoint_node_context_mut`
- `mark_dirty_recursive`

## `tree/traits.rs` -> `src/tree/traits.zig` (421 Rust / 189 Zig lines; tests 0/0)

**Functions not found in Zig**

- `compute_block_child_layout`
- `get_block_child_style`
- `get_block_container_style`
- `get_core_container_style`
- `get_flexbox_child_style`
- `get_flexbox_container_style`
- `get_grid_child_style`
- `get_grid_container_style`

## `util/mod.rs` -> `src/util/mod.zig` (36 Rust / 17 Zig lines; tests 0/1)

**Functions not found in Zig**

- `deserialize_from_str`

## `util/parse.rs` -> `src/util/parse.zig` (118 Rust / 80 Zig lines; tests 0/1)

**Types not found in Zig**

- `struct ParseError`

**Functions not found in Zig**

- `from`

## `util/sys.rs` -> `src/util/sys.zig` (279 Rust / 41 Zig lines; tests 0/0)

**Declarations not found in Zig**

- `const MAX_CHILD_COUNT`
- `const MAX_GRID_TRACKS`
- `const MAX_NODE_COUNT`
