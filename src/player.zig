const std = @import("std");

pub var ping: i32 = undefined;
pub var name: []const u8 = undefined;
pub var uuid: u128 = undefined;
pub var position: [3]f64 = undefined;
pub var gamemode: u8 = 0; // 0 = survival, 1 = creative
