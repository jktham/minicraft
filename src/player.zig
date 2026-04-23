const std = @import("std");

pub var position: [3]f64 = undefined;

pub fn updatePosition(x: f64, y: f64, z: f64) void {
    position[0] = x;
    position[1] = y;
    position[2] = z;
}
