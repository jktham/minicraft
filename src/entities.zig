const std = @import("std");

const inventory = @import("inventory.zig");
const utils = @import("utils.zig");

pub const ItemEntity = struct {
    eid: i32,
    uuid: u128,
    position: [3]f64,
    stack: inventory.Stack,
};

var prng = std.Random.DefaultPrng.init(0);

pub fn randomEID() i32 {
    return std.Random.int(prng.random(), i32);
}

pub fn randomUUID() u128 {
    return std.Random.int(prng.random(), u128);
}

pub const Entities = struct {
    items: std.ArrayList(ItemEntity),

    pub fn init() Entities {
        return .{
            .items = .empty,
        };
    }

    pub fn spawnItem(self: *Entities, gpa: std.mem.Allocator, eid: i32, uuid: u128, position: [3]f64, stack: inventory.Stack) !void {
        std.log.info("Spawning item entity with eid {}, uuid 0x{x}, position ({}, {}, {}), stack {}", .{ eid, uuid, position[0], position[1], position[2], stack });
        try self.items.append(gpa, ItemEntity{
            .eid = eid,
            .uuid = uuid,
            .position = position,
            .stack = stack,
        });
    }

    pub fn destroyItem(self: *Entities, eid: i32) !void {
        std.log.info("Destroying item entity with eid {}", .{eid});
        for (self.items.items, 0..) |item, i| {
            if (item.eid == eid) {
                _ = self.items.swapRemove(i);
                return;
            }
        }
        return error.ItemNotFound;
    }

    pub fn getCloseItems(self: *Entities, gpa: std.mem.Allocator, position: [3]f64, radius: f64) ![]ItemEntity {
        var close_items = std.ArrayList(ItemEntity).empty;
        for (self.items.items) |item| {
            const dist = utils.distance(position, item.position);
            if (dist < radius) {
                _ = try close_items.append(gpa, item);
            }
        }
        return close_items.items;
    }
};
