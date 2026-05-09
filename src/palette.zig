const std = @import("std");

const inventory = @import("inventory.zig");
const world = @import("world.zig");

pub fn block(id: u9, meta: u4) u13 {
    return (@as(u13, id) << 4) | meta;
}

/// blockid(9) | meta(4)
pub const Block = enum(u13) {
    air = block(0, 0),
    stone = block(1, 0),
    granite = block(1, 1),
    granite_polished = block(1, 2),
    diorite = block(1, 3),
    diorite_polished = block(1, 4),
    andesite = block(1, 5),
    andesite_polished = block(1, 6),
    grass = block(2, 0),
    dirt = block(3, 0),
    dirt_coarse = block(3, 1),
    cobblestone = block(4, 0),
    planks = block(5, 0),
    sapling_oak = block(6, 0),
    sapling_spruce = block(6, 1),
    sapling_birch = block(6, 2),
    sapling_jungle = block(6, 3),
    sapling_acacia = block(6, 4),
    sapling_dark_oak = block(6, 5),
    bedrock = block(7, 0),
    water = block(8, 0),
    water_stationary = block(9, 0),
    lava = block(10, 0),
    lava_stationary = block(11, 0),
    sand = block(12, 0),
    gravel = block(13, 0),
    gold_ore = block(14, 0),
    iron_ore = block(15, 0),
    coal_ore = block(16, 0),
    wood = block(17, 0),
    leaves = block(18, 0),

    err = block(213, 0),

    pub fn id(self: Block) u9 {
        return @truncate((@intFromEnum(self) & 0x1FF0) >> 4);
    }

    pub fn meta(self: Block) u4 {
        return @truncate(@intFromEnum(self) & 0xF);
    }

    pub fn toItem(self: Block) Item {
        const i = std.enums.fromInt(Item, item(self.id(), self.meta()));
        if (i == null) {
            return Item.err; // invalid value
        }
        return i.?;
    }

    /// item obtained by mining the block
    pub fn mine(self: Block) Item {
        return switch (self) {
            .stone => .cobblestone,
            .grass => .dirt,
            else => toItem(self),
        };
    }

    /// whether the block can be replaced by another block when placing
    pub fn replaceable(self: Block) bool {
        return switch (self) {
            .air, .water, .water_stationary, .lava, .lava_stationary => true,
            else => false,
        };
    }

    /// whether the block can be collided with, and mined
    pub fn solid(self: Block) bool {
        return switch (self) {
            .air, .water, .water_stationary, .lava, .lava_stationary => false,
            else => true,
        };
    }
};

test "testBlock" {
    try std.testing.expect(Block.air.id() == 0);
    try std.testing.expect(Block.air.meta() == 0);
    try std.testing.expect(Block.dirt_coarse.id() == 3);
    try std.testing.expect(Block.dirt_coarse.meta() == 1);
    try std.testing.expect(block(3, 1) == @intFromEnum(Block.dirt_coarse));
}

pub fn item(id: u16, meta: u16) u32 {
    return @as(u32, id) << 16 | meta;
}

/// itemid(16) | meta(16)
pub const Item = enum(u32) {
    empty = item(0, 0), // treated as -1
    stone = item(1, 0),
    granite = item(1, 1),
    granite_polished = item(1, 2),
    diorite = item(1, 3),
    diorite_polished = item(1, 4),
    andesite = item(1, 5),
    andesite_polished = item(1, 6),
    grass = item(2, 0),
    dirt = item(3, 0),
    dirt_coarse = item(3, 1),
    cobblestone = item(4, 0),
    planks = item(5, 0),
    sapling_oak = item(6, 0),
    sapling_spruce = item(6, 1),
    sapling_birch = item(6, 2),
    sapling_jungle = item(6, 3),
    sapling_acacia = item(6, 4),
    sapling_dark_oak = item(6, 5),
    bedrock = item(7, 0),
    water = item(8, 0),
    water_stationary = item(9, 0),
    lava = item(10, 0),
    lava_stationary = item(11, 0),
    sand = item(12, 0),
    gravel = item(13, 0),
    gold_ore = item(14, 0),
    iron_ore = item(15, 0),
    coal_ore = item(16, 0),
    wood = item(17, 0),
    leaves = item(18, 0),

    iron_shovel = item(256, 0),
    iron_pickaxe = item(257, 0),
    iron_axe = item(258, 0),

    err = item(213, 0),

    pub fn id(self: Item) u16 {
        return @truncate((@intFromEnum(self) & 0xFFFF0000) >> 16);
    }

    pub fn meta(self: Item) u16 {
        return @truncate(@intFromEnum(self) & 0xFFFF);
    }

    pub fn toBlock(self: Item) Block {
        const b = std.enums.fromInt(Block, block(@truncate(self.id()), @truncate(self.meta())));
        if (b == null) {
            return Block.err; // invalid value
        }
        return b.?;
    }

    /// block created by placing the item
    pub fn place(self: Item) Block {
        return switch (self) {
            else => toBlock(self),
        };
    }

    /// whether the item can be placed as a block
    pub fn placeable(self: Item) bool {
        return switch (self) {
            .iron_shovel, .iron_pickaxe, .iron_axe => false,
            else => true,
        };
    }
};

test "testItem" {
    try std.testing.expect(Item.iron_shovel.id() == 256);
    try std.testing.expect(Item.iron_shovel.meta() == 0);
    try std.testing.expect(Item.dirt_coarse.id() == 3);
    try std.testing.expect(Item.dirt_coarse.meta() == 1);
    try std.testing.expect(item(3, 1) == @intFromEnum(Item.dirt_coarse));
}

test "testConversion" {
    try std.testing.expect(Block.stone.toItem() == Item.stone);
    try std.testing.expect(Item.grass.toBlock() == Block.grass);
    try std.testing.expect(Block.grass.mine() == Item.dirt);
}
