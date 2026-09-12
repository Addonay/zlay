//! Direct port of Taffy's `style/float.rs`.

const std = @import("std");
pub const FloatParseError = error{InvalidFloatValue};

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
pub const Float = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    left,
    right,
    none,

    pub fn from_str(input: []const u8) FloatParseError!Float {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "left")) return .left;
        if (std.ascii.eqlIgnoreCase(value, "right")) return .right;
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        return error.InvalidFloatValue;
    }
};

pub const Clear = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    left,
    right,
    both,
    none,

    pub fn from_str(input: []const u8) FloatParseError!Clear {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "left")) return .left;
        if (std.ascii.eqlIgnoreCase(value, "right")) return .right;
        if (std.ascii.eqlIgnoreCase(value, "both")) return .both;
        if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
        return error.InvalidFloatValue;
    }
};
pub const FloatDirection = enum { left, right };

pub fn is_floated(value: Float) bool {
    return value == .left or value == .right;
}

pub fn float_direction(value: Float) ?FloatDirection {
    return switch (value) {
        .left => .left,
        .right => .right,
        .none => null,
    };
}
