// https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening

/// blockid(9) + meta(4), max length 256
pub const palette = [_]u13{
    0b000000000_0000, // air
    0b000000001_0000, // stone
    0b000000010_0000, // grass
    0b000000011_0000, // dirt
    0b000000100_0000, // cobblestone
    0b000000101_0000, // planks
    0b000000110_0000, // sapling
    0b000000111_0000, // bedrock
};

/// index into palette
pub const Block = enum(u8) {
    Air = 0,
    Stone = 1,
    Grass = 2,
    Dirt = 3,
    Cobblestone = 4,
    Planks = 5,
    Sapling = 6,
    Bedrock = 7,

    /// convert block id to item id via mining, returns .Empty if the block cannot be converted to an item (e.g. air)
    pub fn toItem(block: Block) Item {
        return switch (block) {
            .Stone => .Cobblestone,
            .Grass => .Dirt,
            .Dirt => .Dirt,
            .Cobblestone => .Cobblestone,
            .Planks => .Planks,
            .Sapling => .Sapling,
            .Bedrock => .Bedrock,
            else => .Empty,
        };
    }
};

pub const Item = enum(i16) {
    Empty = -1,
    Stone = 1,
    Grass = 2,
    Dirt = 3,
    Cobblestone = 4,
    Planks = 5,
    Sapling = 6,
    Bedrock = 7,
    IronShovel = 256,
    IronPickaxe = 257,
    IronAxe = 258,

    /// convert item id to block id via placing, returns .Air if the item cannot be converted to a block (e.g. pickaxe)
    pub fn toBlock(item: Item) Block {
        return switch (item) {
            .Stone => .Stone,
            .Grass => .Grass,
            .Dirt => .Dirt,
            .Cobblestone => .Cobblestone,
            .Planks => .Planks,
            .Sapling => .Sapling,
            .Bedrock => .Bedrock,
            else => .Air,
        };
    }
};
