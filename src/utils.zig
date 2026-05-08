const std = @import("std");

const entities = @import("entities.zig");

pub fn distance(a: entities.fPos, b: entities.fPos) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return std.math.sqrt(dx * dx + dy * dy + dz * dz);
}

pub fn sameBlockCoords(a: entities.fPos, b: entities.fPos) bool {
    return @floor(a.x) == @floor(b.x) and @floor(a.y) == @floor(b.y) and @floor(a.z) == @floor(b.z);
}

/// get current time in milliseconds since epoch
pub fn getTime(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// replace non-printable characters in a string for logging purposes
pub fn sanitizeString(gpa: std.mem.Allocator, str: []const u8) ![]const u8 {
    var sanitized = try gpa.dupe(u8, str);
    for (sanitized, 0..sanitized.len) |c, i| {
        if (c >= 32 and c < 127) {
            sanitized[i] = c;
        } else {
            sanitized[i] = '?';
        }
    }
    return sanitized;
}
