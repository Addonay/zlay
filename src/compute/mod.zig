//! Taffy `compute/mod.rs` module root.
//!
//! Dispatch mirrors Taffy's `TaffyView::compute_child_layout`: hidden mode
//! short-circuits, `display: none` hides, containers dispatch by display, and
//! childless nodes go through the compute-time measure callback. Child
//! requests made by the algorithms go through `compute_cached_layout`.

const std = @import("std");

pub const block = @import("block.zig");
pub const common = @import("common/mod.zig");
pub const flexbox = @import("flexbox.zig");
pub const float = @import("float.zig");
pub const grid = @import("grid/mod.zig");
pub const leaf = @import("leaf.zig");

const geometry = @import("../geometry.zig");
const style = @import("../style/mod.zig");
const available = @import("../style/available_space.zig");
const tree = @import("../tree/taffy_tree.zig");
const tree_layout = @import("../tree/layout.zig");

pub const ComputeError = error{ InvalidParentNode, InvalidChildNode, InvalidInputNode, ChildIndexOutOfBounds, InvalidLayoutMode, OutOfMemory };

/// Check the cache for a matching entry, otherwise compute and store.
/// This is Taffy's `compute_cached_layout`; it does not write node layouts.
pub fn compute_cached_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, input: tree_layout.LayoutInput) ComputeError!tree_layout.LayoutOutput {
    if (tree_ref.cache_get(node_id, &input)) |cached| return cached;
    const output = try compute_child_layout(tree_ref, node_id, input);
    tree_ref.cache_store(node_id, &input, output);
    return output;
}

fn compute_leaf_for(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, input: tree_layout.LayoutInput) ComputeError!tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    if (tree_ref.measure_function) |measure| {
        return measure(if (node_data.has_context) node_data.context else null, input, node_id, &node_data.style);
    }
    return leaf.compute_leaf_layout(input, &node_data.style, null, null);
}

/// Dispatch by `Style.display`, matching `(display, has_children)` in Taffy.
pub fn compute_child_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, input: tree_layout.LayoutInput) ComputeError!tree_layout.LayoutOutput {
    if (input.run_mode == .perform_hidden_layout) return compute_hidden_layout(tree_ref, node_id);

    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    if (node_data.style.display == .none) return compute_hidden_layout(tree_ref, node_id);
    if (node_data.children.items.len == 0) return compute_leaf_for(tree_ref, node_id, input);

    return switch (node_data.style.display) {
        .flex => flexbox.compute_flexbox_layout(tree_ref, node_id, input),
        .grid => grid.compute_grid_layout(tree_ref, node_id, input),
        .block => block.compute_block_layout(tree_ref, node_id, input, null),
        .flow_root => block.compute_block_layout(tree_ref, node_id, input, null),
        .none => compute_hidden_layout(tree_ref, node_id),
    };
}

/// Compute layout for the root node, mirroring Taffy's `compute_root_layout`.
///
/// This is the scratch epoch boundary: a top-level root layout invalidates all
/// of the tree's `scratchAllocator()` temporaries (root passes only re-enter
/// through child computes, so nested calls keep the outer epoch alive). It is
/// called by `TaffyTree.compute_layout`/`compute_layout_with_measure`, but is
/// also part of the public surface, so the reset lives here rather than in the
/// method wrapper to cover direct callers too.
pub fn compute_root_layout(tree_ref: *tree.TaffyTree, root: tree.NodeId, available_space: geometry.Size(available.AvailableSpace)) ComputeError!tree_layout.LayoutOutput {
    const was_in_pass = tree_ref.in_layout_pass;
    if (!was_in_pass) tree_ref.resetScratch();
    tree_ref.in_layout_pass = true;
    defer tree_ref.in_layout_pass = was_in_pass;

    var known_dimensions = geometry.Size(?f32){ .width = null, .height = null };

    const root_data = tree_ref.node(root) orelse return error.InvalidInputNode;
    const root_style = root_data.style;

    // Block roots pre-resolve styled sizes and available-space width into known
    // dimensions before dispatching, exactly like Taffy.
    if (root_style.is_block()) {
        const parent_size = geometry.Size(?f32){ .width = available_space.width.into_option(), .height = available_space.height.into_option() };
        const aspect_ratio = root_style.aspect_ratio;
        const margin = common.resolve_rect_or_zero(root_style.margin, parent_size.width);
        const padding = common.resolve_length_rect(root_style.padding, parent_size.width);
        const border = common.resolve_length_rect(root_style.border, parent_size.width);
        const padding_border_size = geometry.Size(f32){ .width = padding.left + padding.right + border.left + border.right, .height = padding.top + padding.bottom + border.top + border.bottom };
        const box_sizing_adjustment = if (root_style.box_sizing == .content_box) padding_border_size else geometry.Size(f32){ .width = 0, .height = 0 };

        const min_size = addSize(applyAspectRatio(resolveAutoSize(root_style.min_size, parent_size), aspect_ratio), box_sizing_adjustment);
        const max_size = addSize(resolveAutoSize(root_style.max_size, parent_size), box_sizing_adjustment);
        const clamped_style_size = clampSize(addSize(applyAspectRatio(resolveDimensionSize(root_style.size, parent_size), aspect_ratio), box_sizing_adjustment), min_size, max_size);
        const min_max_definite_size = geometry.Size(?f32){
            .width = if (min_size.width) |min| if (max_size.width) |max| if (max <= min) min else null else null else null,
            .height = if (min_size.height) |min| if (max_size.height) |max| if (max <= min) min else null else null else null,
        };
        const available_space_based_size = geometry.Size(?f32){
            .width = if (available_space.width.into_option()) |width| width - (margin.left + margin.right) else null,
            .height = null,
        };
        known_dimensions = orSize(orSize(orSize(known_dimensions, min_max_definite_size), clamped_style_size), available_space_based_size);
        known_dimensions = maybeMaxSize(known_dimensions, padding_border_size);
    }

    const input = tree_layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = known_dimensions.width != null, .height = known_dimensions.height != null },
        .parent_size = .{ .width = available_space.width.into_option(), .height = available_space.height.into_option() },
        .available_space = available_space,
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    const output = try compute_cached_layout(tree_ref, root, input);

    const node_data = tree_ref.node(root) orelse return error.InvalidInputNode;
    const style_ref = node_data.style;
    const available_width = available_space.width.into_option();
    const padding = common.resolve_length_rect(style_ref.padding, available_width);
    const border = common.resolve_length_rect(style_ref.border, available_width);
    const margin = common.resolve_rect_or_zero(style_ref.margin, available_width);
    const scrollbar_size = geometry.Size(f32){
        .width = if (style_ref.overflow.y == .scroll) style_ref.scrollbar_width else 0,
        .height = if (style_ref.overflow.x == .scroll) style_ref.scrollbar_width else 0,
    };
    const location = geometry.Point(f32){
        .x = if (style_ref.direction == .rtl) (if (available_width) |width| width - output.size.width else 0) else 0,
        .y = 0,
    };
    node_data.unrounded_layout = .{
        .order = 0,
        .location = location,
        .size = output.size,
        .scrollable_overflow_rect = output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .padding = padding,
        .border = border,
        .margin = margin,
    };
    node_data.final_layout = node_data.unrounded_layout;
    return output;
}

pub fn compute_hidden_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId) ComputeError!tree_layout.LayoutOutput {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    _ = node_data.cache.clear();
    node_data.unrounded_layout = .with_order(0);
    node_data.final_layout = .with_order(0);
    for (node_data.children.items) |child_id| _ = try compute_hidden_layout(tree_ref, child_id);
    return tree_layout.LayoutOutput.hidden;
}

fn taffyRound(value: f32) f32 {
    // Taffy's `util/sys.rs::round`: ties go toward +infinity, unlike Zig @round.
    return @floor(value + 0.5);
}

pub fn round_layout(tree_ref: *tree.TaffyTree, node_id: tree.NodeId) !void {
    try round_layout_inner(tree_ref, node_id, 0, 0);
}

pub fn round_layout_inner(tree_ref: *tree.TaffyTree, node_id: tree.NodeId, cumulative_x: f32, cumulative_y: f32) !void {
    const node_data = tree_ref.node(node_id) orelse return error.InvalidInputNode;
    const unrounded = node_data.unrounded_layout;
    const absolute_x = cumulative_x + unrounded.location.x;
    const absolute_y = cumulative_y + unrounded.location.y;
    var rounded = unrounded;
    rounded.location.x = taffyRound(unrounded.location.x);
    rounded.location.y = taffyRound(unrounded.location.y);
    rounded.size.width = taffyRound(absolute_x + unrounded.size.width) - taffyRound(absolute_x);
    rounded.size.height = taffyRound(absolute_y + unrounded.size.height) - taffyRound(absolute_y);
    rounded.border.left = taffyRound(absolute_x + unrounded.border.left) - taffyRound(absolute_x);
    rounded.border.right = taffyRound(absolute_x + unrounded.size.width) - taffyRound(absolute_x + unrounded.size.width - unrounded.border.right);
    rounded.border.top = taffyRound(absolute_y + unrounded.border.top) - taffyRound(absolute_y);
    rounded.border.bottom = taffyRound(absolute_y + unrounded.size.height) - taffyRound(absolute_y + unrounded.size.height - unrounded.border.bottom);
    rounded.padding.left = taffyRound(absolute_x + unrounded.padding.left) - taffyRound(absolute_x);
    rounded.padding.right = taffyRound(absolute_x + unrounded.size.width) - taffyRound(absolute_x + unrounded.size.width - unrounded.padding.right);
    rounded.padding.top = taffyRound(absolute_y + unrounded.padding.top) - taffyRound(absolute_y);
    rounded.padding.bottom = taffyRound(absolute_y + unrounded.size.height) - taffyRound(absolute_y + unrounded.size.height - unrounded.padding.bottom);
    rounded.scrollable_overflow_rect.left = taffyRound(absolute_x + unrounded.scrollable_overflow_rect.left) - taffyRound(absolute_x);
    rounded.scrollable_overflow_rect.right = taffyRound(absolute_x + unrounded.scrollable_overflow_rect.right) - taffyRound(absolute_x);
    rounded.scrollable_overflow_rect.top = taffyRound(absolute_y + unrounded.scrollable_overflow_rect.top) - taffyRound(absolute_y);
    rounded.scrollable_overflow_rect.bottom = taffyRound(absolute_y + unrounded.scrollable_overflow_rect.bottom) - taffyRound(absolute_y);
    rounded.scrollbar_size.width = taffyRound(unrounded.scrollbar_size.width);
    rounded.scrollbar_size.height = taffyRound(unrounded.scrollbar_size.height);
    node_data.final_layout = rounded;
    for (node_data.children.items) |child_id| try round_layout_inner(tree_ref, child_id, absolute_x, absolute_y);
}

fn resolveDimensionSize(value: geometry.Size(style.dimension.Dimension), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width.resolve(parent.width), .height = value.height.resolve(parent.height) };
}

fn resolveAutoSize(value: geometry.Size(style.dimension.LengthPercentageAuto), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width.resolve_to_option(parent.width), .height = value.height.resolve_to_option(parent.height) };
}

fn applyAspectRatio(value: geometry.Size(?f32), ratio: ?f32) geometry.Size(?f32) {
    if (ratio) |r| {
        if (value.width) |width| {
            if (value.height == null) return .{ .width = width, .height = width / r };
        }
        if (value.height) |height| {
            if (value.width == null) return .{ .width = height * r, .height = height };
        }
    }
    return value;
}

fn addSize(value: geometry.Size(?f32), add: geometry.Size(f32)) geometry.Size(?f32) {
    return .{ .width = if (value.width) |v| v + add.width else null, .height = if (value.height) |v| v + add.height else null };
}

fn orSize(a: geometry.Size(?f32), b: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = a.width orelse b.width, .height = a.height orelse b.height };
}

fn clampSize(value: geometry.Size(?f32), min: geometry.Size(?f32), max: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(@min(v, max.width orelse std.math.inf(f32)), min.width orelse -std.math.inf(f32)) else null,
        .height = if (value.height) |v| @max(@min(v, max.height orelse std.math.inf(f32)), min.height orelse -std.math.inf(f32)) else null,
    };
}

fn maybeMaxSize(value: geometry.Size(?f32), floor: geometry.Size(f32)) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(v, floor.width) else null,
        .height = if (value.height) |v| @max(v, floor.height) else null,
    };
}

test {
    _ = geometry.Size(f32);
    _ = style.Style{};
}

test "root dispatcher executes the first flex layout path" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_a = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const child_b = try tree_ref.new_leaf(.{ .size = .{ .width = .length(30), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{ child_a, child_b });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(child_a)).size.width);
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(child_b)).location.x);
}

test "root dispatcher executes the first grid layout path" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const columns = [_]style.grid.GridTemplateComponent{
        .{ .single = style.grid.TrackSizingFunction.from_length(40) },
        .{ .single = style.grid.TrackSizingFunction.from_fr(1) },
    };
    const rows = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_length(20) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(child)).size.width);
}

test "display none recursively hides descendants" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(20) } });
    const child = try tree_ref.new_with_children(.{}, &[_]tree.NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{ .display = .none, .size = .{ .width = .length(50), .height = .length(50) } }, &[_]tree.NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(root)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(grandchild)).size.width);
}

test "LayoutInput.HIDDEN produces hidden layout for a visible tree" {
    const testing = @import("std").testing;
    var tree_ref = tree.TaffyTree.init(testing.allocator);
    defer tree_ref.deinit();
    const leaf_node = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(11) } });
    const hidden = try compute_child_layout(&tree_ref, leaf_node, tree_layout.LayoutInput.HIDDEN);
    try testing.expectEqual(@as(f32, 0), hidden.size.width);
    try testing.expectEqual(@as(f32, 0), hidden.size.height);
}

test {
    _ = @import("block.zig");
    _ = @import("common/mod.zig");
    _ = @import("flexbox.zig");
    _ = @import("float.zig");
    _ = @import("grid/mod.zig");
    _ = @import("leaf.zig");
}
