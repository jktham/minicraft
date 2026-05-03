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

var log_gpa: std.heap.DebugAllocator(.{}) = .init;
const log_allocator = log_gpa.allocator();

const muted_keywords = [_][]const u8{
    "0x1d/03", "player_animation",
    "0x0d/03", "position_update",
    "0x0e/03", "position_look_update",
    "0x0f/03", "look_update",
    "0x47/13", "time_update",
};

pub fn colorLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const message_str = std.fmt.allocPrint(log_allocator, format, args) catch return;
    defer log_allocator.free(message_str);
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
