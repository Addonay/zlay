//! Direct port of Taffy's `style/block.rs`.

const std = @import("std");
pub const BlockParseError = error{InvalidTextAlign};

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
pub const TextAlign = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    auto,
    legacy_left,
    legacy_right,
    legacy_center,

    pub fn is_legacy(self: TextAlign) bool {
        return self != .auto;
    }

    pub fn from_str(input: []const u8) BlockParseError!TextAlign {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "-webkit-left") or std.ascii.eqlIgnoreCase(value, "-moz-left")) return .legacy_left;
        if (std.ascii.eqlIgnoreCase(value, "-webkit-right") or std.ascii.eqlIgnoreCase(value, "-moz-right")) return .legacy_right;
        if (std.ascii.eqlIgnoreCase(value, "-webkit-center") or std.ascii.eqlIgnoreCase(value, "-moz-center")) return .legacy_center;
        return error.InvalidTextAlign;
    }
};

pub const BlockContainerStyle = struct {};
pub const BlockItemStyle = struct {};
