const std = @import("std");
const print = std.debug.print;

pub fn readVarInt(reader: *std.io.Reader) !u40 {
    const CONTINUE_MASK: u8 = 0b10000000;
    const DATA_MASK: u8 = 0b01111111;

    var value: u40 = 0;
    var position: u6 = 0;
    while (true) {
        const byte: u8 = try reader.takeByte();
        value |= @as(u40, byte & DATA_MASK) << position;

        if ((byte & CONTINUE_MASK) == 0) {
            break;
        }

        position += 7;
        if (position >= 32) {
            return error.InvalidVarInt;
        }
    }
    return value;
}

pub fn writeVarInt(writer: *std.io.Writer, value: u40) !void {
    const CONTINUE_MASK: u8 = 0b10000000;
    const DATA_MASK: u8 = 0b01111111;

    var remaining = value;
    while (remaining != 0) {
        var byte: u8 = @intCast(remaining & DATA_MASK);
        remaining >>= 7;

        if (remaining != 0) {
            byte |= CONTINUE_MASK;
        }

        try writer.writeByte(byte);
    }
}

pub fn computeVarIntByteLength(value: u40) usize {
    var remaining = value;
    var length: usize = 0;
    while (remaining != 0) {
        remaining >>= 7;
        length += 1;
    }
    return length;
}

pub fn readShort(reader: *std.io.Reader) !i16 {
    const bytes = try reader.take(2);
    const short: i16 = @as(i16, bytes[0]) << 8 | @as(i16, bytes[1]);
    return short;
}

pub fn readString(reader: *std.io.Reader) ![]u8 {
    const length = try readVarInt(reader);
    const string = try reader.take(@intCast(length));
    return string;
}

pub fn writeString(writer: *std.io.Writer, string: []const u8) !void {
    try writeVarInt(writer, @intCast(string.len));
    try writer.writeAll(string);
}

pub fn computeStringByteLength(string: []const u8) usize {
    return string.len + computeVarIntByteLength(@intCast(string.len));
}
