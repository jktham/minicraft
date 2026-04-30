const std = @import("std");
const utils = @import("utils.zig");

pub const Item = struct {
    eid: i32,
    uuid: u128,
    position: [3]f64,
    id: i16, // https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening
    count: u8,
    damage: i16,
    nbt: []const u8, // {0} for empty
};

pub var items: std.ArrayList(Item) = .empty;

var prng = std.Random.DefaultPrng.init(0);

pub fn randomEID() i32 {
    return std.Random.int(prng.random(), i32);
}

pub fn randomUUID() u128 {
    return std.Random.int(prng.random(), u128);
}

pub fn addItem(eid: i32, uuid: u128, position: [3]f64, id: i16, count: u8, damage: i16, nbt: []const u8) !void {
    std.log.info("Adding item entity with eid {}, uuid 0x{x}, position ({}, {}, {}), id {}, count {}, damage {}, nbt 0x{x}", .{ eid, uuid, position[0], position[1], position[2], id, count, damage, nbt });
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    try items.append(allocator, Item{
        .eid = eid,
        .uuid = uuid,
        .position = position,
        .id = id,
        .count = count,
        .damage = damage,
        .nbt = nbt,
    });
}

pub fn removeItem(eid: i32) !void {
    std.log.info("Removing item entity with eid {}", .{ eid });
    for (items.items, 0..) |item, i| {
        if (item.eid == eid) {
            _ = items.swapRemove(i);
            return;
        }
    }
    return error.ItemNotFound;
}

pub fn getCloseItems(position: [3]f64, radius: f64) ![]Item {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    var close_items = std.ArrayList(Item).empty;
    for (items.items) |item| {
        const dist = utils.distance(position, item.position);
        if (dist < radius) {
            _ = try close_items.append(allocator, item);
        }
    }
    return close_items.items;
}
