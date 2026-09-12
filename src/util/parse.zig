//! Small CSS-value parser seam from Taffy's `util/parse.rs`.
//!
//! The Rust crate delegates tokenization to `cssparser` and then requires the
//! parser to be exhausted. This standalone port keeps the same contract for
//! Zig types that expose `from_str`/`parse` declarations and for primitive
//! enums; callers receive an error instead of a silently accepted suffix.

const std = @import("std");

pub const ParseError = error{ InvalidSyntax, UnexpectedToken, InvalidNumber };

pub const CssToken = union(enum) {
    ident: []const u8,
    number: f32,
    dimension: struct { value: f32, unit: []const u8 },
};

pub fn ParseResult(comptime T: type) type {
    return struct {
        value: T,
        consumed: usize,
    };
}

fn trim(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn parse_float(comptime T: type, input: []const u8) ParseError!T {
    return std.fmt.parseFloat(T, input) catch {
        return error.InvalidNumber;
    };
}

fn parse_primitive(comptime T: type, input: []const u8) ParseError!T {
    if (T == []const u8) return input;
    if (T == f32) return std.fmt.parseFloat(f32, input) catch error.InvalidNumber;
    if (T == f64) return std.fmt.parseFloat(f64, input) catch error.InvalidNumber;
    switch (@typeInfo(T)) {
        .@"enum" => return std.meta.stringToEnum(T, input) orelse error.UnexpectedToken,
        else => {},
    }
    return error.InvalidSyntax;
}

pub fn parse_entirely(comptime T: type, input: []const u8) ParseError!T {
    const source = trim(input);
    if (source.len == 0) return error.InvalidSyntax;
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "from_str")) return T.from_str(source) catch error.InvalidSyntax;
            if (@hasDecl(T, "parse")) return T.parse(source) catch error.InvalidSyntax;
        },
        .@"enum" => {
            if (@hasDecl(T, "from_str")) return T.from_str(source) catch error.InvalidSyntax;
            if (@hasDecl(T, "parse")) return T.parse(source) catch error.InvalidSyntax;
        },
        else => {},
    }
    return parse_primitive(T, source);
}

pub fn from_css(comptime T: type, input: []const u8) ParseError!T {
    return parse_entirely(T, input);
}

pub fn parse_css_str_entirely(comptime T: type, input: []const u8) ParseError!T {
    return parse_entirely(T, input);
}

pub fn from_str(comptime T: type, input: []const u8) ParseError!T {
    return parse_entirely(T, input);
}

test "CSS parser rejects empty input and parses primitive values" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 12.5), try parse_entirely(f32, " 12.5 "));
    try testing.expectEqual(.wrap, try parse_entirely(enum { nowrap, wrap }, "wrap"));
    try testing.expectError(error.InvalidSyntax, parse_entirely(f32, ""));
}
