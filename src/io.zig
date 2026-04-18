const std = @import("std");
const print = std.debug.print;

pub fn readVarInt(reader: *std.io.Reader) !i32 {
    const CONTINUE_MASK: u8 = 0b10000000;
    const DATA_MASK: u8 = 0b01111111;

    var value: u32 = 0;
    var position: u5 = 0;
    while (true) {
        const byte: u8 = try reader.takeByte();
        value |= @as(u32, byte & DATA_MASK) << position;

        if ((byte & CONTINUE_MASK) == 0) {
            break;
        }

        position += 7;
        if (position >= 32) {
            return error.InvalidVarInt;
        }
    }
    return @bitCast(value);
}

pub fn writeVarInt(writer: *std.io.Writer, value: i32) !void {
    const CONTINUE_MASK: u8 = 0b10000000;
    const DATA_MASK: u8 = 0b01111111;

    var remaining: u32 = @bitCast(value);
    while (true) {
        var byte: u8 = @intCast(remaining & DATA_MASK);

        remaining >>= 7;
        if (remaining != 0) {
            byte |= CONTINUE_MASK;
        }
        try writer.writeByte(byte);

        if (remaining == 0) {
            break;
        }
    }
}

pub fn computeVarIntByteLength(value: i32) usize {
    var remaining: u32 = @bitCast(value);
    var length: usize = 0;
    if (remaining == 0) {
        return 1;
    }
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

pub fn writeShort(writer: *std.io.Writer, short: i16) !void {
    const bytes: [2]u8 = .{
        @intCast((short >> 8) & 0xFF),
        @intCast(short & 0xFF),
    };
    try writer.writeAll(&bytes);
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

test "buf reader/writer" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]u8{ 0, 1, 127 };
    for (values) |v| {
        try writer.writeByte(v);
    }
    for (values) |v| {
        const read_value = try reader.takeByte();
        print("Read value: {d}, Expected: {d}\n", .{ read_value, v });
        try std.testing.expect(read_value == v);
    }
}

test "VarInt" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]i32{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i32), -1, std.math.minInt(i32) };
    for (values) |v| {
        try writeVarInt(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000,
        0b00000001,
        0b00000010,
        0b01111111,
        0b10000000, 0b00000001,
        0b11111111, 0b00000001,
        0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00000111,
        0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b00001111,
        0b10000000, 0b10000000, 0b10000000, 0b10000000, 0b00001000,
    };
    for (bytes, 0..) |b, i| {
        print("Encoded byte: {b:0>8}, Expected: {b:0>8}\n", .{ buf[i], b });
        try std.testing.expect(buf[i] == b);
    }

    for (values) |v| {
        const read_value = try readVarInt(&reader);
        print("Read value: {d}, Expected: {d}\n", .{ read_value, v });
        try std.testing.expect(read_value == v);
    }
}

test "VarInt byte length" {
    const values = [_]i32{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i32), -1, std.math.minInt(i32) };
    const expected_lengths = [_]usize{ 1, 1, 1, 1, 2, 2, 5, 5, 5 };
    for (values, 0..) |v, i| {
        const length = computeVarIntByteLength(v);
        print("Value: {d}, Byte length: {d}, Expected: {d}\n", .{ v, length, expected_lengths[i] });
        try std.testing.expect(length == expected_lengths[i]);
    }
}

test "Short" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]i16{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i16), -1, std.math.minInt(i16) };
    for (values) |v| {
        try writeShort(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000,0b00000000,
        0b00000000,0b00000001,
        0b00000000,0b00000010,
        0b00000000,0b01111111,
        0b00000000,0b10000000,
        0b00000000,0b11111111,
        0b01111111,0b11111111,
        0b11111111,0b11111111,
        0b10000000,0b00000000,
    };
    for (bytes, 0..) |b, i| {
        print("Encoded byte: {b:0>8}, Expected: {b:0>8}\n", .{ buf[i], b });
        try std.testing.expect(buf[i] == b);
    }

    for (values) |v| {
        const read_value = try readShort(&reader);
        print("Read value: {d}, Expected: {d}\n", .{ read_value, v });
        try std.testing.expect(read_value == v);
    }
}

test "String" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_][]const u8{ "Test", "a", "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" };
    for (values) |v| {
        try writeString(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000100,
        'T', 'e', 's', 't',
        0b00000001,
        'a',
        0b00000000,

        0b10000000, 0b00000001,
        'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x',
    };
    for (bytes, 0..) |b, i| {
        print("Encoded byte: {b:0>8}, Expected: {b:0>8}\n", .{ buf[i], b });
        try std.testing.expect(buf[i] == b);
    }

    for (values) |v| {
        const read_value = try readString(&reader);
        print("Read value: {s}, Expected: {s}\n", .{ read_value, v });
        try std.testing.expect(std.mem.eql(u8, read_value, v));
    }
}

test "String byte length" {
    const values = [_][]const u8{ "Test", "a", "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" };
    const expected_lengths = [_]usize{ 5, 2, 1, 130 };
    for (values, 0..) |v, i| {
        const length = computeStringByteLength(v);
        print("Value: {s}, Byte length: {d}, Expected: {d}\n", .{ v, length, expected_lengths[i] });
        try std.testing.expect(length == expected_lengths[i]);
    }
}
