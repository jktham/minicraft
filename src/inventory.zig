const std = @import("std");
const world = @import("world.zig");

pub fn blockToItem(block: world.Block) Item {
    return switch (block) {
        .Stone => .Stone,
        .Grass => .Grass,
        .Dirt => .Dirt,
        .Cobblestone => .Cobblestone,
        .Planks => .Planks,
        .Sapling => .Sapling,
        .Bedrock => .Bedrock,
        else => .Empty,
    };
}

pub const Item = enum(i16) {
    Empty = -1,
    Stone = 1,
    Grass = 2,
    Dirt = 3,
    Cobblestone = 4,
    Planks = 5,
    Sapling = 6,
    Bedrock = 7,
    IronPickaxe = 257,
};

pub const Slot = struct {
    id: Item, // https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening
    count: u8,
    damage: i16,
    nbt: []const u8, // {0} for empty
};
