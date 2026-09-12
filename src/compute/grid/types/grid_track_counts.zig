//! Direct-port home for `compute/grid/types/grid_track_counts.rs`.

const coordinates = @import("coordinates.zig");
const geometry = @import("../../../geometry.zig");

pub const TrackRange = struct { start: i16, end: i16 };

pub const GridTrackCounts = struct {
    explicit_rows: u16 = 0,
    explicit_columns: u16 = 0,
    implicit_rows: u16 = 0,
    implicit_columns: u16 = 0,
};

pub const TrackCounts = struct {
    negative_implicit: u16 = 0,
    explicit: u16 = 0,
    positive_implicit: u16 = 0,

    pub fn from_raw(negative: u16, explicit: u16, positive: u16) TrackCounts {
        return .{ .negative_implicit = negative, .explicit = explicit, .positive_implicit = positive };
    }
    pub fn len(self: TrackCounts) usize {
        return @as(usize, self.negative_implicit) + self.explicit + self.positive_implicit;
    }
    pub fn implicit_start_line(self: TrackCounts) coordinates.OriginZeroLine {
        return .{ .value = -@as(i16, @intCast(self.negative_implicit)) };
    }
    pub fn implicit_end_line(self: TrackCounts) coordinates.OriginZeroLine {
        return .{ .value = @as(i16, @intCast(self.explicit + self.positive_implicit)) };
    }

    /// Convert an OriginZero line to the track immediately following it in
    /// the sparse occupancy matrix. This is deliberately not the odd/even
    /// index used by GridTrackVec, which stores lines and tracks together.
    pub fn oz_line_to_next_track(self: TrackCounts, index: coordinates.OriginZeroLine) i16 {
        return index.value + @as(i16, @intCast(self.negative_implicit));
    }

    /// Convert a half-open OriginZero line range to sparse track indexes.
    pub fn oz_line_range_to_track_range(self: TrackCounts, input: geometry.Line(coordinates.OriginZeroLine)) TrackRange {
        return .{ .start = self.oz_line_to_next_track(input.start), .end = self.oz_line_to_next_track(input.end) };
    }

    /// Convert a sparse track index back to the line immediately preceding it.
    pub fn track_to_prev_oz_line(self: TrackCounts, index: u16) coordinates.OriginZeroLine {
        return .{ .value = @as(i16, @intCast(index)) - @as(i16, @intCast(self.negative_implicit)) };
    }

    /// Convert a sparse track range back to its bounding OriginZero lines.
    pub fn track_range_to_oz_line_range(self: TrackCounts, input: TrackRange) geometry.Line(coordinates.OriginZeroLine) {
        return .{ .start = self.track_to_prev_oz_line(@intCast(input.start)), .end = self.track_to_prev_oz_line(@intCast(input.end)) };
    }
};
