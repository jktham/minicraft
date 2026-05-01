const std = @import("std");
const inventory = @import("inventory.zig");

pub const Player = struct {
    eid: i32,
    uuid: u128,
    name: []const u8,
    ping: i32,
    position: [3]f64,
    look: [2]f32,
    gamemode: u8,
    xp: i32,
    inventory: inventory.Inventory,

    pub fn init() Player {
        return .{
            .eid = 0,
            .uuid = 0,
            .name = "",
            .ping = 0,
            .position = [_]f64{0, 0, 0},
            .look = [_]f32{0, 0},
            .gamemode = 0,
            .xp = 0,
            .inventory = inventory.Inventory.init(),
        };
    }
};
