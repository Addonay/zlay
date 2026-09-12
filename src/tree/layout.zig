//! Direct port of Taffy's `tree/layout.rs` data contracts.

const geometry = @import("../geometry.zig");
const available = @import("../style/available_space.zig");

pub const RunMode = enum { perform_layout, compute_size, perform_hidden_layout };
pub const SizingMode = enum { content_size, inherent_size };
pub const RequestedAxis = enum { horizontal, vertical, both };

pub fn requested_axis_from_absolute(axis: geometry.AbsoluteAxis) RequestedAxis {
    return if (axis == .horizontal) .horizontal else .vertical;
}

pub fn requested_axis_into_absolute(axis: RequestedAxis) ?geometry.AbsoluteAxis {
    return switch (axis) {
        .horizontal => .horizontal,
        .vertical => .vertical,
        .both => null,
    };
}

pub const CollapsibleMarginSet = struct {
    positive: f32 = 0,
    negative: f32 = 0,

    pub const zero: CollapsibleMarginSet = .{};
    pub const ZERO: CollapsibleMarginSet = zero;

    pub fn from_margin(value: f32) CollapsibleMarginSet {
        return if (value >= 0) .{ .positive = value } else .{ .negative = value };
    }

    pub fn collapse_with_margin(self: CollapsibleMarginSet, value: f32) CollapsibleMarginSet {
        var result = self;
        if (value >= 0) result.positive = @max(result.positive, value) else result.negative = @min(result.negative, value);
        return result;
    }

    pub fn collapse_with_set(self: CollapsibleMarginSet, other: CollapsibleMarginSet) CollapsibleMarginSet {
        return .{ .positive = @max(self.positive, other.positive), .negative = @min(self.negative, other.negative) };
    }

    pub fn resolve(self: CollapsibleMarginSet) f32 {
        return self.positive + self.negative;
    }
};

pub const Baselines = struct {
    first: ?f32 = null,
    last: ?f32 = null,

    pub const none: Baselines = .{};
    pub const NONE: Baselines = none;

    pub fn from_first(first: ?f32) Baselines {
        return .{ .first = first };
    }
};

pub const LayoutInput = struct {
    run_mode: RunMode,
    sizing_mode: SizingMode,
    axis: RequestedAxis,
    known_dimensions: geometry.Size(?f32),
    known_dimensions_are_definite: geometry.Size(bool),
    parent_size: geometry.Size(?f32),
    available_space: geometry.Size(available.AvailableSpace),
    vertical_margins_are_collapsible: geometry.Line(bool),

    pub const HIDDEN: LayoutInput = .{
        .run_mode = .perform_hidden_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
};

pub const LayoutOutput = struct {
    size: geometry.Size(f32),
    scrollable_overflow_rect: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    baselines: Baselines = .none,
    top_margin: CollapsibleMarginSet = .zero,
    bottom_margin: CollapsibleMarginSet = .zero,
    margins_can_collapse_through: bool = false,

    pub fn from_outer_size(size: geometry.Size(f32)) LayoutOutput {
        return .{ .size = size };
    }

    pub const hidden: LayoutOutput = .{ .size = .{ .width = 0, .height = 0 } };
    pub const HIDDEN: LayoutOutput = hidden;

    pub const default: LayoutOutput = hidden;

    pub fn from_sizes_and_baselines(size: geometry.Size(f32), baselines: Baselines) LayoutOutput {
        return .{ .size = size, .baselines = baselines };
    }

    pub fn from_sizes(size: geometry.Size(f32)) LayoutOutput {
        return LayoutOutput.from_outer_size(size);
    }
};

pub const Layout = struct {
    order: u32 = 0,
    location: geometry.Point(f32) = .{ .x = 0, .y = 0 },
    size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    content_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    scrollable_overflow_rect: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    scrollbar_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    border: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    padding: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    margin: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },

    pub fn with_order(order: u32) Layout {
        return .{ .order = order };
    }

    pub fn new() Layout {
        return .{};
    }

    pub fn content_box_width(self: Layout) f32 {
        return self.size.width - self.padding.left - self.padding.right - self.border.left - self.border.right;
    }

    pub fn content_box_height(self: Layout) f32 {
        return self.size.height - self.padding.top - self.padding.bottom - self.border.top - self.border.bottom;
    }

    pub fn content_box_size(self: Layout) geometry.Size(f32) {
        return .{ .width = self.content_box_width(), .height = self.content_box_height() };
    }

    pub fn content_box_x(self: Layout) f32 {
        return self.location.x + self.border.left + self.padding.left;
    }

    pub fn content_box_y(self: Layout) f32 {
        return self.location.y + self.border.top + self.padding.top;
    }

    pub fn scroll_width(self: Layout) f32 {
        return @max(0, self.scrollable_overflow_rect.right + @min(self.scrollbar_size.width, self.size.width) - self.size.width + self.border.left + self.border.right);
    }

    pub fn scroll_height(self: Layout) f32 {
        return @max(0, self.scrollable_overflow_rect.bottom + @min(self.scrollbar_size.height, self.size.height) - self.size.height + self.border.top + self.border.bottom);
    }
};

pub const DetailedLayoutInfo = union(enum) { none, grid: *const anyopaque };

test "collapsible margins follow positive plus most negative" {
    const testing = @import("std").testing;
    var margins = CollapsibleMarginSet.from_margin(10);
    margins = margins.collapse_with_margin(4);
    margins = margins.collapse_with_margin(-3);
    try testing.expectEqual(@as(f32, 7), margins.resolve());
}

test "layout contracts expose hidden input and scroll extents" {
    const testing = @import("std").testing;
    try testing.expectEqual(RunMode.perform_hidden_layout, LayoutInput.HIDDEN.run_mode);
    var layout = Layout{ .size = .{ .width = 100, .height = 80 }, .scrollable_overflow_rect = .{ .left = 0, .right = 140, .top = 0, .bottom = 100 } };
    layout.scrollbar_size = .{ .width = 10, .height = 10 };
    try testing.expectEqual(@as(f32, 50), layout.scroll_width());
    try testing.expectEqual(@as(f32, 30), layout.scroll_height());
}
