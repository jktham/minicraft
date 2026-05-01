const std = @import("std");

const entities = @import("entities.zig");
const inventory = @import("inventory.zig");
const player = @import("player.zig");
const world = @import("world.zig");

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
