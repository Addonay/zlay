//! Direct port of Taffy's `compute/common/sizing_keyword.rs`.

const available = @import("../../style/available_space.zig");
const dimension = @import("../../style/dimension.zig");
const geometry = @import("../../geometry.zig");

pub const SizingKeywordResolution = union(enum) {
    measure: available.AvailableSpace,
    exact: f32,
};

/// Resolve one sizing keyword. A non-keyword returns `null`, and a keyword
/// whose required basis is indefinite also returns `null`, which means the
/// caller treats it as `auto`, matching Taffy's behavior.
pub fn resolve_sizing_keyword(value: dimension.Dimension, stretch_size: ?f32, percent_basis: ?f32) ?SizingKeywordResolution {
    return switch (value.value.tag()) {
        .min_content => .{ .measure = .min_content },
        .max_content => .{ .measure = .max_content },
        .fit_content_px => .{ .measure = .{ .definite = value.value.value() } },
        .fit_content_percent => if (percent_basis) |basis| .{ .measure = .{ .definite = basis * value.value.value() } } else null,
        .fit_content_keyword => if (stretch_size) |size| .{ .measure = .{ .definite = size } } else null,
        .stretch => if (stretch_size) |size| .{ .exact = size } else null,
        else => null,
    };
}

pub fn is_intrinsic(value: dimension.Dimension) bool {
    return switch (value.value.tag()) {
        .min_content, .max_content, .fit_content_keyword, .fit_content_px, .fit_content_percent, .stretch, .content => true,
        else => false,
    };
}

/// Resolve absolute-position sizing keywords before the absolute placement
/// pass. Measurement-backed keywords retain their available-space result for
/// the caller; an exact `stretch` result is written immediately. A custom
/// tree can replace the measure branch through its normal leaf measurement
/// callback without changing the keyword calculation here.
pub fn resolve_absolute_sizing_keywords(
    known_dimensions: *geometry.Size(?f32),
    size_style: geometry.Size(dimension.Dimension),
    area_size: geometry.Size(f32),
    inset: geometry.Rect(?f32),
    margin: geometry.Rect(?f32),
) void {
    const stretch_width = @max(area_size.width - (inset.left orelse 0) - (inset.right orelse 0) - (margin.left orelse 0) - (margin.right orelse 0), 0);
    const stretch_height = @max(area_size.height - (inset.top orelse 0) - (inset.bottom orelse 0) - (margin.top orelse 0) - (margin.bottom orelse 0), 0);
    if (known_dimensions.width == null) if (resolve_sizing_keyword(size_style.width, stretch_width, area_size.width)) |resolution| switch (resolution) {
        .exact => |value| known_dimensions.width = value,
        .measure => |space| {
            if (space.into_option()) |value| known_dimensions.width = value;
        },
    };
    if (known_dimensions.height == null) if (resolve_sizing_keyword(size_style.height, stretch_height, area_size.height)) |resolution| switch (resolution) {
        .exact => |value| known_dimensions.height = value,
        .measure => |space| {
            if (space.into_option()) |value| known_dimensions.height = value;
        },
    };
}
