//! Taffy-compatible serde support using the `serde` Zig framework
//! (https://github.com/OrlovEvgeny/serde.zig, pinned in build.zig.zon).
//!
//! The wire format matches Taffy 0.14 with the `serde` feature enabled, which
//! was captured from the pinned Rust crate:
//!
//! * `CompactLength` (and the `LengthPercentage`, `LengthPercentageAuto`,
//!   `Dimension`, `MinTrackSizingFunction`, `MaxTrackSizingFunction` wrappers)
//!   serialize as the u64 wire bits `(tag << 32) | f32_bits`. Deserialization
//!   validates the tag set for each wrapper exactly as Rust does.
//! * Enums use PascalCase variant names (`"Flex"`, `"RowDense"`, ...).
//! * `AlignItems`/`AlignContent` serialize as a single string: the PascalCase
//!   keyword, prefixed with `Safe` when the safety flag is `safe`.
//! * `GridPlacement` uses external tagging (`"Auto"`, `{"Line":2}`,
//!   `{"NamedLine":["foo",-1]}`); named payloads serialize as two-element
//!   arrays like Rust's tuple variants.
//! * `Contain` serializes as its u8 bit set.
//!
//! Only types whose in-memory shape differs from the wire shape need hooks;
//! the rest rely on reflection plus `rename_all = .pascal_case`.

const std = @import("std");
const serde = @import("serde");

const compact = @import("style/compact_length.zig");
const dimension = @import("style/dimension.zig");
const alignment = @import("style/alignment.zig");
const grid = @import("style/grid.zig");
const style_mod = @import("style/mod.zig");

pub const pascal_options = .{ .rename_all = serde.NamingConvention.pascal_case };

// ---------------------------------------------------------------------------
// Entry points used as `zerdeSerialize` / `zerdeDeserialize` declarations
// ---------------------------------------------------------------------------

pub fn serialize(value: anytype, serializer: anytype) !void {
    // The framework may hand hooks a pointer to the field value.
    if (comptime @typeInfo(@TypeOf(value)) == .pointer and @typeInfo(@TypeOf(value)).pointer.size == .one) {
        return serialize(value.*, serializer);
    }
    const T = @TypeOf(value);
    if (comptime T == compact.CompactLength) return serializeCompactLength(value, serializer);
    if (comptime T == dimension.LengthPercentage) return serializeCompactLength(value.value, serializer);
    if (comptime T == dimension.LengthPercentageAuto) return serializeCompactLength(value.value, serializer);
    if (comptime T == dimension.Dimension) return serializeCompactLength(value.value, serializer);
    if (comptime T == grid.MinTrackSizingFunction) return serializeCompactLength(value.value, serializer);
    if (comptime T == grid.MaxTrackSizingFunction) return serializeCompactLength(value.value, serializer);
    if (comptime T == style_mod.Contain) return serializer.serializeInt(@as(u8, @bitCast(value)));
    if (comptime T == alignment.AlignItems) return serializeAlignment(value, serializer);
    if (comptime T == alignment.AlignContent) return serializeAlignment(value, serializer);
    if (comptime T == grid.NamedLine) return serializePair(value.name, value.index, serializer);
    if (comptime T == grid.NamedSpan) return serializePair(value.name, value.count, serializer);
    if (comptime T == grid.GridPlacement) return serializeGridPlacement(value, serializer);
    if (comptime T == grid.RepetitionCount) return serializeRepetitionCount(value, serializer);
    @compileError("serde_hooks has no serializer for " ++ @typeName(T));
}

pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, deserializer: anytype) @TypeOf(deserializer.*).Error!T {
    if (comptime T == compact.CompactLength) return deserializeCompactLength(deserializer);
    if (comptime T == dimension.LengthPercentage) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isLengthPercentageTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == dimension.LengthPercentageAuto) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isLengthPercentageAutoTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == dimension.Dimension) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isDimensionTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == grid.MinTrackSizingFunction) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isMinTrackTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == grid.MaxTrackSizingFunction) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isMaxTrackTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == style_mod.Contain) {
        const bits = try deserializer.deserializeInt(u8);
        return @bitCast(bits);
    }
    if (comptime T == alignment.AlignItems) return deserializeAlignment(T, allocator, deserializer);
    if (comptime T == alignment.AlignContent) return deserializeAlignment(T, allocator, deserializer);
    if (comptime T == grid.NamedLine) return deserializeNamedLine(allocator, deserializer);
    if (comptime T == grid.NamedSpan) return deserializeNamedSpan(allocator, deserializer);
    if (comptime T == grid.GridPlacement) return deserializeGridPlacement(allocator, deserializer);
    if (comptime T == grid.RepetitionCount) return deserializeRepetitionCount(allocator, deserializer);
    @compileError("serde_hooks has no deserializer for " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// CompactLength
// ---------------------------------------------------------------------------

fn serializeCompactLength(value: compact.CompactLength, serializer: anytype) !void {
    // Note: Rust's serde refuses to serialize calc values. The serde.zig JSON
    // serializer has a fixed two-error set (`OutOfMemory`, `WriteFailed`), so
    // a custom error cannot be propagated here; calc instead serializes as its
    // raw bits (`0`), which deserialization rejects as an invalid tag. This is
    // the one known serde wire divergence and is documented in report.md.
    if (value.is_calc()) {
        try serializer.serializeInt(@as(u64, 0));
        return;
    }
    try serializer.serializeInt(value.serialized());
}

fn deserializeCompactLength(deserializer: anytype) !compact.CompactLength {
    const bits = try deserializer.deserializeInt(u64);
    const tag: u8 = @intCast(bits >> 32);
    if (!isBaseCompactTag(tag)) return deserializer.raiseError(error.InvalidTag);
    return compact.from_serialized(bits);
}

/// Tags Rust accepts when deserializing a bare `CompactLength`
/// (everything except the calc tag and unknown bit patterns).
fn isBaseCompactTag(tag: u8) bool {
    return tag == @backingInt(compact.CompactLengthTag.length) or
        tag == @backingInt(compact.CompactLengthTag.percent) or
        tag == @backingInt(compact.CompactLengthTag.auto) or
        tag == @backingInt(compact.CompactLengthTag.min_content) or
        tag == @backingInt(compact.CompactLengthTag.max_content) or
        tag == @backingInt(compact.CompactLengthTag.fit_content_keyword) or
        tag == @backingInt(compact.CompactLengthTag.fit_content_px) or
        tag == @backingInt(compact.CompactLengthTag.fit_content_percent) or
        tag == @backingInt(compact.CompactLengthTag.stretch) or
        tag == @backingInt(compact.CompactLengthTag.content) or
        tag == @backingInt(compact.CompactLengthTag.fr);
}

fn isLengthPercentageTag(tag: compact.CompactLengthTag) bool {
    return tag == .length or tag == .percent;
}

fn isLengthPercentageAutoTag(tag: compact.CompactLengthTag) bool {
    return tag == .length or tag == .percent or tag == .auto;
}

/// Rust's `Dimension` deserializer accepts these tags (notably excluding fr).
fn isDimensionTag(tag: compact.CompactLengthTag) bool {
    return switch (tag) {
        .length, .percent, .auto, .min_content, .max_content, .fit_content_keyword, .fit_content_px, .fit_content_percent, .stretch, .content => true,
        else => false,
    };
}

fn isMinTrackTag(tag: compact.CompactLengthTag) bool {
    return switch (tag) {
        .length, .percent, .auto, .min_content, .max_content, .fit_content_px, .fit_content_percent => true,
        else => false,
    };
}

fn isMaxTrackTag(tag: compact.CompactLengthTag) bool {
    return switch (tag) {
        .length, .percent, .auto, .min_content, .max_content, .fit_content_px, .fit_content_percent, .fr => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// AlignItems / AlignContent
// ---------------------------------------------------------------------------

fn serializeAlignment(value: anytype, serializer: anytype) !void {
    var buffer: [32]u8 = undefined;
    const name = alignmentWireName(@TypeOf(value), value.keyword, value.safety, &buffer);
    try serializer.serializeString(name);
}

fn alignmentWireName(comptime T: type, keyword: anytype, safety: alignment.AlignmentSafety, buffer: []u8) []const u8 {
    const base = if (comptime T == alignment.AlignItems)
        alignItemsKeywordName(keyword)
    else if (comptime T == alignment.AlignContent)
        alignContentKeywordName(keyword)
    else
        @compileError("alignmentWireName: unsupported type " ++ @typeName(T));
    if (safety == .safe) return std.fmt.bufPrint(buffer, "Safe{s}", .{base}) catch unreachable;
    return base;
}

fn alignItemsKeywordName(keyword: alignment.AlignItemsKeyword) []const u8 {
    return switch (keyword) {
        .start => "Start",
        .end => "End",
        .flex_start => "FlexStart",
        .flex_end => "FlexEnd",
        .self_start => "SelfStart",
        .self_end => "SelfEnd",
        .center => "Center",
        .baseline => "Baseline",
        .stretch => "Stretch",
    };
}

fn alignContentKeywordName(keyword: alignment.AlignContentKeyword) []const u8 {
    return switch (keyword) {
        .start => "Start",
        .end => "End",
        .flex_start => "FlexStart",
        .flex_end => "FlexEnd",
        .center => "Center",
        .stretch => "Stretch",
        .space_between => "SpaceBetween",
        .space_evenly => "SpaceEvenly",
        .space_around => "SpaceAround",
    };
}

fn deserializeAlignment(comptime T: type, allocator: std.mem.Allocator, deserializer: anytype) @TypeOf(deserializer.*).Error!T {
    const text = try deserializer.deserializeString(allocator);
    defer serde.core.releaseString(deserializer, allocator, text);

    var safety: alignment.AlignmentSafety = .unsafe;
    var body = text;
    if (std.mem.startsWith(u8, body, "Safe")) {
        safety = .safe;
        body = body["Safe".len..];
        if (body.len == 0) return deserializer.raiseError(error.InvalidAlignment);
    }
    if (comptime T == alignment.AlignItems) {
        return .{ .keyword = parseAlignItemsKeyword(body) orelse return deserializer.raiseError(error.InvalidAlignment), .safety = safety };
    } else if (comptime T == alignment.AlignContent) {
        return .{ .keyword = parseAlignContentKeyword(body) orelse return deserializer.raiseError(error.InvalidAlignment), .safety = safety };
    }
    @compileError("deserializeAlignment: unsupported type " ++ @typeName(T));
}

fn parseAlignItemsKeyword(name: []const u8) ?alignment.AlignItemsKeyword {
    inline for (.{
        .{ "Start", alignment.AlignItemsKeyword.start },
        .{ "End", alignment.AlignItemsKeyword.end },
        .{ "FlexStart", alignment.AlignItemsKeyword.flex_start },
        .{ "FlexEnd", alignment.AlignItemsKeyword.flex_end },
        .{ "SelfStart", alignment.AlignItemsKeyword.self_start },
        .{ "SelfEnd", alignment.AlignItemsKeyword.self_end },
        .{ "Center", alignment.AlignItemsKeyword.center },
        .{ "Baseline", alignment.AlignItemsKeyword.baseline },
        .{ "Stretch", alignment.AlignItemsKeyword.stretch },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn parseAlignContentKeyword(name: []const u8) ?alignment.AlignContentKeyword {
    inline for (.{
        .{ "Start", alignment.AlignContentKeyword.start },
        .{ "End", alignment.AlignContentKeyword.end },
        .{ "FlexStart", alignment.AlignContentKeyword.flex_start },
        .{ "FlexEnd", alignment.AlignContentKeyword.flex_end },
        .{ "Center", alignment.AlignContentKeyword.center },
        .{ "Stretch", alignment.AlignContentKeyword.stretch },
        .{ "SpaceBetween", alignment.AlignContentKeyword.space_between },
        .{ "SpaceEvenly", alignment.AlignContentKeyword.space_evenly },
        .{ "SpaceAround", alignment.AlignContentKeyword.space_around },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Named grid lines (Rust tuple variants serialize as two-element arrays)
// ---------------------------------------------------------------------------

fn serializePair(name: []const u8, second: anytype, serializer: anytype) !void {
    var array = try serializer.beginArray();
    try array.serializeString(name);
    try array.serializeInt(second);
    try array.end();
}

fn deserializeNamedLine(allocator: std.mem.Allocator, deserializer: anytype) !grid.NamedLine {
    var sequence = try deserializer.deserializeSeqAccess();
    const name = (try sequence.nextElement([]const u8, allocator)) orelse return deserializer.raiseError(error.InvalidLength);
    const index = (try sequence.nextElement(i16, allocator)) orelse return deserializer.raiseError(error.InvalidLength);
    // Consume the closing bracket; reject any extra elements.
    if (try sequence.nextElement(serde.core.Value, allocator) != null) return deserializer.raiseError(error.UnexpectedToken);
    return .{ .name = name, .index = index };
}

fn deserializeNamedSpan(allocator: std.mem.Allocator, deserializer: anytype) !grid.NamedSpan {
    var sequence = try deserializer.deserializeSeqAccess();
    const name = (try sequence.nextElement([]const u8, allocator)) orelse return deserializer.raiseError(error.InvalidLength);
    const count = (try sequence.nextElement(u16, allocator)) orelse return deserializer.raiseError(error.InvalidLength);
    if (try sequence.nextElement(serde.core.Value, allocator) != null) return deserializer.raiseError(error.UnexpectedToken);
    return .{ .name = name, .count = count };
}

// ---------------------------------------------------------------------------
// GridPlacement / RepetitionCount
//
// These unions mix void variants with payload variants. serde.zig's external
// union rename does not apply to void variants, so both directions are
// implemented explicitly to match Taffy's Rust representation exactly.
// ---------------------------------------------------------------------------

fn protocolBackend(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}

fn Protocol(comptime D: type) type {
    if (@hasDecl(D, "serde_protocol")) return D.serde_protocol;
    return struct {
        pub fn checkpoint(d: *D) D {
            return d.*;
        }
        pub fn restore(d: *D, saved: D) void {
            d.* = saved;
        }
    };
}

fn serializeGridPlacement(value: grid.GridPlacement, serializer: anytype) !void {
    switch (value) {
        .auto => try serializer.serializeString("Auto"),
        .line => |line| try serializeTagged("Line", line, serializer),
        .span => |span| try serializeTagged("Span", span, serializer),
        .named_line => |named| try serializeTagged("NamedLine", .{ named.name, named.index }, serializer),
        .named_span => |named| try serializeTagged("NamedSpan", .{ named.name, named.count }, serializer),
    }
}

fn serializeRepetitionCount(value: grid.RepetitionCount, serializer: anytype) !void {
    switch (value) {
        .auto_fit => try serializer.serializeString("AutoFit"),
        .auto_fill => try serializer.serializeString("AutoFill"),
        .count => |count| try serializeTagged("Count", count, serializer),
    }
}

fn serializeTagged(comptime tag: []const u8, payload: anytype, serializer: anytype) !void {
    var object = try serializer.beginStruct();
    try object.serializeField(tag, payload);
    try object.end();
}

fn deserializeGridPlacement(allocator: std.mem.Allocator, deserializer: anytype) !grid.GridPlacement {
    const D = protocolBackend(@TypeOf(deserializer));
    const saved = Protocol(D).checkpoint(deserializer);
    if (deserializer.deserializeString(allocator)) |name| {
        defer serde.core.releaseString(deserializer, allocator, name);
        if (std.mem.eql(u8, name, "Auto")) return .auto;
        Protocol(D).restore(deserializer, saved);
    } else |err| {
        if (err == error.OutOfMemory) return deserializer.raiseError(error.OutOfMemory);
        Protocol(D).restore(deserializer, saved);
    }

    var access = try deserializer.deserializeStruct(grid.GridPlacement);
    const key = (try access.nextKey(allocator)) orelse return deserializer.raiseError(error.MissingField);
    defer access.freeKey(key, allocator);
    if (std.mem.eql(u8, key, "Line")) {
        const payload = try access.nextValue(i16, allocator);
        try expectNoMoreKeys(&access, allocator, deserializer);
        return .{ .line = payload };
    }
    if (std.mem.eql(u8, key, "Span")) {
        const payload = try access.nextValue(u16, allocator);
        try expectNoMoreKeys(&access, allocator, deserializer);
        return .{ .span = payload };
    }
    if (std.mem.eql(u8, key, "NamedLine")) {
        const payload = try access.nextValue(grid.NamedLine, allocator);
        try expectNoMoreKeys(&access, allocator, deserializer);
        return .{ .named_line = payload };
    }
    if (std.mem.eql(u8, key, "NamedSpan")) {
        const payload = try access.nextValue(grid.NamedSpan, allocator);
        try expectNoMoreKeys(&access, allocator, deserializer);
        return .{ .named_span = payload };
    }
    return deserializer.raiseError(error.UnexpectedToken);
}

fn deserializeRepetitionCount(allocator: std.mem.Allocator, deserializer: anytype) !grid.RepetitionCount {
    const D = protocolBackend(@TypeOf(deserializer));
    const saved = Protocol(D).checkpoint(deserializer);
    if (deserializer.deserializeString(allocator)) |name| {
        defer serde.core.releaseString(deserializer, allocator, name);
        if (std.mem.eql(u8, name, "AutoFit")) return .auto_fit;
        if (std.mem.eql(u8, name, "AutoFill")) return .auto_fill;
        Protocol(D).restore(deserializer, saved);
    } else |err| {
        if (err == error.OutOfMemory) return deserializer.raiseError(error.OutOfMemory);
        Protocol(D).restore(deserializer, saved);
    }

    var access = try deserializer.deserializeStruct(grid.RepetitionCount);
    const key = (try access.nextKey(allocator)) orelse return deserializer.raiseError(error.MissingField);
    defer access.freeKey(key, allocator);
    if (std.mem.eql(u8, key, "Count")) {
        const payload = try access.nextValue(u16, allocator);
        try expectNoMoreKeys(&access, allocator, deserializer);
        return .{ .count = payload };
    }
    return deserializer.raiseError(error.UnexpectedToken);
}

fn expectNoMoreKeys(access: anytype, allocator: std.mem.Allocator, deserializer: anytype) !void {
    if (try access.nextKey(allocator)) |extra| {
        access.freeKey(extra, allocator);
        return deserializer.raiseError(error.UnexpectedToken);
    }
}
