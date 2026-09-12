//! Allocator-backed high-level tree corresponding to Taffy's
//! `tree/taffy_tree.rs`.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style/mod.zig");
const layout_mod = @import("layout.zig");
const cache = @import("cache.zig");
const node = @import("node.zig");
const traits = @import("traits.zig");
const compute = @import("../compute/mod.zig");

pub const NodeId = node.NodeId;
pub const TaffyError = error{ InvalidParentNode, InvalidChildNode, InvalidInputNode, ChildIndexOutOfBounds };
pub const Error = TaffyError;

pub const TaffyConfig = struct {
    use_rounding: bool = true,

    pub fn default() TaffyConfig {
        return .{};
    }
};
pub fn TaffyResult(comptime T: type) type {
    return TaffyError!T;
}

pub const NodeData = struct {
    style: style_mod.Style,
    unrounded_layout: layout_mod.Layout = .{},
    final_layout: layout_mod.Layout = .{},
    children: std.ArrayList(NodeId),
    parent: ?NodeId = null,
    cache: cache.Cache = .{},
    alive: bool = true,
    /// Per-node measure context (Taffy's `NodeContext`). `has_context` mirrors
    /// Taffy's flag so a null context can still be a stored context.
    has_context: bool = false,
    context: ?*anyopaque = null,
    detailed_layout_info: layout_mod.DetailedLayoutInfo = .none,
    /// Destructor for `detailed_layout_info`, supplied by the algorithm that
    /// produced it (the tree layer cannot know concrete detail types).
    detailed_info_deinit: ?*const fn (*const anyopaque, std.mem.Allocator) void = null,

    fn deinit(self: *NodeData, allocator: std.mem.Allocator) void {
        freeDetailedInfo(self, allocator);
        self.children.deinit(allocator);
    }
};

fn freeDetailedInfo(node_data: *NodeData, allocator: std.mem.Allocator) void {
    if (node_data.detailed_layout_info != .none) {
        if (node_data.detailed_info_deinit) |deinit_fn| {
            deinit_fn(node_data.detailed_layout_info.grid, allocator);
        }
        node_data.detailed_layout_info = .none;
        node_data.detailed_info_deinit = null;
    }
}

/// Paged node storage.
///
/// Taffy's slotmap inserts into immovable blocks; the Zig port previously used
/// one `ArrayList(NodeData)` whose doubling growth memcpy'd the entire tree on
/// every capacity increase (`NodeData` is ~1.9 KB). Pages are allocated once
/// and never moved, so node insertion is O(1) with no large copies, while node
/// identity stays a dense `u32` index (page = id >> shift).
pub const NodeStore = struct {
    pub const page_shift: u6 = 6;
    pub const page_size: usize = 1 << page_shift;

    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged([]NodeData) = .empty,
    /// Number of slots ever appended; live ids are `0..len`.
    len: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) NodeStore {
        return .{ .allocator = allocator };
    }

    fn pageIndex(id: u32) usize {
        return id >> page_shift;
    }

    fn pageOffset(id: u32) usize {
        return id & (page_size - 1);
    }

    pub fn ensurePages(self: *NodeStore, count: usize) !void {
        const required = (count + page_size - 1) / page_size;
        while (self.pages.items.len < required) {
            const page = try self.allocator.alloc(NodeData, page_size);
            // Pages are filled slot-by-slot by `append`; only the used slots
            // are ever read.
            try self.pages.append(self.allocator, page);
        }
    }

    /// In-place leaf construction: write the new node directly into its page
    /// slot instead of building a ~1.2 KB temporary and copying it.
    pub fn appendLeaf(self: *NodeStore, value: style_mod.Style) !NodeId {
        const id = self.len;
        try self.ensurePages(self.len + 1);
        self.len += 1;
        const node_data = self.at(id);
        node_data.style = value;
        node_data.unrounded_layout = .{};
        node_data.final_layout = .{};
        node_data.children = .empty;
        node_data.parent = null;
        node_data.cache = .{};
        node_data.alive = true;
        node_data.has_context = false;
        node_data.context = null;
        node_data.detailed_layout_info = .none;
        node_data.detailed_info_deinit = null;
        return id;
    }

    pub fn append(self: *NodeStore, data: NodeData) !NodeId {
        const id = self.len;
        try self.ensurePages(self.len + 1);
        self.pages.items[pageIndex(id)][pageOffset(id)] = data;
        self.len += 1;
        return id;
    }

    /// Mutable access to an uninitialized-capacity slot is never exposed; the
    /// index must be < `len`.
    pub fn at(self: *NodeStore, id: u32) *NodeData {
        return &self.pages.items[pageIndex(id)][pageOffset(id)];
    }

    pub fn atConst(self: *const NodeStore, id: u32) *const NodeData {
        return &self.pages.items[pageIndex(id)][pageOffset(id)];
    }

    /// Free the backing pages. Callers deinit live nodes first.
    pub fn deinit(self: *NodeStore) void {
        for (self.pages.items) |page| self.allocator.free(page);
        self.pages.deinit(self.allocator);
        self.len = 0;
    }
};

pub const TaffyTree = struct {
    allocator: std.mem.Allocator,
    nodes: NodeStore,
    use_rounding: bool = true,
    /// Measure callback active for the current compute run. `compute_layout`
    /// uses Taffy's default (zero-size) measure; `compute_layout_with_measure`
    /// installs the caller's callback for the duration of the run.
    measure_function: ?traits.MeasureFunc = null,
    /// Per-tree arena for layout-pass temporaries (line lists, placement
    /// scratch, track arrays, occupancy intervals, ...). Allocations made from
    /// `scratchAllocator()` are owned by the tree and valid until the next
    /// top-level layout pass (or `resetScratch`/`clear`); nothing allocated
    /// from it is allowed to escape the pass that requested it. Resetting
    /// keeps the arena's capacity, so repeated passes reuse the same block
    /// instead of returning to the backing allocator.
    scratch: std.heap.ArenaAllocator,
    /// True while a layout pass is active. The scratch arena is reset only
    /// when a pass starts outside every other pass, so re-entrant child
    /// computes (the algorithms call back through `compute_child_layout`)
    /// cannot invalidate temporaries the outer pass is still using.
    in_layout_pass: bool = false,

    pub fn init(allocator: std.mem.Allocator) TaffyTree {
        return .{ .allocator = allocator, .nodes = NodeStore.init(allocator), .scratch = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn new(allocator: std.mem.Allocator) TaffyTree {
        return init(allocator);
    }

    pub fn init_with_config(allocator: std.mem.Allocator, config: TaffyConfig) TaffyTree {
        return .{ .allocator = allocator, .nodes = NodeStore.init(allocator), .use_rounding = config.use_rounding, .scratch = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn new_with_config(allocator: std.mem.Allocator, config: TaffyConfig) TaffyTree {
        return init_with_config(allocator, config);
    }

    pub fn with_capacity(allocator: std.mem.Allocator, capacity: usize) TaffyTree {
        var result = init(allocator);
        result.nodes.ensurePages(capacity) catch @panic("Taffy tree allocation failed");
        return result;
    }

    pub fn enable_rounding(self: *TaffyTree) void {
        self.use_rounding = true;
    }
    pub fn disable_rounding(self: *TaffyTree) void {
        self.use_rounding = false;
    }

    pub fn deinit(self: *TaffyTree) void {
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) self.nodes.at(index).deinit(self.allocator);
        self.nodes.deinit();
        self.scratch.deinit();
        self.in_layout_pass = false;
    }

    /// Allocator for layout-pass temporaries. Memory is owned by the tree and
    /// invalidated by the next top-level layout pass, `resetScratch`, `clear`
    /// or `deinit`. Never store an escaping pointer/reference in it.
    pub fn scratchAllocator(self: *TaffyTree) std.mem.Allocator {
        return self.scratch.allocator();
    }

    /// Invalidate every `scratchAllocator()` allocation, retaining the arena's
    /// capacity for the next pass. Called automatically when a top-level
    /// layout pass begins; only needed manually when driving the compute
    /// functions directly without `compute_layout`/`compute_child_layout`.
    pub fn resetScratch(self: *TaffyTree) void {
        _ = self.scratch.reset(.retain_capacity);
    }

    pub fn total_node_count(self: *const TaffyTree) usize {
        var count: usize = 0;
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) {
            if (self.nodes.atConst(index).alive) count += 1;
        }
        return count;
    }

    /// Drop all nodes while retaining the allocator-backed node capacity.
    pub fn clear(self: *TaffyTree) void {
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) self.nodes.at(index).deinit(self.allocator);
        self.nodes.len = 0;
        self.resetScratch();
    }

    pub fn new_leaf(self: *TaffyTree, value: style_mod.Style) !NodeId {
        return try self.nodes.appendLeaf(value);
    }

    /// Create a measured leaf, corresponding to Taffy's
    /// `new_leaf_with_context` API. The context is opaque to the tree and is
    /// passed back to the measure callback installed at compute time.
    pub fn new_leaf_with_context(self: *TaffyTree, value: style_mod.Style, context: ?*anyopaque) !NodeId {
        const id = try self.new_leaf(value);
        const node_data = self.nodes.at(id);
        node_data.context = context;
        node_data.has_context = context != null;
        return id;
    }

    pub fn new_with_children(self: *TaffyTree, value: style_mod.Style, child_list: []const NodeId) !NodeId {
        const id = try self.new_leaf(value);
        try self.set_children(id, child_list);
        return id;
    }

    pub fn set_children(self: *TaffyTree, parent_id: NodeId, child_list: []const NodeId) !void {
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        // Validate everything before mutating: a rejected child ID must
        // leave the tree untouched, not half-detached (reparenting moves
        // edges out of other parents below).
        for (child_list) |child_id| {
            const child = self.get_node_mut(child_id) orelse return error.InvalidChildNode;
            if (child.parent) |old_parent| {
                if (old_parent != parent_id and self.get_node(old_parent) == null) return error.InvalidParentNode;
            }
        }
        for (parent_node.children.items) |old_child| {
            if (self.get_node_mut(old_child)) |old| old.parent = null;
        }
        parent_node.children.clearRetainingCapacity();
        for (child_list) |child_id| {
            const child = self.get_node_mut(child_id) orelse return error.InvalidChildNode;
            // Detach from a previous parent first (marks it dirty); silently
            // leaving the old edge creates two layout parents and a stale
            // cached layout on the old one.
            try self.detach_from_parent(child_id, child.parent, parent_id);
            child.parent = parent_id;
            try parent_node.children.append(self.allocator, child_id);
        }
        self.mark_dirty(parent_id);
    }

    pub fn add_child(self: *TaffyTree, parent_id: NodeId, child: NodeId) !void {
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        const child_node = self.get_node_mut(child) orelse return error.InvalidChildNode;
        try self.detach_from_parent(child, child_node.parent, parent_id);
        child_node.parent = parent_id;
        try parent_node.children.append(self.allocator, child);
        self.mark_dirty(parent_id);
    }

    pub fn insert_child_at_index(self: *TaffyTree, parent_id: NodeId, index: usize, child: NodeId) !void {
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        const child_node = self.get_node_mut(child) orelse return error.InvalidChildNode;
        if (index > parent_node.children.items.len) return error.ChildIndexOutOfBounds;
        try self.detach_from_parent(child, child_node.parent, parent_id);
        try parent_node.children.insert(self.allocator, index, child);
        child_node.parent = parent_id;
        self.mark_dirty(parent_id);
    }

    pub fn remove_child(self: *TaffyTree, parent_id: NodeId, child: NodeId) !NodeId {
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        for (parent_node.children.items, 0..) |child_id, index| {
            if (child_id == child) {
                _ = parent_node.children.orderedRemove(index);
                if (self.get_node_mut(child)) |child_node| child_node.parent = null;
                self.mark_dirty(parent_id);
                return child;
            }
        }
        return error.InvalidChildNode;
    }

    pub fn remove_child_at_index(self: *TaffyTree, parent_id: NodeId, index: usize) !NodeId {
        const child = try self.child_at(parent_id, index);
        return self.remove_child(parent_id, child);
    }

    pub fn remove_children_range(self: *TaffyTree, parent_id: NodeId, start: usize, end: usize) !void {
        if (start > end) return error.ChildIndexOutOfBounds;
        var index = end;
        while (index > start) {
            index -= 1;
            _ = try self.remove_child_at_index(parent_id, index);
        }
    }

    pub fn replace_child_at_index(self: *TaffyTree, parent_id: NodeId, index: usize, child: NodeId) !NodeId {
        const old_child = try self.child_at(parent_id, index);
        _ = try self.remove_child_at_index(parent_id, index);
        try self.insert_child_at_index(parent_id, index, child);
        return old_child;
    }

    pub fn child_count(self: *const TaffyTree, parent_id: NodeId) !usize {
        return (self.get_node(parent_id) orelse return error.InvalidParentNode).children.items.len;
    }

    pub fn child_at(self: *const TaffyTree, parent_id: NodeId, index: usize) !NodeId {
        const child_list = (self.get_node(parent_id) orelse return error.InvalidParentNode).children.items;
        if (index >= child_list.len) return error.ChildIndexOutOfBounds;
        return child_list[index];
    }

    pub fn child_at_index(self: *const TaffyTree, parent_id: NodeId, index: usize) !NodeId {
        return self.child_at(parent_id, index);
    }

    pub fn child_ids(self: *const TaffyTree, parent_id: NodeId) ![]const NodeId {
        return self.children(parent_id);
    }

    pub fn get_child_id(self: *const TaffyTree, parent_id: NodeId, index: usize) !NodeId {
        return self.child_at(parent_id, index);
    }

    pub fn children(self: *const TaffyTree, parent_id: NodeId) ![]const NodeId {
        return (self.get_node(parent_id) orelse return error.InvalidParentNode).children.items;
    }

    pub fn parent(self: *const TaffyTree, child_id: NodeId) !?NodeId {
        return (self.get_node(child_id) orelse return error.InvalidInputNode).parent;
    }

    pub fn style_of(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return (self.get_node(id) orelse return error.InvalidInputNode).style;
    }

    /// Borrowed style pointer: no ~512-byte `Style` copy per call. Pointers
    /// are stable because nodes live in paged storage and are never moved.
    pub fn style_ptr(self: *const TaffyTree, id: NodeId) ?*const style_mod.Style {
        return &(self.get_node(id) orelse return null).style;
    }

    pub fn style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }

    pub fn set_style(self: *TaffyTree, id: NodeId, value: style_mod.Style) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.style = value;
        self.mark_dirty(id);
    }

    pub fn layout_of(self: *const TaffyTree, id: NodeId) !layout_mod.Layout {
        const node_data = self.get_node(id) orelse return error.InvalidInputNode;
        return if (self.use_rounding) node_data.final_layout else node_data.unrounded_layout;
    }

    pub fn layout(self: *const TaffyTree, id: NodeId) !layout_mod.Layout {
        return self.layout_of(id);
    }

    pub fn detailed_layout_info(self: *const TaffyTree, id: NodeId) !layout_mod.DetailedLayoutInfo {
        return (self.get_node(id) orelse return error.InvalidInputNode).detailed_layout_info;
    }

    /// Store algorithm-produced detailed information for a node, freeing any
    /// previous value with the destructor supplied by its producer.
    pub fn set_detailed_grid_info(self: *TaffyTree, id: NodeId, info: *const anyopaque, deinit_fn: *const fn (*const anyopaque, std.mem.Allocator) void) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        freeDetailedInfo(node_data, self.allocator);
        node_data.detailed_layout_info = .{ .grid = info };
        node_data.detailed_info_deinit = deinit_fn;
    }

    pub fn unrounded_layout(self: *const TaffyTree, id: NodeId) !layout_mod.Layout {
        return (self.get_node(id) orelse return error.InvalidInputNode).unrounded_layout;
    }

    pub fn get_final_layout(self: *const TaffyTree, id: NodeId) !layout_mod.Layout {
        return self.layout_of(id);
    }
    pub fn get_unrounded_layout(self: *const TaffyTree, id: NodeId) !layout_mod.Layout {
        return self.unrounded_layout(id);
    }

    pub fn set_unrounded_layout(self: *TaffyTree, id: NodeId, value: layout_mod.Layout) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.unrounded_layout = value;
    }

    pub fn set_final_layout(self: *TaffyTree, id: NodeId, value: layout_mod.Layout) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.final_layout = value;
    }

    pub fn cache_get(self: *TaffyTree, id: NodeId, input: *const layout_mod.LayoutInput) ?layout_mod.LayoutOutput {
        const node_data = self.get_node_mut(id) orelse return null;
        return node_data.cache.get(input.*);
    }

    pub fn cache_store(self: *TaffyTree, id: NodeId, input: *const layout_mod.LayoutInput, output: layout_mod.LayoutOutput) void {
        if (self.get_node_mut(id)) |node_data| node_data.cache.store(input.*, output);
    }

    pub fn cache_clear(self: *TaffyTree, id: NodeId) void {
        if (self.get_node_mut(id)) |node_data| _ = node_data.cache.clear();
    }

    pub fn get_debug_label(self: *const TaffyTree, id: NodeId) []const u8 {
        _ = self;
        _ = id;
        return "node";
    }

    pub fn get_core_container_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }
    pub fn get_block_container_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }
    pub fn get_block_child_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }
    pub fn get_flexbox_container_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }
    pub fn get_flexbox_child_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }
    pub fn get_grid_container_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }
    pub fn get_grid_child_style(self: *const TaffyTree, id: NodeId) !style_mod.Style {
        return self.style_of(id);
    }

    pub fn resolve_calc_value(self: *const TaffyTree, _: ?*const anyopaque, _: f32) f32 {
        _ = self;
        return 0;
    }

    pub fn compute_child_layout(self: *TaffyTree, id: NodeId, input: layout_mod.LayoutInput) !layout_mod.LayoutOutput {
        // The incremental entry path is a scratch epoch of its own. Child
        // computes issued by the algorithms re-enter here while a pass is
        // active, so they must not reset the arena the outer pass is using.
        if (self.in_layout_pass) return compute.compute_cached_layout(self, id, input);
        self.resetScratch();
        self.in_layout_pass = true;
        defer self.in_layout_pass = false;
        return compute.compute_cached_layout(self, id, input);
    }

    pub fn mark_dirty(self: *TaffyTree, id: NodeId) void {
        var current: ?NodeId = id;
        while (current) |node_id| {
            const node_data = self.get_node_mut(node_id) orelse break;
            // Taffy stops as soon as an ancestor is already dirty: its cache
            // is empty, so every ancestor above it was cleared before.
            switch (node_data.cache.clear()) {
                .already_empty => break,
                .cleared => {},
            }
            current = node_data.parent;
        }
    }

    /// Taffy reports a node as dirty when its cache is empty; the algorithm
    /// cache is the single source of truth (mutations clear it).
    pub fn is_dirty(self: *const TaffyTree, id: NodeId) !bool {
        return (self.get_node(id) orelse return error.InvalidInputNode).cache.is_empty();
    }

    pub fn dirty(self: *const TaffyTree, id: NodeId) !bool {
        return self.is_dirty(id);
    }

    pub fn set_node_context(self: *TaffyTree, id: NodeId, context: ?*anyopaque) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.context = context;
        node_data.has_context = context != null;
        self.mark_dirty(id);
    }

    pub fn get_node_context(self: *const TaffyTree, id: NodeId) ?*anyopaque {
        const node_data = self.get_node(id) orelse return null;
        return if (node_data.has_context) node_data.context else null;
    }

    pub fn get_node_context_mut(self: *TaffyTree, id: NodeId) ?*anyopaque {
        const node_data = self.get_node_mut(id) orelse return null;
        return if (node_data.has_context) node_data.context else null;
    }

    pub fn compute_layout(self: *TaffyTree, id: NodeId, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) !void {
        try self.compute_layout_impl(id, available_space);
    }

    pub fn compute_layout_with_measure(self: *TaffyTree, id: NodeId, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace), measure_function: traits.MeasureFunc) !void {
        const previous = self.measure_function;
        self.measure_function = measure_function;
        defer self.measure_function = previous;
        try self.compute_layout_impl(id, available_space);
    }

    fn compute_layout_impl(self: *TaffyTree, id: NodeId, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) !void {
        _ = try compute.compute_root_layout(self, id, available_space);
        if (self.use_rounding) try compute.round_layout(self, id);
    }

    /// Taffy `LayoutPartialTreeExt::measure_child_size`: compute a child's size
    /// on one axis with `RunMode::ComputeSize`.
    pub fn measure_child_size(
        self: *TaffyTree,
        node_id: NodeId,
        known_dimensions: geometry.Size(?f32),
        parent_size: geometry.Size(?f32),
        available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace),
        sizing_mode: layout_mod.SizingMode,
        axis: geometry.AbsoluteAxis,
        vertical_margins_are_collapsible: geometry.Line(bool),
    ) !f32 {
        const output = try self.compute_child_layout(node_id, .{
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .sizing_mode = sizing_mode,
            .axis = if (axis == .horizontal) .horizontal else .vertical,
            .run_mode = .compute_size,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
        return output.size.get_abs(axis);
    }

    /// Taffy `LayoutPartialTreeExt::measure_child_size_both`.
    pub fn measure_child_size_both(
        self: *TaffyTree,
        node_id: NodeId,
        known_dimensions: geometry.Size(?f32),
        parent_size: geometry.Size(?f32),
        available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace),
        sizing_mode: layout_mod.SizingMode,
        vertical_margins_are_collapsible: geometry.Line(bool),
    ) !geometry.Size(f32) {
        const output = try self.compute_child_layout(node_id, .{
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .sizing_mode = sizing_mode,
            .axis = .both,
            .run_mode = .compute_size,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
        return output.size;
    }

    /// Taffy `LayoutPartialTreeExt::perform_child_layout`.
    pub fn perform_child_layout(
        self: *TaffyTree,
        node_id: NodeId,
        known_dimensions: geometry.Size(?f32),
        parent_size: geometry.Size(?f32),
        available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace),
        sizing_mode: layout_mod.SizingMode,
        vertical_margins_are_collapsible: geometry.Line(bool),
    ) !layout_mod.LayoutOutput {
        return self.compute_child_layout(node_id, .{
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .sizing_mode = sizing_mode,
            .axis = .both,
            .run_mode = .perform_layout,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
    }

    pub fn remove(self: *TaffyTree, id: NodeId) !NodeId {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        const old_parent = node_data.parent;
        if (old_parent) |parent_id| {
            if (self.get_node_mut(parent_id)) |parent_node| {
                var index: usize = 0;
                while (index < parent_node.children.items.len) : (index += 1) {
                    if (parent_node.children.items[index] == id) {
                        _ = parent_node.children.orderedRemove(index);
                        break;
                    }
                }
                self.mark_dirty(parent_id);
            }
        }
        for (node_data.children.items) |child_id| {
            if (self.get_node_mut(child_id)) |child| child.parent = null;
        }
        node_data.children.clearRetainingCapacity();
        node_data.parent = null;
        freeDetailedInfo(node_data, self.allocator);
        node_data.alive = false;
        _ = node_data.cache.clear();
        return id;
    }

    /// Remove the last live node in arena order. Node IDs are intentionally
    /// not reused, matching the stable identity boundary of the high-level
    /// tree even though the backing storage is an ArrayList.
    pub fn remove_last_node(self: *TaffyTree) !NodeId {
        var index = self.nodes.len;
        while (index > 0) {
            index -= 1;
            if (self.nodes.atConst(index).alive) return self.remove(@intCast(index));
        }
        return error.InvalidInputNode;
    }

    pub fn print_tree(self: *const TaffyTree, root: NodeId) void {
        std.debug.print("TREE\n", .{});
        self.print_tree_node(root, "", false);
    }

    fn print_tree_node(self: *const TaffyTree, id: NodeId, prefix: []const u8, has_sibling: bool) void {
        const value = self.layout_of(id) catch return;
        std.debug.print("{s}{s}node [x={d} y={d} w={d} h={d}] ({d})\n", .{ prefix, if (has_sibling) "├── " else "└── ", value.location.x, value.location.y, value.size.width, value.size.height, id });
        const child_list = self.children(id) catch return;
        for (child_list, 0..) |child, child_index| self.print_tree_node(child, prefix, child_index + 1 < child_list.len);
    }

    pub fn node(self: *TaffyTree, id: NodeId) ?*NodeData {
        return self.get_node_mut(id);
    }

    /// Immutable node access used by the grid-estimation and diagnostic
    /// stages. Taffy exposes this through `Tree`/`PrintTree` trait methods;
    /// Zig keeps the const boundary explicit instead of returning a mutable
    /// pointer from a const tree.
    pub fn node_const(self: *const TaffyTree, id: NodeId) ?*const NodeData {
        return self.get_node(id);
    }

    fn detach_from_parent(self: *TaffyTree, child_id: NodeId, old_parent: ?NodeId, new_parent: NodeId) !void {
        const old_parent_id = old_parent orelse return;
        if (old_parent_id == new_parent) return;
        const old_parent_node = self.get_node_mut(old_parent_id) orelse return error.InvalidParentNode;
        var index: usize = 0;
        while (index < old_parent_node.children.items.len) : (index += 1) {
            if (old_parent_node.children.items[index] == child_id) {
                _ = old_parent_node.children.orderedRemove(index);
                self.mark_dirty(old_parent_id);
                return;
            }
        }
    }

    fn get_node(self: *const TaffyTree, id: NodeId) ?*const NodeData {
        if (id >= self.nodes.len) return null;
        const node_data = self.nodes.atConst(id);
        if (!node_data.alive) return null;
        return node_data;
    }

    fn get_node_mut(self: *TaffyTree, id: NodeId) ?*NodeData {
        if (id >= self.nodes.len) return null;
        const node_data = self.nodes.at(id);
        if (!node_data.alive) return null;
        return node_data;
    }
};

test "taffy tree creates children and propagates dirty state" {
    const testing = std.testing;
    var tree = TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{});
    const root = try tree.new_with_children(.{}, &[_]NodeId{child});
    try testing.expectEqual(@as(usize, 1), try tree.child_count(root));
    try testing.expectEqual(child, try tree.child_at(root, 0));
    try tree.set_style(child, .{ .flex_grow = 1 });
    try testing.expect(try tree.is_dirty(root));
}

test "taffy tree reparents children across mutation APIs" {
    const testing = std.testing;
    var tree = TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{});
    const first_parent = try tree.new_leaf(.{});
    const second_parent = try tree.new_leaf(.{});
    try tree.add_child(first_parent, child);
    try testing.expectEqual(@as(usize, 1), try tree.child_count(first_parent));
    try tree.insert_child_at_index(second_parent, 0, child);
    try testing.expectEqual(@as(usize, 0), try tree.child_count(first_parent));
    try testing.expectEqual(second_parent, (try tree.parent(child)).?);
    _ = try tree.remove_child(second_parent, child);
    try testing.expect((try tree.parent(child)) == null);
}

test "taffy set_children reparent refreshes both parents" {
    // A[X 10x10], B[] under a block root. Moving X to B via set_children
    // must invalidate A's cached layout too — otherwise A keeps its stale
    // 10px height after recompute.
    const testing = std.testing;
    var tree = TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const x = try tree.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const a = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{x});
    const b = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{});
    const root = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{ a, b });
    try tree.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 10), (try tree.layout_of(a)).size.height);

    try tree.set_children(b, &[_]NodeId{x});
    try testing.expect(try tree.is_dirty(a));
    try tree.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 0), (try tree.layout_of(a)).size.height);
    try testing.expectEqual(@as(f32, 10), (try tree.layout_of(b)).size.height);
    try testing.expectEqual(b, (try tree.parent(x)).?);
}

test "taffy set_children validates before mutating" {
    // A rejected child ID must leave the tree untouched — no partial
    // detach/attach. A[X]; set_children(B, [X, BAD]) errors and A still
    // owns X, B stays empty.
    const testing = std.testing;
    var tree = TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const x = try tree.new_leaf(.{});
    const a = try tree.new_with_children(.{}, &[_]NodeId{x});
    const b = try tree.new_with_children(.{}, &[_]NodeId{});
    try testing.expectError(error.InvalidChildNode, tree.set_children(b, &[_]NodeId{ x, 9999 }));
    try testing.expectEqual(@as(usize, 1), try tree.child_count(a));
    try testing.expectEqual(@as(usize, 0), try tree.child_count(b));
    try testing.expectEqual(a, (try tree.parent(x)).?);
}
