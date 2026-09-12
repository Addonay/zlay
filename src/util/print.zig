//! Direct-port home for Taffy's `util/print.rs`.

const tree = @import("../tree/taffy_tree.zig");
const std = @import("std");

pub fn format_node(writer: anytype, node_id: tree.NodeId, layout: anytype) !void {
    try writer.print("{d}: x={d} y={d} w={d} h={d}", .{ node_id, layout.location.x, layout.location.y, layout.size.width, layout.size.height });
}

pub fn write_tree(writer: anytype, tree_ref: *const tree.TaffyTree, root: tree.NodeId) !void {
    try writer.writeAll("TREE\n");
    try write_node(writer, tree_ref, root, "", false);
}

pub fn write_node(writer: anytype, tree_ref: *const tree.TaffyTree, node_id: tree.NodeId, prefix: []const u8, has_sibling: bool) !void {
    const node_layout = try tree_ref.layout_of(node_id);
    const label = if (has_sibling) "├── " else "└── ";
    try writer.print("{s}{s}{d}: x={d} y={d} w={d} h={d}\n", .{ prefix, label, node_id, node_layout.location.x, node_layout.location.y, node_layout.size.width, node_layout.size.height });
    const child_ids = try tree_ref.children(node_id);
    for (child_ids, 0..) |child_id, index| {
        try write_node(writer, tree_ref, child_id, prefix, index + 1 < child_ids.len);
    }
}

pub fn print_tree(tree_ref: *const tree.TaffyTree, root: tree.NodeId) void {
    std.debug.print("TREE\n", .{});
    print_node_debug(tree_ref, root, "", false);
}

fn print_node_debug(tree_ref: *const tree.TaffyTree, node_id: tree.NodeId, prefix: []const u8, has_sibling: bool) void {
    const node_layout = tree_ref.layout_of(node_id) catch return;
    std.debug.print("{s}{s}{d}: x={d} y={d} w={d} h={d}\n", .{ prefix, if (has_sibling) "├── " else "└── ", node_id, node_layout.location.x, node_layout.location.y, node_layout.size.width, node_layout.size.height });
    const child_ids = tree_ref.children(node_id) catch return;
    for (child_ids, 0..) |child_id, index| print_node_debug(tree_ref, child_id, prefix, index + 1 < child_ids.len);
}
