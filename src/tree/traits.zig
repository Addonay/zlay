//! Function-table form of Taffy's `tree/traits.rs`.
//!
//! The first literal pass preserves the separation between traversal and
//! layout access. Later this can become a comptime interface where the host
//! supplies a concrete tree type.

const geometry = @import("../geometry.zig");
const available = @import("../style/available_space.zig");
const style = @import("../style/mod.zig");
const layout = @import("layout.zig");
const node_mod = @import("node.zig");

/// Compute-time measure callback, matching Taffy's
/// `FnMut(LayoutInput, NodeId, Option<&mut NodeContext>, &Style) -> LayoutOutput`.
pub const MeasureFunc = *const fn (
    context: ?*anyopaque,
    inputs: layout.LayoutInput,
    node_id: node_mod.NodeId,
    style: *const style.Style,
) layout.LayoutOutput;

pub const TraversePartialTree = struct {
    context: *anyopaque,
    child_count_fn: *const fn (context: *anyopaque, node: u32) usize,
    child_at_fn: *const fn (context: *anyopaque, node: u32, index: usize) u32,

    pub fn child_count(self: TraversePartialTree, node: u32) usize {
        return self.child_count_fn(self.context, node);
    }
    pub fn get_child_id(self: TraversePartialTree, node: u32, index: usize) u32 {
        return self.child_at_fn(self.context, node, index);
    }

    pub fn child_ids(self: TraversePartialTree, node: u32) ChildIterator {
        return .{ .traversal = self, .node = node };
    }
};

/// Iterator equivalent of Taffy's associated `ChildIter` type. It keeps the
/// function-table ABI small while preserving the iterator boundary expected
/// by the recursive tree traits.
pub const ChildIterator = struct {
    traversal: TraversePartialTree,
    node: u32,
    index: usize = 0,

    pub fn next(self: *ChildIterator) ?u32 {
        if (self.index >= self.traversal.child_count(self.node)) return null;
        const child = self.traversal.get_child_id(self.node, self.index);
        self.index += 1;
        return child;
    }
};

pub const TraverseTree = TraversePartialTree;
pub const CacheTree = struct {
    context: *anyopaque,
    cache_get: *const fn (context: *anyopaque, node: u32, input: *const anyopaque) ?*const anyopaque,
    cache_store: *const fn (context: *anyopaque, node: u32, input: *const anyopaque, output: *const anyopaque) void,
    cache_clear: *const fn (context: *anyopaque, node: u32) void,

    pub fn cache_get_value(self: CacheTree, node: u32, input: *const anyopaque) ?*const anyopaque {
        return self.cache_get(self.context, node, input);
    }
    pub fn cache_store_value(self: CacheTree, node: u32, input: *const anyopaque, output: *const anyopaque) void {
        self.cache_store(self.context, node, input, output);
    }
    pub fn cache_clear_node(self: CacheTree, node: u32) void {
        self.cache_clear(self.context, node);
    }
};
pub const LayoutPartialTree = struct {
    traversal: TraversePartialTree,
    compute_child: ?*const fn (context: *anyopaque, node: u32, input: layout.LayoutInput) layout.LayoutOutput = null,
    set_unrounded: ?*const fn (context: *anyopaque, node: u32, value: layout.Layout) void = null,
    get_style_fn: ?*const fn (context: *anyopaque, node: u32) style.Style = null,
    cache_tree: ?CacheTree = null,
    resolve_calc_fn: ?*const fn (context: *anyopaque, value: ?*const anyopaque, basis: f32) f32 = null,
    set_detailed_grid_info_fn: ?*const fn (context: *anyopaque, node: u32, info: *const anyopaque) void = null,

    pub fn child_ids(self: LayoutPartialTree, node: u32) ChildIterator {
        return self.traversal.child_ids(node);
    }
    pub fn child_count(self: LayoutPartialTree, node: u32) usize {
        return self.traversal.child_count(node);
    }
    pub fn compute_child_layout(self: LayoutPartialTree, node: u32, input: layout.LayoutInput) layout.LayoutOutput {
        return if (self.compute_child) |function| function(self.traversal.context, node, input) else @panic("unconfigured Taffy LayoutPartialTree compute_child_layout");
    }
    pub fn set_unrounded_layout(self: LayoutPartialTree, node: u32, value: layout.Layout) void {
        if (self.set_unrounded) |function| function(self.traversal.context, node, value) else @panic("unconfigured Taffy LayoutPartialTree set_unrounded_layout");
    }

    pub fn get_style(self: LayoutPartialTree, node: u32) style.Style {
        return if (self.get_style_fn) |function| function(self.traversal.context, node) else @panic("unconfigured Taffy LayoutPartialTree get_style");
    }

    pub fn resolve_calc_value(self: LayoutPartialTree, value: ?*const anyopaque, basis: f32) f32 {
        return if (self.resolve_calc_fn) |function| function(self.traversal.context, value, basis) else 0;
    }

    pub fn cache_get(self: LayoutPartialTree, node: u32, input: *const anyopaque) ?*const anyopaque {
        return if (self.cache_tree) |cache| cache.cache_get_value(node, input) else null;
    }

    pub fn cache_store(self: LayoutPartialTree, node: u32, input: *const anyopaque, output: *const anyopaque) void {
        if (self.cache_tree) |cache| cache.cache_store_value(node, input, output);
    }

    pub fn cache_clear(self: LayoutPartialTree, node: u32) void {
        if (self.cache_tree) |cache| cache.cache_clear_node(node);
    }

    pub fn set_detailed_grid_info(self: LayoutPartialTree, node: u32, info: *const anyopaque) void {
        if (self.set_detailed_grid_info_fn) |function| function(self.traversal.context, node, info);
    }

    /// Measure one absolute axis under Taffy's `ComputeSize` run mode.
    pub fn measure_child_size(self: LayoutPartialTree, node: u32, known_dimensions: geometry.Size(?f32), parent_size: geometry.Size(?f32), available_space: geometry.Size(available.AvailableSpace), sizing_mode: layout.SizingMode, axis: geometry.AbsoluteAxis, vertical_margins_are_collapsible: geometry.Line(bool)) f32 {
        const output = self.compute_child_layout(node, .{
            .run_mode = .compute_size,
            .sizing_mode = sizing_mode,
            .axis = layout.requested_axis_from_absolute(axis),
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
        return if (axis == .horizontal) output.size.width else output.size.height;
    }

    pub fn measure_child_size_both(self: LayoutPartialTree, node: u32, known_dimensions: geometry.Size(?f32), parent_size: geometry.Size(?f32), available_space: geometry.Size(available.AvailableSpace), sizing_mode: layout.SizingMode, vertical_margins_are_collapsible: geometry.Line(bool)) geometry.Size(f32) {
        return self.compute_child_layout(node, .{
            .run_mode = .compute_size,
            .sizing_mode = sizing_mode,
            .axis = .both,
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        }).size;
    }

    pub fn perform_child_layout(self: LayoutPartialTree, node: u32, known_dimensions: geometry.Size(?f32), parent_size: geometry.Size(?f32), available_space: geometry.Size(available.AvailableSpace), sizing_mode: layout.SizingMode, vertical_margins_are_collapsible: geometry.Line(bool)) layout.LayoutOutput {
        return self.compute_child_layout(node, .{
            .run_mode = .perform_layout,
            .sizing_mode = sizing_mode,
            .axis = .both,
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
    }

    pub fn calc(self: LayoutPartialTree, value: ?*const anyopaque, basis: f32) f32 {
        return self.resolve_calc_value(value, basis);
    }
};
pub const RoundTree = struct {
    context: ?*anyopaque = null,
    get_unrounded: ?*const fn (context: *anyopaque, node: u32) layout.Layout = null,
    set_final: ?*const fn (context: *anyopaque, node: u32, value: layout.Layout) void = null,

    pub fn get_unrounded_layout(self: RoundTree, node: u32) layout.Layout {
        return if (self.get_unrounded) |function| function(self.context orelse @panic("unconfigured Taffy RoundTree context"), node) else @panic("unconfigured Taffy RoundTree get_unrounded_layout");
    }
    pub fn set_final_layout(self: RoundTree, node: u32, value: layout.Layout) void {
        if (self.set_final) |function| function(self.context orelse @panic("unconfigured Taffy RoundTree context"), node, value) else @panic("unconfigured Taffy RoundTree set_final_layout");
    }
};
pub const PrintTree = struct {
    context: ?*anyopaque = null,
    debug_label: ?*const fn (context: *anyopaque, node: u32) []const u8 = null,
    final_layout: ?*const fn (context: *anyopaque, node: u32) layout.Layout = null,

    pub fn get_debug_label(self: PrintTree, node: u32) []const u8 {
        return if (self.debug_label) |function| function(self.context orelse @panic("unconfigured Taffy PrintTree context"), node) else "node";
    }
    pub fn get_final_layout(self: PrintTree, node: u32) layout.Layout {
        return if (self.final_layout) |function| function(self.context orelse @panic("unconfigured Taffy PrintTree context"), node) else @panic("unconfigured Taffy PrintTree get_final_layout");
    }
};
pub const LayoutFlexboxContainer = struct { partial: LayoutPartialTree };
pub const LayoutGridContainer = struct { partial: LayoutPartialTree };
pub const LayoutBlockContainer = struct { partial: LayoutPartialTree };
