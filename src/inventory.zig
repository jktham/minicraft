const std = @import("std");

const palette = @import("palette.zig");
const world = @import("world.zig");

pub const Stack = struct {
    item: palette.Item,
    count: u8,
    nbt: []const u8, // {0} for empty
};

pub const N_SLOTS = 46;
pub const MAX_STACK = 99;

pub const Inventory = struct {
    slots: [N_SLOTS]Stack,
    changed: [N_SLOTS]bool, // slot has changed since last update

    pub fn init() Inventory {
        return .{
            .slots = [_]Stack{.{ .item = palette.Item.empty, .count = 0, .nbt = &[_]u8{0} }} ** N_SLOTS,
            .changed = [_]bool{false} ** N_SLOTS,
        };
    }

    /// try to add the stack to the inventory, error if not enough space in the inventory. if there are already stacks of the same item, they will be filled up first.
    pub fn addStack(self: *Inventory, stack: Stack) !void {
        var count = stack.count;
        for (&self.slots, 0..N_SLOTS) |*slot, i| { // existing stacks
            if (slot.item == stack.item and std.mem.eql(u8, slot.nbt, stack.nbt)) {
                const new_count = slot.count + count;
                if (new_count > MAX_STACK) {
                    slot.count = MAX_STACK;
                    count = new_count - MAX_STACK;
                    self.changed[i] = true;
                    continue;
                }
                slot.count = new_count;
                self.changed[i] = true;
                return;
            }
        }
        for (36..45) |i| { // hotbar first
            if (self.slots[i].count == 0) {
                self.slots[i] = .{
                    .item = stack.item,
                    .count = count,
                    .nbt = stack.nbt,
                };
                self.changed[i] = true;
                return;
            }
        }
        for (0..46) |i| { // main inventory
            if (self.slots[i].count == 0) {
                self.slots[i] = .{
                    .item = stack.item,
                    .count = count,
                    .nbt = stack.nbt,
                };
                self.changed[i] = true;
                return;
            }
        }
        return error.InventoryFull;
    }

    /// try to remove count items from the stack in the given slot, error if not enough items in the stack. if the stack is empty after removing, set the slot to empty.
    pub fn removeCount(self: *Inventory, index: usize, count: u8) !void {
        var slot = &self.slots[index];
        if (count > slot.count) return error.NotEnoughItems;

        if (count < slot.count) {
            slot.count -= count;
        } else {
            slot.count = 0;
            slot.item = palette.Item.empty;
            slot.nbt = &[_]u8{0};
        }
        self.changed[index] = true;
    }
};
