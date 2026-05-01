const std = @import("std");
const inventory = @import("inventory.zig");

pub var ping: ?i32 = null;
pub var eid: ?i32 = null;
pub var name: ?[]const u8 = null;
pub var uuid: ?u128 = null;
pub var position: ?[3]f64 = null;
pub var look: ?[2]f32 = null;
pub var gamemode: ?u8 = null; // 0 = survival, 1 = creative
pub var xp: ?i32 = null;
pub var inv: ?inventory.Inventory = null;
