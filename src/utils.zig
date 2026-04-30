const std = @import("std");

pub fn distance(a: [3]f64, b: [3]f64) f64 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return std.math.sqrt(dx * dx + dy * dy + dz * dz);
}

/// get current time in milliseconds since epoch
pub fn getTime(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}
