const std = @import("std");
const player = @import("player.zig");
const inventory = @import("inventory.zig");
const world = @import("world.zig");
const entities = @import("entities.zig");

pub const Game = struct {
    player: player.Player,
    world: world.World,
    entities: entities.Entities,

    pub fn init() Game {
        return .{
            .player = player.Player.init(),
            .world = world.World.init(),
            .entities = entities.Entities.init(),
        };
    }
};
