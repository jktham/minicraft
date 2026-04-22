const std = @import("std");
const server = @import("server.zig");

pub fn main() !void {
    try server.startServer();
}

pub const std_options: std.Options = .{
    .logFn = colorLogFn,
    // .log_level = std.log.Level.debug,
};

pub fn colorLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = switch (message_level) {
        .err => "\x1b[31m", // red
        .warn => "\x1b[33m", // yellow
        .info => "\x1b[37m", // white
        .debug => "\x1b[34m", // blue
    };
    const reset = "\x1b[0m";

    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(color ++ level_txt ++ prefix2 ++ format ++ reset ++ "\n", args) catch return;
}

test {
    std.testing.refAllDecls(@This());
}
