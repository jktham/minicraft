const std = @import("std");
const print = std.debug.print;

test "buf reader/writer" {
    print("--- Test: buf reader/writer ---\n", .{});
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

pub fn readByte(reader: *std.io.Reader) !u8 {
    return reader.takeByte();
}

pub fn writeByte(writer: *std.io.Writer, value: u8) !void {
    try writer.writeByte(value);
}

pub fn readBool(reader: *std.io.Reader) !bool {
    const byte = try reader.takeByte();
    if (byte == 0) {
        return false;
    } else if (byte == 1) {
        return true;
    } else {
        return error.InvalidBoolean;
    }
}

pub fn writeBool(writer: *std.io.Writer, value: bool) !void {
    try writer.writeByte(if (value) 1 else 0);
}

test "Bool" {
    print("--- Test: Bool ---\n", .{});
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]bool{ false, true };
    for (values) |v| {
        try writeBool(&writer, v);
    }
    try writer.flush();

    for (values) |v| {
        const read_value = try readBool(&reader);
        print("Read value: {}, Expected: {}\n", .{ read_value, v });
        try std.testing.expect(read_value == v);
    }
}

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

test "VarInt" {
    print("--- Test: VarInt ---\n", .{});
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

test "VarInt byte length" {
    print("--- Test: VarInt byte length ---\n", .{});
    const values = [_]i32{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i32), -1, std.math.minInt(i32) };
    const expected_lengths = [_]usize{ 1, 1, 1, 1, 2, 2, 5, 5, 5 };
    for (values, 0..) |v, i| {
        const length = computeVarIntByteLength(v);
        print("Value: {d}, Byte length: {d}, Expected: {d}\n", .{ v, length, expected_lengths[i] });
        try std.testing.expect(length == expected_lengths[i]);
    }
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

test "Short" {
    print("--- Test: Short ---\n", .{});
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]i16{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i16), -1, std.math.minInt(i16) };
    for (values) |v| {
        try writeShort(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000, 0b00000000,
        0b00000000, 0b00000001,
        0b00000000, 0b00000010,
        0b00000000, 0b01111111,
        0b00000000, 0b10000000,
        0b00000000, 0b11111111,
        0b01111111, 0b11111111,
        0b11111111, 0b11111111,
        0b10000000, 0b00000000,
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

pub fn readInt(reader: *std.io.Reader) !i32 {
    const bytes = try reader.take(4);
    const int: i32 = @as(i32, bytes[0]) << 24 | @as(i32, bytes[1]) << 16 | @as(i32, bytes[2]) << 8 | @as(i32, bytes[3]);
    return int;
}

pub fn writeInt(writer: *std.io.Writer, int: i32) !void {
    const bytes: [4]u8 = .{
        @intCast((int >> 24) & 0xFF),
        @intCast((int >> 16) & 0xFF),
        @intCast((int >> 8) & 0xFF),
        @intCast(int & 0xFF),
    };
    try writer.writeAll(&bytes);
}

pub fn readLong(reader: *std.io.Reader) !i64 {
    const bytes = try reader.take(8);
    const long: i64 = @as(i64, bytes[0]) << 56 | @as(i64, bytes[1]) << 48 | @as(i64, bytes[2]) << 40 | @as(i64, bytes[3]) << 32 | @as(i64, bytes[4]) << 24 | @as(i64, bytes[5]) << 16 | @as(i64, bytes[6]) << 8 | @as(i64, bytes[7]);
    return long;
}

pub fn writeLong(writer: *std.io.Writer, long: i64) !void {
    const bytes: [8]u8 = .{
        @intCast((long >> 56) & 0xFF),
        @intCast((long >> 48) & 0xFF),
        @intCast((long >> 40) & 0xFF),
        @intCast((long >> 32) & 0xFF),
        @intCast((long >> 24) & 0xFF),
        @intCast((long >> 16) & 0xFF),
        @intCast((long >> 8) & 0xFF),
        @intCast(long & 0xFF),
    };
    try writer.writeAll(&bytes);
}

test "Long" {
    print("--- Test: Long ---\n", .{});
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]i64{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i64), -1, std.math.minInt(i64) };
    for (values) |v| {
        try writeLong(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000010,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01111111,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b10000000,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b11111111,
        0b01111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111,
        0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111,
        0b10000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
    };
    for (bytes, 0..) |b, i| {
        print("Encoded byte: {b:0>8}, Expected: {b:0>8}\n", .{ buf[i], b });
        try std.testing.expect(buf[i] == b);
    }

    for (values) |v| {
        const read_value = try readLong(&reader);
        print("Read value: {d}, Expected: {d}\n", .{ read_value, v });
        try std.testing.expect(read_value == v);
    }
}

pub fn readFloat(reader: *std.io.Reader) !f32 {
    const bytes = try reader.take(4);
    const int: u32 = @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | @as(u32, bytes[3]);
    return @bitCast(int);
}

pub fn writeFloat(writer: *std.io.Writer, value: f32) !void {
    const int: u32 = @bitCast(value);
    const bytes: [4]u8 = .{
        @intCast((int >> 24) & 0xFF),
        @intCast((int >> 16) & 0xFF),
        @intCast((int >> 8) & 0xFF),
        @intCast(int & 0xFF),
    };
    try writer.writeAll(&bytes);
}

pub fn readDouble(reader: *std.io.Reader) !f64 {
    const bytes = try reader.take(8);
    const long: u64 = @as(u64, bytes[0]) << 56 | @as(u64, bytes[1]) << 48 | @as(u64, bytes[2]) << 40 | @as(u64, bytes[3]) << 32 | @as(u64, bytes[4]) << 24 | @as(u64, bytes[5]) << 16 | @as(u64, bytes[6]) << 8 | @as(u64, bytes[7]);
    return @bitCast(long);
}

pub fn writeDouble(writer: *std.io.Writer, value: f64) !void {
    const long: u64 = @bitCast(value);
    const bytes: [8]u8 = .{
        @intCast((long >> 56) & 0xFF),
        @intCast((long >> 48) & 0xFF),
        @intCast((long >> 40) & 0xFF),
        @intCast((long >> 32) & 0xFF),
        @intCast((long >> 24) & 0xFF),
        @intCast((long >> 16) & 0xFF),
        @intCast((long >> 8) & 0xFF),
        @intCast(long & 0xFF),
    };
    try writer.writeAll(&bytes);
}

pub fn readUUID(reader: *std.io.Reader) !u128 {
    const bytes = try reader.take(16);
    const uuid: u128 = @as(u128, bytes[0]) << 120 | @as(u128, bytes[1]) << 112 | @as(u128, bytes[2]) << 104 | @as(u128, bytes[3]) << 96 | @as(u128, bytes[4]) << 88 | @as(u128, bytes[5]) << 80 | @as(u128, bytes[6]) << 72 | @as(u128, bytes[7]) << 64 | @as(u128, bytes[8]) << 56 | @as(u128, bytes[9]) << 48 | @as(u128, bytes[10]) << 40 | @as(u128, bytes[11]) << 32 | @as(u128, bytes[12]) << 24 | @as(u128, bytes[13]) << 16 | @as(u128, bytes[14]) << 8 | @as(u128, bytes[15]);
    return uuid;
}

pub fn writeUUID(writer: *std.io.Writer, uuid: u128) !void {
    const bytes: [16]u8 = .{
        @intCast((uuid >> 120) & 0xFF),
        @intCast((uuid >> 112) & 0xFF),
        @intCast((uuid >> 104) & 0xFF),
        @intCast((uuid >> 96) & 0xFF),
        @intCast((uuid >> 88) & 0xFF),
        @intCast((uuid >> 80) & 0xFF),
        @intCast((uuid >> 72) & 0xFF),
        @intCast((uuid >> 64) & 0xFF),
        @intCast((uuid >> 56) & 0xFF),
        @intCast((uuid >> 48) & 0xFF),
        @intCast((uuid >> 40) & 0xFF),
        @intCast((uuid >> 32) & 0xFF),
        @intCast((uuid >> 24) & 0xFF),
        @intCast((uuid >> 16) & 0xFF),
        @intCast((uuid >> 8) & 0xFF),
        @intCast(uuid & 0xFF),
    };
    try writer.writeAll(&bytes);
}

test "UUID" {
    print("--- Test: UUID ---\n", .{});
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]u128{ 0, 1, 2, 127, 128, 255, std.math.maxInt(u128), std.math.minInt(u128) };
    for (values) |v| {
        try writeUUID(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000001,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000010,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b01111111,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b10000000,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b11111111,
        0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111,
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
    };
    for (bytes, 0..) |b, i| {
        print("Encoded byte: {b:0>8}, Expected: {b:0>8}\n", .{ buf[i], b });
        try std.testing.expect(buf[i] == b);
    }

    for (values) |v| {
        const read_value = try readUUID(&reader);
        print("Read value: {d}, Expected: {d}\n", .{ read_value, v });
        try std.testing.expect(read_value == v);
    }
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

test "String" {
    print("--- Test: String ---\n", .{});
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_][]const u8{ "Test", "a", "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }; // 128*x
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

// returns total number of bytes that would be written for the given string, including the length prefix
pub fn computeStringByteLength(string: []const u8) usize {
    return string.len + computeVarIntByteLength(@intCast(string.len));
}

test "String byte length" {
    print("--- Test: String byte length ---\n", .{});
    const values = [_][]const u8{ "Test", "a", "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }; // 128*x
    const expected_lengths = [_]usize{ 5, 2, 1, 130 };
    for (values, 0..) |v, i| {
        const length = computeStringByteLength(v);
        print("Value: {s}, Byte length: {d}, Expected: {d}\n", .{ v, length, expected_lengths[i] });
        try std.testing.expect(length == expected_lengths[i]);
    }
}
