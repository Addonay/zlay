# Style/geometry core parity audit

## Verdict

**No — not complete parity, but the gap is not where the static audit says it is.** Every default-reachable `Style` field exists with the exact same type shape and default value as Rust's all-default-features build (43/43 fields verified field-by-field; see the table below), and the enums `Display`, `BoxSizing`, `Position`, `Overflow`, `Direction`, `BoxGenerationMode`, `Float`, `Clear`, all alignment types, `Contain`, and the `CompactLength` tag set are present and semantically aligned. The static audit's headline style findings are false positives: `Position` in this rev has only `Relative`/`Absolute` (`BorderBox`/`ContentBox` belong to `BoxSizing`), `Line`/`Point`/`Rect`/`Size`/`MinMax` exist as Zig generic functions, `Contain` exists as a packed struct, `AlignItemsKeyword` has all 9 variants, `Float` has all 3 variants, and `AvailableSpace::or` exists. The real parity gaps are understated by names: (1) **`calc` values are representable but never resolved** — the layout paths silently treat them as `auto`/`null` and `TaffyTree.resolve_calc_value` is a stub returning 0 (`calc` is a default Cargo feature); (2) **`Style.is_block` wrongly returns true for `display: flow-root`**, breaking margin-collapsing/BFC semantics; (3) **serde is entirely absent**; (4) `util/math.zig`'s `maybe_max` and min-only `maybe_clamp` invert Rust semantics; (5) several parser edge cases and `compact_length.resolved_percentage_size` differ; (6) custom-ident generics and the trait-based low-level style API are replaced by concrete `Style` + `[]const u8` records. None of these are caught by the name-based audit, and the ~57 Rust unit tests for these files have only 12 Zig counterparts.

## Covered and behaviorally aligned

- **`Style` field set and defaults.** All fields at Rust `style/mod.rs:598-760` (`DEFAULT` at 764-839) have Zig counterparts at `style/mod.zig:320-366` with identical default values for the default-feature build: `display=Flex`, `item_is_table=false`, `item_is_replaced=false`, `box_sizing=BorderBox`, `direction=Ltr`, `overflow=Visible/Visible`, `scrollbar_width=0`, `contain=NONE`, `float=None`, `clear=None`, `position=Relative`, all-auto `inset`, all-auto `size/min_size/max_size`, `aspect_ratio=None`, zero `margin/padding/border/gap`, all alignment `None`, `text_align=Auto`, `flex_direction=Row`, `flex_wrap=NoWrap`, `flex_line_count=1`, `flex_basis=AUTO`, `flex_grow=0`, `flex_shrink=1`, empty grid template/auto vector fields, `grid_auto_flow=Row`, `grid_template_areas=None`, `grid_row/column=Auto/Auto`. (Full table under "Present but behaviorally divergent".)
- **`Contain`** modeled as `packed struct(u8)` (`style/mod.zig:41-101`); bit layout matches Rust `Contain(u8)` (`style/mod.rs:429-443`): layout=bit0, paint=bit1; `NONE/LAYOUT/PAINT/CONTENT/DEFAULT`, `contains`, `intersects`, `union`, `establishes_independent_formatting_context`, `suppresses_baseline`, `contains_scrollable_overflow` all present and correct. `BitOr`/`BitOrAssign` are Rust operator traits; Zig uses the named `union` method (language difference, not a gap).
- **`Position`** (`style/mod.zig:17`) = `{relative, absolute}` matches Rust `style/mod.rs:299-312` exactly (the audit's `BorderBox`/`ContentBox` claim is a type-attribution error; those are `BoxSizing` variants at `style/mod.rs:333-341`).
- **`Display`, `BoxSizing`, `Overflow`, `Direction`, `BoxGenerationMode`** variants complete (`style/mod.zig:15-40`); `Overflow.is_scroll_container`/`maybe_into_automatic_min_size`, `Direction.is_rtl` match (`style/mod.rs:381-401`, 567-573). `BoxGenerationMode` accessor matches Rust (`style/mod.zig:370-372` vs `style/mod.rs:852-857`).
- **`CoreStyle`/`Flexbox*`/`Grid*`/`Block*` accessors** exist as wrapper records (`style/mod.zig:108-318`) and their per-field behavior matches the Rust trait impls (`style/mod.rs:848-1405`), including `grid_align_content` defaulting to `Stretch` (`style/mod.zig:264-266` vs `style/grid.rs:262-269`).
- **Alignment** (`style/alignment.zig`): both keyword enums, all variants; `AlignmentSafety{unsafe,safe}`; all plain and `SAFE_*` constants; `is_safe`, `keyword_value` (= Rust `keyword()`), `resolve_self_relative` (direction flip only in inline axis, safety preserved) match Rust `style/alignment.rs:24-236`. `AlignContentKeyword.reversed` matches Rust `style/alignment.rs:90-106`, including `Stretch -> End`. Parsers replicate the accept/reject matrix: `safe`/`unsafe` prefixed position keywords accepted, `safe|unsafe + baseline|stretch|space-*` rejected (`alignment.zig:154-176` vs `alignment.rs:239-414`).
- **`AvailableSpace`** (`style/available_space.zig`): all variants and operations present — `is_definite`, `into_option`, `unwrap_or`, `unwrap` (panics like Rust), **`or`** (`available_space.zig:38-40`; the audit wrongly lists it missing), `or_else`, `unwrap_or_else`, `maybe_set`, `map_definite_value`, `compute_free_space` (MaxContent → +inf, MinContent → 0), `is_roughly_equal` (f32 EPSILON), `From<f32>`/`From<Option<f32>>` as `from`, plus `into_options` for `Size`. Matches `style/available_space.rs:23-162`.
- **`CompactLength`** (`style/compact_length.zig`): all 13 semantic tags (`CompactLengthTag`, `compact_length.zig:125-138`) carry the exact Rust tag bit values (`compact_length.rs:212-238`); all predicates present with matching sets (`is_sizing_keyword`, `is_max_or_fit_content`, `is_max_content_alike`, `is_min_or_max_content`, `is_intrinsic`, `is_zero`, `is_fr`, `uses_percentage`, `is_calc`); `serialized`/`from_serialized` reproduce Rust's 64-bit wire layout `(tag << 32) | f32_bits` for value-bearing tags (verified analytically against `compact_length.rs:113-125, 549-567`), with a Zig wire test.
- **`Dimension` family** (`style/dimension.zig`): `LengthPercentage`, `LengthPercentageAuto`, `Dimension` all wrap `CompactLength`; constructors `length/percent/auto/min_content/max_content/fit_content/fit_content_px/fit_content_percent/stretch/content/calc` open on `Dimension`, with `into_option` (length only, Rust `grid`-gated), `is_auto`, `is_sizing_keyword`, `is_stretch`, `is_content`, `tag`, `expand`; `Rect<Dimension>::from_length/from_percent` and `Size<Dimension>::from_lengths/from_percent` equivalents exist (`dimension.zig:338-344`, `geometry.zig:380-390`). Non-calc `MaybeResolve` behavior matches Rust: length → `Some`, percent → context map, auto/content/intrinsic keywords → `None` (`dimension.zig:196-206` vs `dimension.rs:57-76`, `util/resolve.rs:28-76`).
- **`geometry.zig`**: all primitives and helpers from `geometry.rs` are present under Zig spellings (`AbsoluteAxis`, `AbstractAxis`, `InBothAbsAxis`, `Rect`, `Line`, `Size`, `Point`, `MinMax`): `get_abs`, `grid_axis_sum`, `map`, `horizontal/vertical_components`, `sum_axes`, `main_axis_sum`, `cross_axis_sum`, `main/cross_start/end`, `union` (f32 result identical), `zero` constants, `Size` `f32_max/f32_min/has_non_zero_area`, `maybe_apply_aspect_ratio` (method matches Rust exactly), `unwrap_or`/`or`/`both_axis_defined`, `from_cross`, `map_width/map_height/zip_map`, flex/AbstractAxis accessors, `Point` accessors/`transpose`, `Point → Size`, `Line::map/sum`, bool-line constants.
- **`style_helpers.zig`**: `zero/auto/min_content/max_content/length/percent/fit_content/fr/flex/line/span/minmax/repeat/evenly_sized_tracks` all exist (`style_helpers.zig:7-92`); behavior matches for the concrete types used by the port.

## Missing or unimplemented

- **`calc()` resolution is not implemented (default feature).** Rust: `LengthPercentage::calc`/`LengthPercentageAuto::calc`/`Dimension::calc` are usable constructors (`style/dimension.rs:61-65, 214-218, 468-474`), `CompactLength::calc` (`style/compact_length.rs:260-266`), and every resolution path threads a `calc` closure (`util/resolve.rs:15, 31-38, 50-52, 68-69`) plus `LayoutPartialTree::calc` (`tree/traits.rs:409-417`). Zig: only `Dimension.calc` (`style/dimension.zig:173-175`), `CompactLength` calc (`style/compact_length.zig:199-201`) and grid track calc exist; `LengthPercentage`/`LengthPercentageAuto` have **no** calc constructor; `Dimension.resolve` returns `null` for calc (`dimension.zig:196-206`), `compact_length.resolved_percentage_size` ignores it (`compact_length.zig:95-101`), `util/resolve.zig:59-82` falls into `unreachable`/`null`, and `TaffyTree.resolve_calc_value` is a stub returning 0 (`tree/taffy_tree.zig:326-329`; trait default 0 at `tree/traits.zig:94-96`). **Impact:** a style containing a calc size is accepted and laid out as `auto`/0 instead of the resolved value — silently wrong layout for a default-feature API. **Severity: BLOCKER** (for the `calc` feature; if calc is intentionally out of scope it must fail loudly rather than silently, per `port.md`'s own gate).
- **serde integration is absent.** Rust derives/serializes `Style` (`style/mod.rs:54-55, 196-197, 596-597`), `Dimension`/`LengthPercentage*` with tag validation (`dimension.rs:129-143, 308-322, 612-638`), `CompactLength` custom wire format (`compact_length.rs:549-597`), geometry (`geometry.rs:106-107, 315-317, 352-353, 651-652, 747-748`), and hand-written `AlignItems`/`AlignContent` visitors (`alignment.rs:431-585`). Zig has no serde layer; only `CompactLength.serialized/from_serialized` helpers exist (`compact_length.zig:103-164`) and `serialized()` returns `0` for calc instead of an error. **Impact:** serde users cannot serialize/deserialize styles; wire tests impossible. **Severity: MAJOR.**
- **`FromStr` coverage for keyword enums.** Rust parses `Display` (`style/mod.rs:239-250`), `Position` (314-318), `BoxSizing` (343-347), `Overflow` (403-409), `Direction` (575-579). Zig has `from_str` only for `Contain`, `Dimension`, `LengthPercentage*` (`style/mod.zig:52`, `dimension.zig:27/81/156`), `AvailableSpace`, `AlignItems/AlignContent`, `FlexDirection/FlexWrap`, grid types, `Float/Clear/TextAlign`. **Impact:** `parse`-feature parity gap; users cannot parse `display`, `position`, `box-sizing`, `overflow`, `direction` keywords. **Severity: MINOR.**
- **`FlexWrap` compound parsing.** Rust (with default `flexbox_balance`) parses multi-keyword forms: `"wrap balance"` → `Balance`, `"wrap-reverse balance"` → `BalanceReverse`, rejects duplicates/`"nowrap balance"` (`style/flex.rs:142-183`). Zig `FlexWrap.from_str` only accepts the five bare keywords, including `"balance"`/`"balance-reverse"` (`style/flex.zig:55-63`). **Impact:** CSS `flex-wrap: wrap balance` not parseable. **Severity: MINOR.**
- **Calc-era API pieces:** `ExpandedDimension.Calc(*const ())` carries the handle in Rust (`dimension.rs:583-584`) and `From<ExpandedDimension>` reconstructs it (593-609); Zig's `.calc` variant has no payload (`dimension.zig:264-276`) and `dimension_from_expanded` panics for calc (`dimension.zig:358-359`). `LengthPercentage`/`LengthPercentageAuto` also lack the Rust `unsafe from_raw` (`dimension.rs:67-73, 220-226`). **Severity: MINOR** (subset of the calc blocker).
- **`Size<AvailableSpace>::maybe_set` / `into_options` as `Size` methods.** Rust (`available_space.rs:153-162`) implements `into_options` and `maybe_set` on `Size<AvailableSpace>`; Zig only has a free `into_options` (`available_space.zig:94-96`) and `AvailableSpace.maybe_set`; `Size.maybe_set` is missing. Zig callers inline their own equivalent. **Severity: MINOR.**
- **`MaybeResolve`/`ResolveOrZero` generic composition.** Rust implements `MaybeResolve` for `Size<T>` against `Size<In>` (`util/resolve.rs:88-97`) and `ResolveOrZero` for `Size<In>→Size<Out>` and for `Rect<T>` against `Size<In>`, `Option<f32>` and `f32` (`resolve.rs:120-168`). Zig's `util/resolve.zig` only dispatches scalar types and a uniform-`?f32` `resolve_rect_or_zero` (`resolve.zig:9-20, 94-110`); it has no Size-context `Rect` or `Size` composition, and (like all of `util/math.zig`/`util/resolve.zig`) it is **not imported by any compute file** — the algorithms re-implement resolution inline. **Impact:** low-level/API parity only today, but it means the "literal" helper layer is not the one being exercised. **Severity: MINOR.**
- **Custom-ident generics and trait-based low-level style API.** Rust `Style<S: CheapCloneStr>` is generic over the ident type and the low-level algorithms are generic over `impl CoreStyle`/`Flexbox*`/`Grid*`/`Block*` traits with default implementations (`style/mod.rs:595-1405`); `LayoutPartialTree::get_style` is associated-type generic. Zig fixes `CheapCloneStr = []const u8` (`style/mod.zig:107`), `Style` is concrete, the `CoreStyle` etc. records embed `value: Style` (`style/mod.zig:108-318`), and `LayoutPartialTree.get_style` returns concrete `style.Style` (`tree/traits.zig:72, 90`). **Impact:** custom tree/style implementations cannot supply their own style objects; API incompatibility for low-level embedders. **Severity: MAJOR** (possibly intentional language mapping; recorded factually).
- **Feature-dependent defaults / const.** Rust `Display::DEFAULT` varies with enabled features (`style/mod.rs:215-231`) and `Style::DEFAULT` is a `const` (762-840). Zig hard-codes `.flex` and has no `Style.DEFAULT` const (only `Style{}` defaults). **Impact:** only builds that disable flexbox differ. **Severity: MINOR.**
- **`style_helpers` genericity and ownership.** Rust helpers are generic over output type (`length/percent/zero/auto/min_content/max_content` at `style_helpers.rs:95-97, 155-159, 214-218, 274-278, 408-412, 489-493`), `repeat` accepts `u16` or `"auto-fit"/"auto-fill"` via `TryInto<RepetitionCount>` (22-34), and `evenly_sized_tracks` returns an owned `Vec` (36-45). Zig helpers return concrete `Dimension`/`TrackSizingFunction` (`style_helpers.zig:18-56`), `repeat` takes `u16` only (54-56), and `evenly_sized_tracks` allocates with `std.heap.page_allocator` and leaks (82-88). **Severity: MINOR.**
- **`document-features` docs and root/prelude export deltas.** Rust gates feature docs (`lib.rs:60-61`) and re-exports `ParseError`/`ParseResult`, `print_tree`, and the whole `util::*` helper namespace at crate root (`lib.rs:126-133`); the prelude exports `Line`, `FromLength`, `FromPercent`, `FromFr`, `TaffyAuto`, `TaffyFitContent`, `TaffyMinContent`, `TaffyMaxContent`, `TaffyZero`, `TaffyGridLine`, `TaffyGridSpan`, `evenly_sized_tracks` (`prelude.rs:3-28`). Zig `root.zig`/`prelude.zig` omit those (`prelude.zig:8-70` has no `Line`, no trait markers, no `evenly_sized_tracks`; `root.zig` has no `ParseError`/`ParseResult`/`print_tree`). **Severity: MINOR.**

## Present but behaviorally divergent

### `Style` field-by-field default comparison (Rust `style/mod.rs:598-839` vs Zig `style/mod.zig:320-366`; all-features/default build)

| Field | Rust type → default | Zig type → default | Verdict |
|---|---|---|---|
| `dummy` | `PhantomData<S>` | absent | N/A (language) |
| `display` | `Display` → `Flex` | `Display` → `.flex` | OK |
| `item_is_table` | `bool` → false | `bool` → false | OK |
| `item_is_replaced` | `bool` → false | `bool` → false | OK |
| `box_sizing` | `BoxSizing` → `BorderBox` | → `.border_box` | OK |
| `direction` | `Direction` → `Ltr` | → `.ltr` | OK |
| `overflow` | `Point<Overflow>` → Visible/Visible | same → visible/visible | OK |
| `scrollbar_width` | `f32` → 0.0 | `f32` → 0 | OK |
| `contain` | `Contain` → `NONE` | packed struct → all false | OK |
| `float` | `Float` → `None` (float_layout) | → `.none` | OK |
| `clear` | `Clear` → `None` | → `.none` | OK |
| `position` | `Position` → `Relative` | → `.relative` | OK |
| `inset` | `Rect<LengthPercentageAuto>` → auto ×4 | same → auto ×4 | OK |
| `size` | `Size<Dimension>` → auto ×2 | same → auto ×2 | OK |
| `min_size` | `Size<LengthPercentageAuto>` → auto ×2 | same | OK |
| `max_size` | `Size<LengthPercentageAuto>` → auto ×2 | same | OK |
| `aspect_ratio` | `Option<f32>` → None | `?f32` → null | OK |
| `margin` | `Rect<LengthPercentageAuto>` → zero (=len 0) | same → len 0 ×4 | OK |
| `padding` | `Rect<LengthPercentage>` → zero | same → len 0 ×4 | OK |
| `border` | `Rect<LengthPercentage>` → zero | same → len 0 ×4 | OK |
| `align_items` | `Option<AlignItems>` → None | `?AlignItems` → null | OK |
| `align_self` | `Option<AlignSelf>` → None | `?AlignSelf` → null | OK |
| `justify_items` | `Option<AlignItems>` → None | `?JustifyItems` → null | OK |
| `justify_self` | `Option<AlignSelf>` → None | `?JustifySelf` → null | OK |
| `align_content` | `Option<AlignContent>` → None | `?AlignContent` → null | OK |
| `justify_content` | `Option<JustifyContent>` → None | `?JustifyContent` → null | OK |
| `gap` | `Size<LengthPercentage>` → zero | same → len 0 ×2 | OK |
| `text_align` | `TextAlign` → `Auto` | → `.auto` | OK |
| `flex_direction` | `FlexDirection` → `Row` | → `.row` | OK |
| `flex_wrap` | `FlexWrap` → `NoWrap` | → `.no_wrap` | OK |
| `flex_line_count` | `u16` → 1 (`flexbox_balance`) | `u16` → 1 | OK |
| `flex_basis` | `Dimension` → `AUTO` | → `.auto` | OK |
| `flex_grow` | `f32` → 0.0 | `f32` → 0 | OK |
| `flex_shrink` | `f32` → 1.0 | `f32` → 1 | OK |
| `grid_template_rows` | `GridTrackVec<GridTemplateComponent<S>>` → empty | `[]const GridTemplateComponent` → `&.{}` | OK (non-generic) |
| `grid_template_columns` | same → empty | same | OK |
| `grid_auto_rows` | `GridTrackVec<TrackSizingFunction>` → empty | `[]const TrackSizingFunction` → empty | OK |
| `grid_auto_columns` | same → empty | same | OK |
| `grid_auto_flow` | `GridAutoFlow` → `Row` | → `.row` | OK |
| `grid_template_areas` | `Option<GridTemplateAreas<S>>` → None | `?GridTemplateAreas` → null | OK |
| `grid_template_column_names` | `GridTrackVec<GridTrackVec<S>>` → empty | `[]const GridTemplateLineNames` → empty | OK |
| `grid_template_row_names` | same → empty | same | OK |
| `grid_row` | `Line<GridPlacement<S>>` → Auto/Auto | same → auto/auto | OK |
| `grid_column` | same → Auto/Auto | same | OK |

No default value differs for the default build. There is no `order` field in this Taffy rev (so nothing to compare; the prompt's mention is a version mismatch).

### Semantics that diverge even though the item exists

- **`Style.is_block` includes `flow_root`.** Rust: `matches!(self.display, Display::Block)` — the doc explicitly says `flow-root` must **not** be treated as block so it forms a new BFC (`style/mod.rs:95-103, 858-862`); used by leaf margin collapsing (`compute/leaf.rs:78`) and block item generation/BFC membership (`compute/block.rs:546, 823-834`). Zig: `self.display == .block or self.display == .flow_root` (`style/mod.zig:374-376`, free fn 527-529). **Impact:** `display: flow-root` nodes can be collapsed through / treated as in the parent BFC, producing wrong margins/blocks. **Severity: MAJOR.**
- **`Contain.from_str` accepts invalid inputs.** Rust errors for `""` (`style/mod.rs:1516`) and for `content` followed by anything (`"content layout"`, `"content paint"`, `"content style"`; 1521-1522, enforcement at 520-528). Zig returns `NONE` for empty input (loop never entered then `return result`, `style/mod.zig:52-78`) and accepts `"content paint"`/`"content style"` because only `seen != 0` (not exhaustion) is checked for `content` (`mod.zig:60-63`). Separators are only space/tab, not all CSS whitespace. **Severity: MINOR.**
- **`AvailableSpace.from_css` accepts values Rust rejects.** Rust requires `value >= 0.0` for Number/Dimension tokens and is case-sensitive for `min-content`/`max-content` (`style/available_space.rs:38-49`). Zig `std.fmt.parseFloat` accepts negatives, `inf`, `nan`, and all keyword comparisons are case-insensitive (`available_space.zig:87-92`). **Severity: MINOR.**
- **`CompactLength::resolved_percentage_size` differs.** Rust resolves only `PERCENT_TAG` (and calc when enabled), returning `None` for `fit_content_percent` (`style/compact_length.rs:497-508`). Zig resolves `.fit_content_percent` too and returns `null` for calc (`style/compact_length.zig:95-101`). Used only through `MinTrackSizingFunction`/`MaxTrackSizingFunction` wrappers (`style/grid.zig:453, 596`), and no compute caller was found, so current impact is API-level. **Severity: MINOR** (escalate if grid code starts using it).
- **`MaybeMath` inversions in `util/math.zig`.** Rust `Option<f32>::maybe_max` returns `None` whenever the left side is `None` (`util/math.rs:38-45`); Zig `maybe_max` returns the right value for `(None, Some)` (`util/math.zig:13-16`, asserted by its own test at line 138). Rust's min-only clamp is `self.max(min)` (`math.rs:47-55, 113-120` for f32, 197-206 for AvailableSpace); Zig `option_maybe_clamp`/`f32_maybe_clamp`/`available_maybe_clamp` compute `@min(max orelse v, @max(min orelse v, v))`, which returns `v` instead of raising it to `min` when `max` is `None` and `min > v` (`math.zig:33-36, 65-67, 91-97`). No production file imports `util/math.zig`, but `compute/leaf.zig:172-175` re-derives the same RHS-wins `max_optional`, and uses it in the early-return path (`leaf.zig:55-60`) that Rust's leaf does not have (`compute/leaf.rs:61, 95-111`). **Severity: MAJOR** (wrong helper semantics; reachable through the leaf re-implementation).
- **Aspect-ratio guards not in Rust.** Rust `Size::<Option<f32>>::maybe_apply_aspect_ratio` divides/multiplies for any `Some(ratio)` including 0 or negatives (`geometry.rs:604-613`); Zig adds `if (ratio <= 0) return value` in the free helper (`geometry.zig:475-481`) and `if (r > 0)` in `compute/leaf.zig:153-159` (the `Size` method itself at `geometry.zig:292-297` matches Rust). Rust leaf additionally transfers aspect ratio to `min_size` before box-sizing adjustment (`compute/leaf.rs:48-59`), while Zig applies it only to `node_size` after the box-sizing add; `max_size` is not transferred in either. **Severity: MINOR** for ratio ≤ 0; the leaf ordering difference is an algorithm-level divergence (cross-boundary note for the leaf/block audit).
- **`Dimension.from_str` fit-content parsing.** Rust/cssparser accepts nested whitespace and tokenizes normally (`style/dimension.rs:357-386`). Zig uses prefix/suffix string tests and only accepts `fit-content(<number>%|px)` with no interior whitespace, while its `parse_numeric` can accept `"inf"`/`"nan"` (`dimension.zig:156-172`). **Severity: MINOR.**
- **`TextAlign.from_str` accepts `-moz-*` aliases.** Rust parses only `auto`, `-webkit-left`, `-webkit-right`, `-webkit-center` (`style/block.rs:58-64`). Zig accepts `-moz-left/right/center` too (`style/block.zig:19-21`). **Severity: MINOR.**
- **`CompactLength.serialized` on calc.** Rust errors (`compact_length.rs:555-559`); Zig returns `0` (`compact_length.zig:103-118`). `from_serialized` panics on unknown/calc instead of returning an error (`compact_length.zig:147-164`). **Severity: MINOR** (subset of serde/calc gaps).
- **Extra, unused `dimensionToAvailable`.** Zig `style/dimension.zig:278-284` maps everything except `min_content`/`max_content` (including length/percent/auto/fit-content/stretch) to `.max_content`; there is no Rust counterpart (Rust leaf maps `Option<f32>` via `AvailableSpace::from`, `compute/leaf.rs:117,127`). No caller exists. **Severity: MINOR** (dead, misleading helper).

## Test coverage comparison

Counts are `#[test]` functions (Rust) vs top-level `test` blocks (Zig) in the corresponding files.

| File | Rust tests | Zig tests | Notable Rust behaviors with no Zig test |
|---|---|---|---|
| `style/mod.rs` | 3 | 2 | `defaults_match` (asserts **every** field of `DEFAULT` against a literal), `style_sizes` (size budget), full `parse_contain` matrix (17 asserts; Zig has 2) |
| `style/alignment.rs` | 20 | 2 | `is_safe` matrix, `keyword()` stripping, `resolve_self_relative` (8 cases), `AlignContentKeyword::reversed`, parse matrix for both types, serde round-trips, size budget |
| `style/available_space.rs` | 0 | 1 | — (Zig has coverage Rust lacks) |
| `style/compact_length.rs` | 0 | 1 | — (Zig adds a wire-tag test; no Rust counterpart) |
| `style/dimension.rs` | 4 | 2 | `expand`/`From` round-trips for all keywords (`dimension.rs:679-729`) |
| `style_helpers.rs` | 3 | 0 | `repeat` (u16 / auto-fit / auto-fill) |
| `geometry.rs` | 0 | 2 | — (Zig has coverage Rust lacks) |
| `util/resolve.rs` | 15 | 0 | all `maybe_resolve`/`resolve_or_zero` dimension/Size/Rect cases |
| `util/math.rs` | 12 | 1 | `maybe_min/max/add/sub` for all LHS/RHS combinations (would catch the `maybe_max` inversion) |
| `util/parse.rs` | 0 | 1 | — |
| **Total** | **57** | **12** | |

Rust categories with no Zig coverage: default-value equivalence, memory layout, safe/unsafe alignment behavior, self-relative alignment resolution, dimension expand round-trips, `MaybeResolve`/`ResolveOrZero`, `MaybeMath`, style-helper constructors. There is no Zig test asserting `flow_root`/`is_block`, `Contain.from_str` rejection cases, or calc behavior (unsurprising, since calc resolution doesn't exist).

## Feature flags / API surface affected

Cargo features from `.references/taffy/Cargo.toml` (`[features]`, line ~40+) and Zig status:

| Cargo feature | Zig status |
|---|---|
| `default` (`std`, `taffy_tree`, `flexbox`, `flexbox_balance`, `grid`, `block_layout`, `float_layout`, `calc`, `content_size`, `detailed_layout_info`) | Zig always compiles the default algorithm set (no feature gates); equivalent for default consumers except `calc` (broken) |
| `block_layout` | Present, always enabled (`style/block.zig`, `compute/block.zig`) |
| `float_layout` | Present, always enabled (`style/float.zig`, `compute/float.zig`) |
| `flexbox` | Present, always enabled |
| `flexbox_balance` | Partial: `FlexWrap.balance/balance_reverse`, `is_balance`, `flex_line_count` present (`style/flex.zig:38-54`, `style/mod.zig:353`); compound CSS parser missing; compute behavior not verified here (flex audit) |
| `grid` | Present, always enabled |
| `calc` | **Partial/broken:** representation on `CompactLength`/`Dimension`/grid track functions; no `LengthPercentage`/`LengthPercentageAuto` calc ctor; no resolution path; `TaffyTree.resolve_calc_value` returns 0; serde rejects calc (no serde) |
| `content_size` | Present: `LayoutOutput.content_size` always exists (`tree/layout.zig:112`); algorithms not verified to populate it (other audits) |
| `detailed_layout_info` | Partial: `DetailedLayoutInfo` union + accessor (`tree/layout.zig:156`, `tree/taffy_tree.zig:39, 260`) and `set_detailed_grid_info` seam (`tree/traits.zig:75, 110`); static audit reports no `compute/detailed_info` module |
| `strict_provenance` | N/A (Zig has no tagged pointers/unsafe provenance; `compact_length` uses an explicit union) |
| `taffy_tree` | Present, always enabled |
| `serde` | **Absent** (no serde integration anywhere; only CompactLength wire helpers) |
| `parse` | Partial: `from_str` for many types; missing `Display`, `BoxSizing`, `Position`, `Overflow`, `Direction`; `FlexWrap` compound form; `Style` itself has no parser in either (Rust parses individual fields) |
| `parse_faster` | N/A (cssparser-specific) |
| `std` | N/A: Zig always uses `std`; there is no `no_std` configuration |
| `alloc` | N/A: allocation is explicit via `std.mem.Allocator` (but `style_helpers.evenly_sized_tracks` uses `page_allocator`) |
| `debug` | `util/debug.zig` exists (same file-level destination) |
| `profile` | N/A (Rust tooling only) |
| `document-features` (optional dep) | Absent (docs only) |

Low-level API surface: `lib.rs` re-exports `compute::*`, `geometry::*`, `style::*`, `tree::*`, `util::*`, `ParseError`/`ParseResult`, `print_tree` (`lib.rs:87-133`); `prelude.rs` exports `Line` plus the helper traits. Zig `root.zig`/`prelude.zig` list explicit names and omit those (see "Missing or unimplemented" above).

## Evidence notes

- Reference revision confirmed: `git rev-parse HEAD` = `1b918bafcab101dd234ebeb27da0443e24fd9de2` ("Block/Flexbox/Grid: floor content width … #1178"), i.e. v0.14.0-7, matching the prompt.
- Files read in full: Rust `style/mod.rs`, `style/alignment.rs`, `style/available_space.rs`, `style/compact_length.rs`, `style/dimension.rs`, `style/block.rs`, `style/flex.rs`, `style/float.rs`, `geometry.rs`, `style_helpers.rs`, `util/resolve.rs`, `util/math.rs`, `util/parse.rs`, `prelude.rs`, `lib.rs`, `Cargo.toml`, plus `compute/leaf.rs`; Zig `style/mod.zig`, `style/alignment.zig`, `style/available_space.zig`, `style/compact_length.zig`, `style/dimension.zig`, `style/block.zig`, `style/flex.zig`, `style/float.zig`, `style/grid.zig` (Style-relevant sections), `geometry.zig`, `style_helpers.zig`, `util/resolve.zig`, `util/math.zig`, `util/parse.zig`, `util/mod.zig`, `root.zig`, `prelude.zig`, `tree/traits.zig`, `tree/taffy_tree.zig`, `compute/leaf.zig`, `compute/block.zig`, `compute/mod.zig`, `port.md`, `audit/api_audit.md`.
- Methods: field-by-field table built by reading `Style::DEFAULT`/`impl Default` and the Zig struct defaults; tag values/opcodes compared numerically; all "Missing" claims in `api_audit.md` for this area were re-checked against Zig source and several are false positives (listed in the Verdict).
- **Could not verify:** no Zig compiler is installed (`which zig` → not found), so none of the behavioral claims were executed; they are code-reading results. I also did not run the Rust test suite. Compute-side feature behavior (`flexbox_balance`, `content_size`, `detailed_layout_info` population) belongs to other audits and is only marked partial/unverified here. Whether `calc` is intentionally out of scope is not stated anywhere in `port.md`; `port.md:75-82` claims no production failure gate remains, which conflicts with the silent calc behavior.
- No source file was modified; only this audit file was written.
