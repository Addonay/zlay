//! Direct port of Taffy's `compute/grid/types/named.rs`.
//!
//! Resolution of named grid lines: builds per-axis maps from line name to
//! one-indexed line positions (expanding `repeat()`s and `grid-template-areas`
//! generated names), then resolves `GridPlacement` values into numeric lines,
//! handling named spans relative to a definite opposite edge and the CSS
//! fallback for non-existent line names.

const std = @import("std");
const geometry = @import("../../../geometry.zig");
const style_mod = @import("../../../style/mod.zig");
const grid_style = @import("../../../style/grid.zig");

const MAX_GRID_TRACKS: u32 = 10_000;

pub const GridAreaEnd = enum { start, end };

const LinePositions = std.ArrayListUnmanaged(u32);

const LineFilter = union(enum) {
    all,
    /// Keep positions `<= point` (Taffy: `partition_point(|line| *line <= point)`)
    after_inclusive: u32,
    /// Keep positions `< point` (Taffy: `partition_point(|line| *line < point)`)
    before_exclusive: u32,
};

/// The (1-indexed line number, name) pairs used by detailed layout info.
const LineNamePair = struct { line: u32, name: []const u8 };

pub const NamedLineResolver = struct {
    arena: std.heap.ArenaAllocator,
    row_lines: std.StringHashMapUnmanaged(LinePositions) = .{},
    column_lines: std.StringHashMapUnmanaged(LinePositions) = .{},
    areas: std.StringHashMapUnmanaged(grid_style.GridTemplateArea) = .{},
    area_column_count_value: u16 = 0,
    area_row_count_value: u16 = 0,
    explicit_column_count: u16 = 0,
    explicit_row_count: u16 = 0,
    column_line_name_pairs: std.ArrayListUnmanaged(LineNamePair) = .empty,
    row_line_name_pairs: std.ArrayListUnmanaged(LineNamePair) = .empty,

    /// Create and initialise a new `NamedLineResolver` from a style.
    pub fn init(backing_allocator: std.mem.Allocator, item_style: *const style_mod.Style, column_auto_repetitions: u16, row_auto_repetitions: u16) !NamedLineResolver {
        var result = NamedLineResolver{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
        // `arena` is moved by value; keep using result.arena from here on.
        const allocator = result.arena.allocator();

        try init_axis(&result, allocator, .horizontal, item_style.grid_template_columns, item_style.grid_template_column_names, column_auto_repetitions);
        try init_axis(&result, allocator, .vertical, item_style.grid_template_rows, item_style.grid_template_row_names, row_auto_repetitions);

        // The size of the area template may be larger than the extents of the named areas
        // due to unnamed cells, so it is taken from the style.
        result.area_column_count_value = item_style.grid_template_area_column_count();
        result.area_row_count_value = item_style.grid_template_area_row_count();
        if (item_style.grid_template_areas) |areas| {
            for (areas.areas) |area| {
                try result.areas.put(allocator, area.name, area);

                const col_start = try std.fmt.allocPrint(allocator, "{s}-start", .{area.name});
                try result.column_line_name_pairs.append(allocator, .{ .line = area.column_start, .name = col_start });
                try upsert_line_name_map(&result.column_lines, allocator, col_start, area.column_start);

                const col_end = try std.fmt.allocPrint(allocator, "{s}-end", .{area.name});
                try result.column_line_name_pairs.append(allocator, .{ .line = area.column_end, .name = col_end });
                try upsert_line_name_map(&result.column_lines, allocator, col_end, area.column_end);

                const row_start = try std.fmt.allocPrint(allocator, "{s}-start", .{area.name});
                try result.row_line_name_pairs.append(allocator, .{ .line = area.row_start, .name = row_start });
                try upsert_line_name_map(&result.row_lines, allocator, row_start, area.row_start);

                const row_end = try std.fmt.allocPrint(allocator, "{s}-end", .{area.name});
                try result.row_line_name_pairs.append(allocator, .{ .line = area.row_end, .name = row_end });
                try upsert_line_name_map(&result.row_lines, allocator, row_end, area.row_end);
            }
        }

        // Sort and dedup lines for each column name
        try sort_and_dedup_map(&result.column_lines, allocator);
        try sort_and_dedup_map(&result.row_lines, allocator);

        return result;
    }

    pub fn deinit(self: *NamedLineResolver) void {
        self.arena.deinit();
    }

    fn axis_maps(self: *NamedLineResolver, axis: geometry.AbsoluteAxis) *std.StringHashMapUnmanaged(LinePositions) {
        return if (axis == .horizontal) &self.column_lines else &self.row_lines;
    }

    pub fn resolve_row_names(self: *const NamedLineResolver, value: geometry.Line(grid_style.GridPlacement)) geometry.Line(grid_style.GridPlacement) {
        return self.resolve_line_names(value, .vertical);
    }

    pub fn resolve_column_names(self: *const NamedLineResolver, value: geometry.Line(grid_style.GridPlacement)) geometry.Line(grid_style.GridPlacement) {
        return self.resolve_line_names(value, .horizontal);
    }

    /// Resolve named lines for both the `start` and `end` of a grid placement.
    pub fn resolve_line_names(self: *const NamedLineResolver, value: geometry.Line(grid_style.GridPlacement), axis: geometry.AbsoluteAxis) geometry.Line(grid_style.GridPlacement) {
        const explicit_track_count = if (axis == .horizontal) self.explicit_column_count else self.explicit_row_count;
        const lines = if (axis == .horizontal) &self.column_lines else &self.row_lines;
        const resolver_axis = AxisResolver{ .lines = lines, .explicit_track_count = explicit_track_count };

        const start_resolved: grid_style.GridPlacement = if (value.start == .named_line)
            .{ .line = resolver_axis.find_line_index(value.start.named_line.name, value.start.named_line.index, .start, .all) }
        else
            value.start;

        const end_resolved: grid_style.GridPlacement = if (value.end == .named_line)
            .{ .line = resolver_axis.find_line_index(value.end.named_line.name, value.end.named_line.index, .end, .all) }
        else
            value.end;

        // If both the *-start and *-end values specify a line, the span is implicit.
        // If one side is a named span, it is resolved relative to the definite line.
        if (start_resolved == .line and end_resolved == .named_span) {
            const start_line = start_resolved.line;
            const normalized_start_line: u32 = if (start_line > 0)
                @intCast(@max(start_line, 0))
            else
                @intCast(@max(@as(i32, explicit_track_count) + 1 + start_line, 0));
            const end_line = resolver_axis.find_line_index(
                end_resolved.named_span.name,
                @intCast(end_resolved.named_span.count),
                .end,
                .{ .after_inclusive = normalized_start_line },
            );
            return .{ .start = .{ .line = start_line }, .end = .{ .line = end_line } };
        }
        if (start_resolved == .named_span and end_resolved == .line) {
            const end_line = end_resolved.line;
            const normalized_end_line: u32 = if (end_line > 0)
                @intCast(@max(end_line, 0))
            else
                @intCast(@max(@as(i32, explicit_track_count) + 1 + end_line, 0));
            const start_line = resolver_axis.find_line_index(
                start_resolved.named_span.name,
                @intCast(start_resolved.named_span.count),
                .start,
                .{ .before_exclusive = normalized_end_line },
            );
            return .{ .start = .{ .line = start_line }, .end = .{ .line = end_line } };
        }

        return .{ .start = resolve_non_named(start_resolved), .end = resolve_non_named(end_resolved) };
    }

    pub fn area_column_count(self: *const NamedLineResolver) u16 {
        return self.area_column_count_value;
    }
    pub fn area_row_count(self: *const NamedLineResolver) u16 {
        return self.area_row_count_value;
    }

    /// Build the per-line name lists used by `DetailedGridTracksInfo`.
    /// Returned index `i` is the (i+1)-th grid line, matching the 1-indexed
    /// `line` recorded for every name pair. Empty when the axis has no names.
    pub fn detailed_line_names(self: *const NamedLineResolver, allocator: std.mem.Allocator, axis: geometry.AbsoluteAxis) ![]const []const []const u8 {
        const pairs = if (axis == .horizontal) self.column_line_name_pairs.items else self.row_line_name_pairs.items;
        if (pairs.len == 0) return &.{};
        var max_line: usize = 0;
        for (pairs) |pair| max_line = @max(max_line, pair.line);
        const lines = try allocator.alloc(std.ArrayListUnmanaged([]const u8), max_line + 1);
        for (lines) |*line| line.* = .empty;
        for (pairs) |pair| {
            const index: usize = if (pair.line > 0) @intCast(pair.line - 1) else 0;
            try lines[index].append(allocator, pair.name);
        }
        const result = try allocator.alloc([]const []const u8, lines.len);
        for (lines, 0..) |line, index| result[index] = line.items;
        return result;
    }

    pub fn set_explicit_column_count(self: *NamedLineResolver, count: u16) void {
        self.explicit_column_count = count;
    }
    pub fn set_explicit_row_count(self: *NamedLineResolver, count: u16) void {
        self.explicit_row_count = count;
    }
};

fn resolve_non_named(value: grid_style.GridPlacement) grid_style.GridPlacement {
    return switch (value) {
        .auto => .auto,
        .line => |line| .{ .line = line },
        .span => |span| .{ .span = span },
        .named_span => .{ .span = 1 },
        .named_line => |named| .{ .line = named.index },
    };
}

const AxisResolver = struct {
    lines: *const std.StringHashMapUnmanaged(LinePositions),
    explicit_track_count: u16,

    fn find_line_index(self: AxisResolver, name: []const u8, idx_raw: i16, end: GridAreaEnd, filter: LineFilter) i16 {
        var idx: i32 = idx_raw;
        const explicit_track_count: i32 = self.explicit_track_count;

        // An index of 0 is used to represent "no index specified".
        if (idx == 0) idx = 1;

        if (self.lines.get(name)) |lines| {
            return get_line(apply_filter(filter, lines.items), explicit_track_count, idx);
        }

        // Implicit names generated by `grid-template-areas`
        var buffer: [512]u8 = undefined;
        const suffix = if (end == .start) "-start" else "-end";
        if (name.len + suffix.len < buffer.len) {
            const implicit_name = std.fmt.bufPrint(&buffer, "{s}{s}", .{ name, suffix }) catch name;
            if (self.lines.get(implicit_name)) |lines| {
                return get_line(apply_filter(filter, lines.items), explicit_track_count, idx);
            }
        }

        // The CSS Grid specification matches non-existent line names to the first
        // (positive) implicit line in the grid.
        const line: i64 = if (idx > 0)
            @as(i64, explicit_track_count) + 1 + idx
        else
            -(@as(i64, explicit_track_count) + 1 + idx);
        return clamp_i16(line);
    }
};

fn apply_filter(filter: LineFilter, lines: []const u32) []const u32 {
    return switch (filter) {
        .all => lines,
        .after_inclusive => |point| lines[partition_point_le(lines, point)..],
        .before_exclusive => |point| lines[0..partition_point_lt(lines, point)],
    };
}

fn partition_point_le(lines: []const u32, point: u32) usize {
    var index: usize = 0;
    while (index < lines.len and lines[index] <= point) : (index += 1) {}
    return index;
}

fn partition_point_lt(lines: []const u32, point: u32) usize {
    var index: usize = 0;
    while (index < lines.len and lines[index] < point) : (index += 1) {}
    return index;
}

fn get_line(lines: []const u32, explicit_track_count: i32, idx: i32) i16 {
    const abs_idx: usize = @intCast(@abs(idx));
    const line: i64 = if (abs_idx <= lines.len)
        (if (idx > 0) @as(i64, lines[abs_idx - 1]) else @as(i64, lines[lines.len - abs_idx]))
    else blk: {
        const remaining_lines: i64 = @as(i64, @intCast(abs_idx - lines.len)) * (if (idx > 0) @as(i64, 1) else @as(i64, -1));
        break :blk if (idx > 0)
            @as(i64, explicit_track_count) + 1 + remaining_lines
        else
            -(@as(i64, explicit_track_count) + 1 + remaining_lines);
    };
    return clamp_i16(line);
}

fn clamp_i16(value: i64) i16 {
    return @intCast(@max(@as(i64, std.math.minInt(i16)), @min(@as(i64, std.math.maxInt(i16)), value)));
}

fn upsert_line_name_map(map: *std.StringHashMapUnmanaged(LinePositions), allocator: std.mem.Allocator, key: []const u8, value: u32) !void {
    const entry = try map.getOrPut(allocator, key);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(allocator, value);
}

fn sort_and_dedup_map(map: *std.StringHashMapUnmanaged(LinePositions), allocator: std.mem.Allocator) !void {
    _ = allocator;
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const items = entry.value_ptr.items;
        std.mem.sort(u32, items, {}, std.sort.asc(u32));
        var write: usize = 0;
        for (items, 0..) |value, read| {
            if (write == 0 or items[write - 1] != value) {
                items[write] = value;
                write += 1;
            }
            _ = read;
        }
        entry.value_ptr.shrinkRetainingCapacity(write);
    }
}

fn init_axis(
    result: *NamedLineResolver,
    allocator: std.mem.Allocator,
    axis: geometry.AbsoluteAxis,
    components: []const grid_style.GridTemplateComponent,
    line_names: []const grid_style.GridTemplateLineNames,
    auto_repetitions: u16,
) !void {
    const lines = result.axis_maps(axis);
    const pairs = if (axis == .horizontal) &result.column_line_name_pairs else &result.row_line_name_pairs;

    var current_line: u32 = 0;
    for (line_names, 0..) |names, line_index| {
        current_line += 1;
        for (names) |name| {
            try pairs.append(allocator, .{ .line = current_line, .name = name });
            try upsert_line_name_map(lines, allocator, name, current_line);
        }

        if (line_index < components.len) {
            const component = components[line_index];
            switch (component) {
                .single => {},
                .repeat => |repeat| {
                    const repeat_count: u32 = switch (repeat.count) {
                        .count => |count| count,
                        .auto_fit, .auto_fill => auto_repetitions,
                    };
                    const lines_per_repetition: u32 = repeat.track_count();
                    const line_name_set_count: u32 = @intCast(repeat.line_names.len);
                    std.debug.assert(line_name_set_count == 0 or line_name_set_count == lines_per_repetition + 1);

                    for (0..repeat_count) |_| {
                        for (repeat.line_names, 0..) |line_name_set, set_index| {
                            const line = current_line + @as(u32, @intCast(set_index));
                            for (line_name_set) |name| {
                                try pairs.append(allocator, .{ .line = line, .name = name });
                                try upsert_line_name_map(lines, allocator, name, line);
                            }
                        }
                        current_line += lines_per_repetition;
                        // Names for lines beyond the maximum track limit are never resolvable
                        if (current_line > MAX_GRID_TRACKS) break;
                    }
                    // Last line name set collapses with the following line name set
                    if (repeat_count > 0) current_line -|= 1;
                },
            }
        }
    }
}

test "named grid lines resolve positive and negative occurrences" {
    const testing = std.testing;
    const cols = [_]grid_style.GridTemplateComponent{
        .{ .single = grid_style.TrackSizingFunction.from_length(10) },
        .{ .single = grid_style.TrackSizingFunction.from_length(10) },
    };
    const names = [_]grid_style.GridTemplateLineNames{
        &[_][]const u8{"content"},
        &.{},
        &[_][]const u8{"content"},
    };
    var item_style = style_mod.Style{ .display = .grid, .grid_template_columns = &cols, .grid_template_column_names = &names };
    var resolver = try NamedLineResolver.init(testing.allocator, &item_style, 0, 0);
    defer resolver.deinit();
    resolver.set_explicit_column_count(2);

    const start = resolver.resolve_column_names(.{ .start = .{ .named_line = .{ .name = "content", .index = 2 } }, .end = .auto }).start;
    const end = resolver.resolve_column_names(.{ .start = .{ .named_line = .{ .name = "content", .index = -1 } }, .end = .auto }).start;
    try testing.expect(start == .line and start.line == 3);
    try testing.expect(end == .line and end.line == 3);
    _ = &item_style;
}

test "missing named lines fall back to implicit grid lines" {
    const testing = std.testing;
    var resolver = try NamedLineResolver.init(testing.allocator, &.{}, 0, 0);
    defer resolver.deinit();
    resolver.set_explicit_column_count(10_000);
    const resolved = resolver.resolve_column_names(.{ .start = .{ .named_line = .{ .name = "missing", .index = std.math.maxInt(i16) } }, .end = .auto });
    try testing.expect(resolved.start == .line);
    try testing.expectEqual(@as(i16, std.math.maxInt(i16)), resolved.start.line);
}
