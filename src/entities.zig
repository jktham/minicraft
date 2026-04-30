const std = @import("std");
const utils = @import("utils.zig");
const inventory = @import("inventory.zig");

pub const DroppedItem = struct {
    eid: i32,
    uuid: u128,
    position: [3]f64,
    slot: inventory.Slot,
};

pub var dropped_items: std.ArrayList(DroppedItem) = .empty;

var prng = std.Random.DefaultPrng.init(0);

pub fn randomEID() i32 {
    return std.Random.int(prng.random(), i32);
}

pub fn randomUUID() u128 {
    return std.Random.int(prng.random(), u128);
}

pub fn spawnItem(gpa: std.mem.Allocator, eid: i32, uuid: u128, position: [3]f64, slot: inventory.Slot) !void {
    std.log.info("Adding item entity with eid {}, uuid 0x{x}, position ({}, {}, {}), id {}, count {}, damage {}, nbt 0x{x}", .{ eid, uuid, position[0], position[1], position[2], slot.id, slot.count, slot.damage, slot.nbt });
    try dropped_items.append(gpa, DroppedItem{
        .eid = eid,
        .uuid = uuid,
        .position = position,
        .slot = slot,
    });
}

pub fn destroyItem(eid: i32) !void {
    std.log.info("Removing item entity with eid {}", .{ eid });
    for (dropped_items.items, 0..) |item, i| {
        if (item.eid == eid) {
            _ = dropped_items.swapRemove(i);
            return;
        }
    }
    return error.ItemNotFound;
}

pub fn getCloseItems(gpa: std.mem.Allocator, position: [3]f64, radius: f64) ![]DroppedItem {
    var close_items = std.ArrayList(DroppedItem).empty;
    for (dropped_items.items) |item| {
        const dist = utils.distance(position, item.position);
        if (dist < radius) {
            _ = try close_items.append(gpa, item);
        }
    }
    return close_items.items;
}
