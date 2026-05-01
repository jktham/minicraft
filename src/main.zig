const std = @import("std");

const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    try server.startServer(io, gpa);
}

pub const std_options: std.Options = .{
    .logFn = colorLogFn,
    // .log_level = std.log.Level.debug,
};

pub const muted_keywords = [_][]const u8{
    "length 2, id 0x1d, data 0x00",
    "player_animation",
};

pub fn colorLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    const message_str = std.fmt.allocPrint(allocator, format, args) catch return;
    defer allocator.free(message_str);
    for (muted_keywords) |keyword| {
        if (std.mem.containsAtLeast(u8, message_str, 1, keyword)) {
            return;
        }
    }

    const color = switch (level) {
        .err => "\x1b[31m", // red
        .warn => "\x1b[33m", // yellow
        .info => "\x1b[37m", // white
        .debug => "\x1b[34m", // blue
    };
    const reset = "\x1b[0m";

    const level_txt = comptime level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    nosuspend stderr.writer.print(color ++ level_txt ++ prefix2 ++ format ++ reset ++ "\n", args) catch return;
}

test {
    std.testing.refAllDecls(@This());
}
