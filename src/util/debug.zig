//! Direct-port home for Taffy's `util/debug.rs`.

pub const DebugFlags = packed struct(u8) {
    log_layout: bool = false,
    log_cache: bool = false,
    log_grid: bool = false,
    log_flex: bool = false,
    _reserved: u4 = 0,
};

pub const DebugLogger = struct {
    enabled: bool = false,

    pub fn new() DebugLogger {
        return .{};
    }
    pub fn push_node(self: *DebugLogger, _: u32) void {
        self.enabled = self.enabled;
    }
    pub fn pop_node(self: *DebugLogger) void {
        self.enabled = self.enabled;
    }
    pub fn log(self: *const DebugLogger, message: []const u8) void {
        if (self.enabled) std.debug.print("{s}\n", .{message});
    }
    pub fn labelled_log(self: *const DebugLogger, label: []const u8, message: []const u8) void {
        if (self.enabled) std.debug.print("{s}: {s}\n", .{ label, message });
    }
    pub fn debug_log(self: *const DebugLogger, message: []const u8) void {
        self.log(message);
    }
    pub fn labelled_debug_log(self: *const DebugLogger, label: []const u8, message: []const u8) void {
        self.labelled_log(label, message);
    }
};

pub var node_logger = DebugLogger.new();

pub fn debug_log(message: []const u8) void {
    node_logger.log(message);
}

const std = @import("std");
