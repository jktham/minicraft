const std = @import("std");

const world = @import("world.zig");

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

pub fn itemToBlock(item: Item) world.Block {
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

pub const Stack = struct {
    id: Item, // https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening
    count: u8,
    damage: i16,
    nbt: []const u8, // {0} for empty
};

pub const N_SLOTS = 46;
pub const MAX_STACK = 64;

pub const Inventory = struct {
    slots: [N_SLOTS]Stack,

    pub fn init() Inventory {
        return .{
            .slots = [_]Stack{.{ .id = .Empty, .count = 0, .damage = 0, .nbt = &[_]u8{0} }} ** N_SLOTS,
        };
    }

    pub fn setSlot(self: *Inventory, index: usize, stack: Stack) !void {
        if (index >= N_SLOTS) return error.InvalidSlot;
        self.slots[index] = stack;
    }

    pub fn addStack(self: *Inventory, stack: Stack) !void {
        var count = stack.count;
        for (&self.slots) |*slot| {
            if (slot.id == stack.id and slot.damage == stack.damage and std.mem.eql(u8, slot.nbt, stack.nbt)) {
                const new_count = slot.count + count;
                if (new_count > MAX_STACK) {
                    slot.count = MAX_STACK;
                    count = new_count - MAX_STACK;
                    continue;
                }
                slot.count = new_count;
                return;
            }
        }
        for (36..45) |i| { // hotbar first
            if (self.slots[i].id == .Empty) {
                self.slots[i] = stack;
                return;
            }
        }
        for (&self.slots) |*slot| {
            if (slot.id == .Empty) {
                slot.* = stack;
                return;
            }
        }
        return error.InventoryFull;
    }

    pub fn removeCount(self: *Inventory, index: usize, count: u8) !void {
        var slot = &self.slots[index];
        if (count > slot.count) return error.NotEnoughItems;

        if (count < slot.count) {
            slot.count -= count;
        } else {
            slot.count = 0;
            slot.id = .Empty;
            slot.damage = 0;
            slot.nbt = &[_]u8{0};
        }
    }
};
