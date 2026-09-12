//! Direct port of Taffy's `compute/common/alignment.rs`.

const style = @import("../../style/alignment.zig");

/// Resolve the safe/unsafe overflow-position fallback for self-level
/// alignment, matching Taffy's `resolve_self_alignment_safety`.
pub fn resolve_self_alignment_safety(alignment: style.AlignItems, overflows: bool) style.AlignItemsKeyword {
    if (alignment.safety == .safe and overflows) return .start;
    return alignment.keyword;
}

/// Resolve the distribution fallbacks from CSS Box Alignment §5.3. This is
/// intentionally separate from offset calculation because Flexbox and Grid
/// call it with different item/line counts.
pub fn apply_alignment_fallback(free_space: f32, item_count: usize, alignment: style.AlignContent) style.AlignContentKeyword {
    var keyword = alignment.keyword;
    var is_safe = alignment.safety == .safe;
    if (item_count <= 1 or free_space <= 0) switch (keyword) {
        .stretch, .space_between => {
            keyword = if (keyword == .stretch) .flex_start else .flex_start;
            is_safe = true;
        },
        .space_around, .space_evenly => {
            keyword = .center;
            is_safe = true;
        },
        else => {},
    };
    if (free_space <= 0 and is_safe) keyword = .start;
    return keyword;
}

/// Compute the offset before the first item or between subsequent items.
/// Grid callers pass a zero gap, matching the Rust implementation's note.
pub fn compute_alignment_offset(
    free_space: f32,
    item_count: usize,
    gap: f32,
    keyword: style.AlignContentKeyword,
    layout_is_reversed: bool,
    is_first: bool,
) f32 {
    if (is_first) return switch (keyword) {
        .start => 0,
        .flex_start => if (layout_is_reversed) free_space else 0,
        .end => free_space,
        .flex_end => if (layout_is_reversed) 0 else free_space,
        .center => free_space / 2,
        .stretch, .space_between => 0,
        .space_around => if (free_space >= 0) (free_space / @as(f32, @floatFromInt(item_count))) / 2 else free_space / 2,
        .space_evenly => if (free_space >= 0) free_space / @as(f32, @floatFromInt(item_count + 1)) else free_space / 2,
    };

    const positive_free = @max(0, free_space);
    return gap + switch (keyword) {
        .start, .flex_start, .end, .flex_end, .center, .stretch => 0,
        .space_between => positive_free / @as(f32, @floatFromInt(item_count - 1)),
        .space_around => positive_free / @as(f32, @floatFromInt(item_count)),
        .space_evenly => positive_free / @as(f32, @floatFromInt(item_count + 1)),
    };
}

pub fn fallback_position(value: ?style.AlignContent) style.AlignContentKeyword {
    return (value orelse style.AlignContent.start).keyword;
}
