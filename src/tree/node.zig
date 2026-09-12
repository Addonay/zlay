//! Direct port of Taffy's `tree/node.rs` identity type.

/// Stable index handle. Taffy uses a generational slot key; generation is a
/// Port-status item for the Zig allocator-backed tree's generation semantics.
pub const NodeId = u32;

pub fn node_id(value: u32) NodeId {
    return value;
}
pub fn node_id_from(value: anytype) NodeId {
    return @intCast(value);
}
