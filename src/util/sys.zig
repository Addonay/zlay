//! Direct-port home for Taffy's `util/sys.rs` platform helpers.
//!
//! Taffy's Rust implementation uses small platform abstractions for `Vec`,
//! string identifiers and f32 operations. Zig's standard containers and
//! slices are the direct equivalents; this file is the explicit seam.

pub fn saturating_i16(value: i32) i16 {
    if (value > std.math.maxInt(i16)) return std.math.maxInt(i16);
    if (value < std.math.minInt(i16)) return std.math.minInt(i16);
    return @intCast(value);
}

pub fn round(value: f32) f32 {
    return @round(value);
}
pub fn ceil(value: f32) f32 {
    return @ceil(value);
}
pub fn floor(value: f32) f32 {
    return @floor(value);
}
pub fn abs(value: f32) f32 {
    return @abs(value);
}
pub fn f32_max(a: f32, b: f32) f32 {
    return @max(a, b);
}
pub fn f32_min(a: f32, b: f32) f32 {
    return @min(a, b);
}
pub fn fract(value: f32) f32 {
    return value - @floor(value);
}

pub fn new_vec_with_capacity(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !std.ArrayList(T) {
    var result = std.ArrayList(T).empty;
    try result.ensureTotalCapacity(allocator, capacity);
    return result;
}

const std = @import("std");
