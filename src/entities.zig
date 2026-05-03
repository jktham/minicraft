const std = @import("std");

const inventory = @import("inventory.zig");
const utils = @import("utils.zig");

/// f64 position, not to be confused with data.Position
pub const fPos = struct {
    x: f64,
    y: f64,
    z: f64,
};

pub const ItemEntity = struct {
    eid: i32,
    uuid: u128,
    position: fPos,
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

    pub fn spawnItem(self: *Entities, gpa: std.mem.Allocator, item: ItemEntity) !void {
        std.log.info("Spawning item entity with eid 0x{x}, uuid 0x{x}, position ({}, {}, {}), stack {}", .{ item.eid, item.uuid, item.position.x, item.position.y, item.position.z, item.stack });
        try self.items.append(gpa, item);
    }

    pub fn destroyItem(self: *Entities, eid: i32) !void {
        std.log.info("Destroying item entity with eid 0x{x}", .{eid});
        for (self.items.items, 0..) |item, i| {
            if (item.eid == eid) {
                _ = self.items.swapRemove(i);
                return;
            }
        }
        return error.ItemNotFound;
    }

    pub fn getCloseItems(self: *Entities, gpa: std.mem.Allocator, position: fPos, radius: f64) ![]ItemEntity {
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
