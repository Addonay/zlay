//! Geometric primitives useful for layout.
//!
//! This file is a direct, deliberately verbose Zig transliteration of
//! Taffy `src/geometry.rs`. The implementation keeps the same generic containers
//! and helper vocabulary. Zig cannot overload operators or express Rust's
//! trait bounds in the same syntax, so operator implementations are exposed
//! as named functions (`add`, `sub`) and higher-order helpers take function
//! pointers. That is a porting constraint, not an algorithmic simplification.
//!
//! PORT STATUS: once the complete literal pass is behavior-tested, decide
//! whether the function-pointer mapping helpers should become comptime
//! functions for zero-overhead monomorphisation.

const std = @import("std");

/// The simple absolute horizontal and vertical axis.
pub const AbsoluteAxis = enum {
    horizontal,
    vertical,

    /// Return the other absolute axis.
    pub fn other_axis(self: AbsoluteAxis) AbsoluteAxis {
        return switch (self) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
    }
};

/// The CSS abstract axis.
///
/// Taffy currently assumes horizontal writing mode when converting abstract
/// axes to absolute axes. Keep that quirk visible until writing-mode support
/// is ported.
pub const AbstractAxis = enum {
    inline_axis,
    block,

    pub fn other(self: AbstractAxis) AbstractAxis {
        return switch (self) {
            .inline_axis => .block,
            .block => .inline_axis,
        };
    }

    pub fn as_abs_naive(self: AbstractAxis) AbsoluteAxis {
        return switch (self) {
            .inline_axis => .horizontal,
            .block => .vertical,
        };
    }
};

/// Container that holds an item in each absolute axis without specifying
/// what kind of item it is.
pub fn InBothAbsAxis(comptime T: type) type {
    return struct {
        horizontal: T,
        vertical: T,

        pub const Self = @This();

        pub fn get(self: Self, axis: AbsoluteAxis) T {
            return switch (axis) {
                .horizontal => self.horizontal,
                .vertical => self.vertical,
            };
        }
    };
}

/// An axis-aligned UI rectangle. In Taffy this same shape is used both for
/// edge values (padding/margin/border) and for edge coordinates.
pub fn Rect(comptime T: type) type {
    return struct {
        left: T,
        right: T,
        top: T,
        bottom: T,

        pub const Self = @This();

        pub fn init(left: T, right: T, top: T, bottom: T) Self {
            return .{ .left = left, .right = right, .top = top, .bottom = bottom };
        }

        pub fn new(left: T, right: T, top: T, bottom: T) Self {
            return .{ .left = left, .right = right, .top = top, .bottom = bottom };
        }

        pub fn grid_axis_sum(self: Self, axis: AbsoluteAxis) T {
            return switch (axis) {
                .horizontal => self.left + self.right,
                .vertical => self.top + self.bottom,
            };
        }

        /// Apply a unary mapping function to all four fields.
        pub fn map(self: Self, comptime R: type, function: *const fn (T) R) Rect(R) {
            return .{
                .left = function(self.left),
                .right = function(self.right),
                .top = function(self.top),
                .bottom = function(self.bottom),
            };
        }

        pub fn horizontal_components(self: Self) Line(T) {
            return .{ .start = self.left, .end = self.right };
        }

        pub fn vertical_components(self: Self) Line(T) {
            return .{ .start = self.top, .end = self.bottom };
        }

        pub fn horizontal_axis_sum(self: Self) T {
            return self.left + self.right;
        }

        pub fn vertical_axis_sum(self: Self) T {
            return self.top + self.bottom;
        }

        pub fn sum_axes(self: Self) Size(T) {
            return .{ .width = self.horizontal_axis_sum(), .height = self.vertical_axis_sum() };
        }

        /// Apply a two-argument mapping function. This is the Zig spelling of
        /// Taffy's `Rect::zip_size`; the `size` argument is selected by axis.
        pub fn zip_size(self: Self, size: anytype, comptime R: type, function: anytype) Rect(R) {
            return .{
                .left = function(self.left, size.width),
                .right = function(self.right, size.width),
                .top = function(self.top, size.height),
                .bottom = function(self.bottom, size.height),
            };
        }

        /// Taffy calls these helpers with `FlexDirection`. Keeping the
        /// direction argument generic lets this foundational file avoid an
        /// import cycle with `style/mod.zig` during the literal port.
        pub fn main_axis_sum(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.horizontal_axis_sum() else self.vertical_axis_sum();
        }

        pub fn cross_axis_sum(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.vertical_axis_sum() else self.horizontal_axis_sum();
        }

        pub fn main_start(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.left else self.top;
        }

        pub fn main_end(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.right else self.bottom;
        }

        pub fn cross_start(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.top else self.left;
        }

        pub fn cross_end(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.bottom else self.right;
        }

        /// Element-wise addition. This names the operation because Zig does
        /// not support implementing `+` for user-defined generic structs.
        /// Element-wise addition. `other` is intentionally `anytype`: Rust
        /// implements this for `Rect<T> + Rect<U>` whenever each pair of
        /// fields implements `Add`, while Zig has no operator-overload hook
        /// with which to express that generic relationship.
        pub fn add(self: Self, other: anytype) Rect(@TypeOf(self.left + other.left)) {
            return .{
                .left = self.left + other.left,
                .right = self.right + other.right,
                .top = self.top + other.top,
                .bottom = self.bottom + other.bottom,
            };
        }

        /// Union of two coordinate rectangles. For edge-value rectangles the
        /// operation is only meaningful when `T` is ordered; keeping it on
        /// the generic record preserves the source API while Zig specializes
        /// the comparison at the call site.
        pub fn @"union"(self: Self, other: Rect(T)) Rect(T) {
            return .{ .left = @min(self.left, other.left), .right = @max(self.right, other.right), .top = @min(self.top, other.top), .bottom = @max(self.bottom, other.bottom) };
        }
    };
}

/// A rectangle whose fields are coordinates rather than edge amounts.
/// Taffy's `Rect<f32>::union` is retained as a named helper.
pub fn rect_union(left: Rect(f32), right: Rect(f32)) Rect(f32) {
    return .{
        .left = @min(left.left, right.left),
        .right = @max(left.right, right.right),
        .top = @min(left.top, right.top),
        .bottom = @max(left.bottom, right.bottom),
    };
}

pub const rect_f32_zero: Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };

/// Taffy's specialized `Rect<f32>::ZERO` and `Rect::new` spellings. Zig
/// cannot partially specialize a generic declaration, so these named
/// constructors keep the same explicit specialization at call sites.
pub const RectF32 = Rect(f32);
pub const RECT_F32_ZERO: RectF32 = rect_f32_zero;

pub fn rect_f32_new(start: f32, end: f32, top: f32, bottom: f32) Rect(f32) {
    return .{ .left = start, .right = end, .top = top, .bottom = bottom };
}

pub fn rect_new(start: f32, end: f32, top: f32, bottom: f32) Rect(f32) {
    return rect_f32_new(start, end, top, bottom);
}
pub fn rect_f32_union(left: Rect(f32), right: Rect(f32)) Rect(f32) {
    return rect_union(left, right);
}

/// An abstract start/end line.
pub fn Line(comptime T: type) type {
    return struct {
        start: T,
        end: T,

        pub const Self = @This();

        pub fn map(self: Self, comptime R: type, function: *const fn (T) R) Line(R) {
            return .{ .start = function(self.start), .end = function(self.end) };
        }

        /// Add the two endpoints using the result type of the underlying
        /// addition, matching Rust's `T: Add` implementation rather than
        /// forcing the result back into `T`.
        pub fn sum(self: Self) @TypeOf(self.start + self.end) {
            return self.start + self.end;
        }
    };
}

pub const BoolLine = Line(bool);
pub const bool_line_true: BoolLine = .{ .start = true, .end = true };
pub const bool_line_false: BoolLine = .{ .start = false, .end = false };
pub const LINE_BOOL_TRUE: BoolLine = bool_line_true;
pub const LINE_BOOL_FALSE: BoolLine = bool_line_false;

/// Width and height of a rectangle.
pub fn Size(comptime T: type) type {
    return struct {
        width: T,
        height: T,

        pub const Self = @This();

        /// Get one component using an absolute axis.
        pub fn get_abs(self: Self, axis: AbsoluteAxis) T {
            return switch (axis) {
                .horizontal => self.width,
                .vertical => self.height,
            };
        }

        /// Element-wise addition; named because Zig has no user operator
        /// overloading.
        /// Element-wise addition for `Size<T> + Size<U>`.
        pub fn add(self: Self, other: anytype) Size(@TypeOf(self.width + other.width)) {
            return .{ .width = self.width + other.width, .height = self.height + other.height };
        }

        /// Element-wise subtraction for `Size<T> - Size<U>`.
        pub fn sub(self: Self, other: anytype) Size(@TypeOf(self.width - other.width)) {
            return .{ .width = self.width - other.width, .height = self.height - other.height };
        }

        pub fn map(self: Self, comptime R: type, function: *const fn (T) R) Size(R) {
            return .{ .width = function(self.width), .height = function(self.height) };
        }

        pub fn f32_max(self: Self, other: Self) Self {
            return .{ .width = @max(self.width, other.width), .height = @max(self.height, other.height) };
        }

        pub fn f32_min(self: Self, other: Self) Self {
            return .{ .width = @min(self.width, other.width), .height = @min(self.height, other.height) };
        }

        pub fn has_non_zero_area(self: Self) bool {
            return self.width > 0 and self.height > 0;
        }

        pub fn maybe_apply_aspect_ratio(self: Self, aspect_ratio: ?f32) Self {
            const ratio = aspect_ratio orelse return self;
            if (self.width) |width| if (self.height == null) return .{ .width = width, .height = width / ratio };
            if (self.height) |height| if (self.width == null) return .{ .width = height * ratio, .height = height };
            return self;
        }

        pub fn unwrap_or(self: Self, alternative: anytype) Size(@TypeOf(alternative.width)) {
            return .{ .width = self.width orelse alternative.width, .height = self.height orelse alternative.height };
        }

        pub fn @"or"(self: Self, alternative: Self) Self {
            return .{ .width = self.width orelse alternative.width, .height = self.height orelse alternative.height };
        }

        pub fn both_axis_defined(self: Self) bool {
            return self.width != null and self.height != null;
        }

        pub fn map_width(self: Self, function: *const fn (T) T) Self {
            return .{ .width = function(self.width), .height = self.height };
        }

        pub fn map_height(self: Self, function: *const fn (T) T) Self {
            return .{ .width = self.width, .height = function(self.height) };
        }

        pub fn zip_map(self: Self, other: anytype, comptime R: type, function: anytype) Size(R) {
            return .{ .width = function(self.width, other.width), .height = function(self.height, other.height) };
        }

        pub fn set_main(self: *Self, direction: anytype, value: T) void {
            if (direction_is_row(direction)) self.width = value else self.height = value;
        }

        pub fn set_cross(self: *Self, direction: anytype, value: T) void {
            if (direction_is_row(direction)) self.height = value else self.width = value;
        }

        pub fn with_main(self: Self, direction: anytype, value: T) Self {
            var result = self;
            result.set_main(direction, value);
            return result;
        }

        pub fn with_cross(self: Self, direction: anytype, value: T) Self {
            var result = self;
            result.set_cross(direction, value);
            return result;
        }

        pub fn map_main(self: Self, direction: anytype, function: *const fn (T) T) Self {
            var result = self;
            if (direction_is_row(direction)) result.width = function(result.width) else result.height = function(result.height);
            return result;
        }

        pub fn map_cross(self: Self, direction: anytype, function: *const fn (T) T) Self {
            var result = self;
            if (direction_is_row(direction)) result.height = function(result.height) else result.width = function(result.width);
            return result;
        }

        pub fn main(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.width else self.height;
        }

        pub fn cross(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.height else self.width;
        }

        pub fn get(self: Self, axis: AbstractAxis) T {
            return if (axis == .inline_axis) self.width else self.height;
        }

        pub fn set(self: *Self, axis: AbstractAxis, value: T) void {
            if (axis == .inline_axis) self.width = value else self.height = value;
        }

        pub fn with(self: Self, axis: AbstractAxis, value: T) Self {
            var result = self;
            result.set(axis, value);
            return result;
        }

        /// Construct a size whose fields are made by a dimension-like type's
        /// `length` constructor. This is the named Zig equivalent of
        /// `Size<Dimension>::from_lengths`.
        pub fn from_lengths(comptime DimensionType: type, width: f32, height: f32) Size(DimensionType) {
            return .{ .width = DimensionType.length(width), .height = DimensionType.length(height) };
        }

        /// Construct a size whose fields are made by a dimension-like type's
        /// `percent` constructor. This preserves the source API without an
        /// import cycle from the foundational geometry module back into the
        /// style module.
        pub fn from_percent(comptime DimensionType: type, width: f32, height: f32) Size(DimensionType) {
            return .{ .width = DimensionType.percent(width), .height = DimensionType.percent(height) };
        }
    };
}

pub const F32Size = Size(f32);
pub const OptionalF32Size = Size(?f32);

pub fn f32_size_max(left: F32Size, right: F32Size) F32Size {
    return .{ .width = @max(left.width, right.width), .height = @max(left.height, right.height) };
}

pub fn f32_size_min(left: F32Size, right: F32Size) F32Size {
    return .{ .width = @min(left.width, right.width), .height = @min(left.height, right.height) };
}

pub fn f32_size_has_non_zero_area(value: F32Size) bool {
    return value.width > 0 and value.height > 0;
}

pub const f32_size_zero: F32Size = .{ .width = 0, .height = 0 };
pub const optional_f32_size_none: OptionalF32Size = .{ .width = null, .height = null };
pub const SIZE_F32_ZERO: F32Size = f32_size_zero;
pub const SIZE_OPTIONAL_F32_NONE: OptionalF32Size = optional_f32_size_none;

pub fn optional_size_unwrap_or(value: OptionalF32Size, alternative: F32Size) F32Size {
    return .{ .width = value.width orelse alternative.width, .height = value.height orelse alternative.height };
}

pub fn optional_size_or(value: OptionalF32Size, alternative: OptionalF32Size) OptionalF32Size {
    return .{ .width = value.width orelse alternative.width, .height = value.height orelse alternative.height };
}

pub fn optional_size_both_axis_defined(value: OptionalF32Size) bool {
    return value.width != null and value.height != null;
}

pub fn optional_f32_size_new(width: f32, height: f32) OptionalF32Size {
    return .{ .width = width, .height = height };
}

pub fn optional_f32_size_from_cross(direction: anytype, value: ?f32) OptionalF32Size {
    if (direction_is_row(direction)) return .{ .width = null, .height = value };
    return .{ .width = value, .height = null };
}

pub fn optional_f32_size_from_cross_axis(direction: anytype, value: ?f32) OptionalF32Size {
    return optional_f32_size_from_cross(direction, value);
}

pub fn size_f32_new(width: f32, height: f32) F32Size {
    return .{ .width = width, .height = height };
}

pub fn size_f32_zero() F32Size {
    return SIZE_F32_ZERO;
}

pub fn size_optional_f32_none() OptionalF32Size {
    return SIZE_OPTIONAL_F32_NONE;
}
pub fn size_optional_f32_new(width: f32, height: f32) OptionalF32Size {
    return optional_f32_size_new(width, height);
}
pub fn size_optional_f32_from_cross(direction: anytype, value: ?f32) OptionalF32Size {
    return optional_f32_size_from_cross(direction, value);
}
pub fn size_optional_f32_unwrap_or(value: OptionalF32Size, alternative: F32Size) F32Size {
    return optional_size_unwrap_or(value, alternative);
}
pub fn size_optional_f32_or(value: OptionalF32Size, alternative: OptionalF32Size) OptionalF32Size {
    return optional_size_or(value, alternative);
}
pub fn size_optional_f32_both_axis_defined(value: OptionalF32Size) bool {
    return optional_size_both_axis_defined(value);
}

pub fn size_from_lengths(comptime DimensionType: type, width: f32, height: f32) Size(DimensionType) {
    return .{ .width = DimensionType.length(width), .height = DimensionType.length(height) };
}

pub fn size_from_percent(comptime DimensionType: type, width: f32, height: f32) Size(DimensionType) {
    return .{ .width = DimensionType.percent(width), .height = DimensionType.percent(height) };
}

/// Apply Taffy's aspect-ratio transfer rule to known dimensions.
pub fn optional_f32_size_maybe_apply_aspect_ratio(value: OptionalF32Size, aspect_ratio: ?f32) OptionalF32Size {
    const ratio = aspect_ratio orelse return value;
    if (ratio <= 0) return value;
    if (value.width) |width| if (value.height == null) return .{ .width = width, .height = width / ratio };
    if (value.height) |height| if (value.width == null) return .{ .width = height * ratio, .height = height };
    return value;
}

/// A two-dimensional coordinate.
pub fn Point(comptime T: type) type {
    return struct {
        x: T,
        y: T,

        pub const Self = @This();

        /// Element-wise addition for `Point<T> + Point<U>`.
        pub fn add(self: Self, other: anytype) Point(@TypeOf(self.x + other.x)) {
            return .{ .x = self.x + other.x, .y = self.y + other.y };
        }

        pub fn map(self: Self, comptime R: type, function: *const fn (T) R) Point(R) {
            return .{ .x = function(self.x), .y = function(self.y) };
        }

        pub fn get(self: Self, axis: AbstractAxis) T {
            return if (axis == .inline_axis) self.x else self.y;
        }

        pub fn set(self: *Self, axis: AbstractAxis, value: T) void {
            if (axis == .inline_axis) self.x = value else self.y = value;
        }

        pub fn transpose(self: Self) Self {
            return .{ .x = self.y, .y = self.x };
        }

        pub fn main(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.x else self.y;
        }

        pub fn cross(self: Self, direction: anytype) T {
            return if (direction_is_row(direction)) self.y else self.x;
        }

        /// Convert the point's coordinates into a width/height pair. This
        /// is the direct Zig spelling of `From<Point<T>> for Size<T>`.
        pub fn to_size(self: Self) Size(T) {
            return .{ .width = self.x, .height = self.y };
        }
    };
}

pub const F32Point = Point(f32);
pub const OptionalF32Point = Point(?f32);
pub const f32_point_zero: F32Point = .{ .x = 0, .y = 0 };
pub const optional_f32_point_none: OptionalF32Point = .{ .x = null, .y = null };

pub fn point_to_size(value: anytype) Size(@TypeOf(value.x)) {
    return .{ .width = value.x, .height = value.y };
}

pub fn point_new(comptime T: type, x: T, y: T) Point(T) {
    return .{ .x = x, .y = y };
}

pub fn size_from_point(value: anytype) Size(@TypeOf(value.x)) {
    return point_to_size(value);
}

pub fn point_f32_zero() Point(f32) {
    return .{ .x = 0, .y = 0 };
}

pub fn point_optional_f32_none() Point(?f32) {
    return .{ .x = null, .y = null };
}

pub fn point_f32_new(x: f32, y: f32) Point(f32) {
    return .{ .x = x, .y = y };
}

/// Generic min/max pair used by grid track sizing.
pub fn MinMax(comptime Min: type, comptime Max: type) type {
    return struct {
        min: Min,
        max: Max,
    };
}

/// Keep the direction test in one place. It accepts both the exact Taffy
/// enum spellings (`.row`, `.row_reverse`) and a plain boolean used by a few
/// early port helpers.
fn direction_is_row(direction: anytype) bool {
    if (@TypeOf(direction) == bool) return direction;
    return direction == .row or direction == .row_reverse;
}

test "geometry generic helpers match Taffy semantics" {
    const testing = std.testing;
    const size = F32Size{ .width = 10, .height = 20 };
    try testing.expectEqual(@as(f32, 10), size.get_abs(.horizontal));
    try testing.expectEqual(@as(f32, 20), size.get_abs(.vertical));
    try testing.expectEqual(@as(f32, 30), size.add(.{ .width = 20, .height = 10 }).width);
    try testing.expectEqual(@as(f32, 8), (Rect(f32).init(2, 6, 3, 4)).grid_axis_sum(.horizontal));
    try testing.expect(optional_size_both_axis_defined(optional_f32_size_new(1, 2)));
    const ratio = optional_f32_size_maybe_apply_aspect_ratio(.{ .width = 20, .height = null }, 2);
    try testing.expectEqual(@as(?f32, 10), ratio.height);
}

test "geometry specialized aliases preserve Taffy constructors" {
    const testing = std.testing;
    const rect = rect_new(4, 12, 2, 9);
    try testing.expectEqual(@as(f32, 4), rect.left);
    try testing.expectEqual(@as(f32, 12), rect.right);
    const unioned = rect_f32_union(rect, rect_new(1, 15, 3, 8));
    try testing.expectEqual(@as(f32, 1), unioned.left);
    try testing.expectEqual(@as(f32, 15), unioned.right);
    try testing.expectEqual(@as(f32, 5), size_f32_new(5, 6).width);
    try testing.expectEqual(@as(f32, 7), size_from_point(Point(f32){ .x = 7, .y = 8 }).width);
    try testing.expectEqual(@as(?f32, 4), size_optional_f32_unwrap_or(.{ .width = null, .height = 2 }, .{ .width = 4, .height = 5 }).width);
}
