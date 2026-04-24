const std = @import("std");
const print = std.debug.print;

test "testBuf" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]u8{ 0, 1, 127, 255 };
    for (values) |v| {
        try writer.writeByte(v);
    }
    for (values, 0..) |v, i| {
        const read_value = try reader.takeByte();
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
}

pub fn readByte(reader: *std.io.Reader) !u8 {
    return reader.takeByte();
}

pub fn writeByte(writer: *std.io.Writer, value: u8) !void {
    try writer.writeByte(value);
}

test "testByte" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]u8{ 0, 1, 127, 255 };
    for (values) |v| {
        try writeByte(&writer, v);
    }
    try writer.flush();

    for (values, 0..) |v, i| {
        const read_value = try readByte(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
}

pub fn readBytes(reader: *std.io.Reader, n: usize) ![]const u8 {
    return try reader.take(n);
}

pub fn writeBytes(writer: *std.io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
}

test "testBytes" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_][]const u8{ &[_]u8{0}, &[_]u8{1, 2, 3}, &[_]u8{} };
    for (values) |v| {
        try writeBytes(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000,
        0b00000001, 0b00000010, 0b00000011,
    };
    for (bytes, 0..) |b, i| {
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readBytes(&reader, v.len);
        std.testing.expect(std.mem.eql(u8, read_value, v)) catch |err| {
            print("read 0x{x}, expected 0x{x} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
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
    try writeByte(writer, if (value) 1 else 0);
}

test "testBool" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]bool{ false, true };
    for (values) |v| {
        try writeBool(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000,
        0b00000001,
    };
    for (bytes, 0..) |b, i| {
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readBool(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
}

pub fn readVarInt(reader: *std.io.Reader) !i32 {
    const CONTINUE_MASK: u8 = 0b10000000;
    const DATA_MASK: u8 = 0b01111111;

    var value: u32 = 0;
    var position: u32 = 0; // not u5 to avoid overflow panic, instead handle by checking if position >= 32
    while (true) {
        const byte: u8 = try reader.takeByte();
        value |= @as(u32, byte & DATA_MASK) << @truncate(position);

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

// param type i32 guarantees valid VarInt encoding, so no need to check for overflow when writing
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
        try writeByte(writer, byte);

        if (remaining == 0) {
            break;
        }
    }
}

test "testVarInt" {
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
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readVarInt(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }

    try writeBytes(&writer, &[_]u8{0b10000000, 0b10000000, 0b10000000, 0b10000000, 0b10000000, 0b00000000}); // invalid VarInt (too long)
    try writer.flush();
    try std.testing.expectError(error.InvalidVarInt, readVarInt(&reader));
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

test "testVarIntByteLength" {
    const values = [_]i32{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i32), -1, std.math.minInt(i32) };
    const expected_lengths = [_]usize{ 1, 1, 1, 1, 2, 2, 5, 5, 5 };
    for (values, 0..) |v, i| {
        const length = computeVarIntByteLength(v);
        std.testing.expect(length == expected_lengths[i]) catch |err| {
            print("computed {}, expected {} at index {}\n", .{length, expected_lengths[i], i});
            return err;
        };
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
    try writeBytes(writer, &bytes);
}

test "testShort" {
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
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readShort(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
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
    try writeBytes(writer, &bytes);
}

test "testInt" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]i32{ 0, 1, 2, 127, 128, 255, std.math.maxInt(i32), -1, std.math.minInt(i32) };
    for (values) |v| {
        try writeInt(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b00000000, 0b00000000, 0b00000000, 0b00000001,
        0b00000000, 0b00000000, 0b00000000, 0b00000010,
        0b00000000, 0b00000000, 0b00000000, 0b01111111,
        0b00000000, 0b00000000, 0b00000000, 0b10000000,
        0b00000000, 0b00000000, 0b00000000, 0b11111111,
        0b01111111, 0b11111111, 0b11111111, 0b11111111,
        0b11111111, 0b11111111, 0b11111111, 0b11111111,
        0b10000000, 0b00000000, 0b00000000, 0b00000000,
    };
    for (bytes, 0..) |b, i| {
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readInt(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
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
    try writeBytes(writer, &bytes);
}

test "testLong" {
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
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readLong(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
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
    try writeBytes(writer, &bytes);
}

test "testFloat" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]f32{ 0.0, 1.0, 2.0, std.math.floatMax(f32), -1.0, std.math.floatMin(f32) };
    for (values) |v| {
        try writeFloat(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b00111111, 0b10000000, 0b00000000, 0b00000000,
        0b01000000, 0b00000000, 0b00000000, 0b00000000,
        0b01111111, 0b01111111, 0b11111111, 0b11111111,
        0b10111111, 0b10000000, 0b00000000, 0b00000000,
        0b00000000, 0b10000000, 0b00000000, 0b00000000,
    };
    for (bytes, 0..) |b, i| {
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readFloat(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
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
    try writeBytes(writer, &bytes);
}

test "testDouble" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]f64{ 0.0, 1.0, 2.0, std.math.floatMax(f64), -1.0, std.math.floatMin(f64) };
    for (values) |v| {
        try writeDouble(&writer, v);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b00111111, 0b11110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b01000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b01111111, 0b11101111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111,
        0b10111111, 0b11110000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
        0b00000000, 0b00010000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000,
    };
    for (bytes, 0..) |b, i| {
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readDouble(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
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
    try writeBytes(writer, &bytes);
}

test "testUUID" {
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
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readUUID(&reader);
        std.testing.expect(read_value == v) catch |err| {
            print("read {}, expected {} at index {}\n", .{read_value, v, i});
            return err;
        };
    }
}

pub fn readString(reader: *std.io.Reader) ![]const u8 {
    const length = try readVarInt(reader);
    if (length < 0) {
        return error.InvalidStringLength;
    }
    const string = try readBytes(reader, @intCast(length));
    return string;
}

pub fn writeString(writer: *std.io.Writer, string: []const u8) !void {
    try writeVarInt(writer, @intCast(string.len));
    try writeBytes(writer, string);
}

test "testString" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_][]const u8{ "Test", "a", "", "x" ** 128 };
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
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readString(&reader);
        std.testing.expect(std.mem.eql(u8, read_value, v)) catch |err| {
            print("read {s}, expected {s} at index {}\n", .{read_value, v, i});
            return err;
        };
    }

    try writeVarInt(&writer, -1); // invalid length
    try writer.flush();
    try std.testing.expectError(error.InvalidStringLength, readString(&reader));
}

// returns total number of bytes that would be written for the given string, including the length prefix
pub fn computeStringByteLength(string: []const u8) usize {
    return string.len + computeVarIntByteLength(@intCast(string.len));
}

test "testStringByteLength" {
    const values = [_][]const u8{ "Test", "a", "", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }; // 128*x
    const expected_lengths = [_]usize{ 5, 2, 1, 130 };
    for (values, 0..) |v, i| {
        const length = computeStringByteLength(v);
        std.testing.expect(length == expected_lengths[i]) catch |err| {
            print("computed {}, expected {} at index {}\n", .{length, expected_lengths[i], i});
            return err;
        };
    }
}

pub fn readPacket(reader: *std.io.Reader) !struct{u8, []const u8} {
    const length = try readVarInt(reader);
    if (length <= 0) {
        return error.InvalidPacketLength;
    }
    const packet_id = try readByte(reader);
    const data = try readBytes(reader, @intCast(length - 1)); // packet_id is 1 byte
    std.log.debug("Received packet: length {d}, id 0x{x:0>2}, data 0x{x} ({s})", .{ length, packet_id, data, try sanitizeString(data) });
    return .{packet_id, data};
}

// write packet and flush
pub fn writePacket(writer: *std.io.Writer, packet_id: u8, data: []const u8) !void {
    try writeVarInt(writer, @intCast(data.len + 1));
    try writeByte(writer, packet_id);
    try writeBytes(writer, data);
    try writer.flush();

    if (packet_id == 0x20) { // too large to print, stdout slow
        std.log.debug("Sent large packet: length {d}, id 0x{x:0>2}", .{ data.len + 1, packet_id });
    } else {
        std.log.debug("Sent packet: length {d}, id 0x{x:0>2}, data 0x{x} ({s})", .{ data.len + 1, packet_id, data, try sanitizeString(data) });
    }
}

test "testPacket" {
    var buf: [1000]u8 = undefined;
    var reader = std.io.Reader.fixed(&buf);
    var writer = std.io.Writer.fixed(&buf);

    const values = [_]struct{u8, []const u8}{ .{0x01, "Test"}, .{0xff, ""}, .{0x10, &[_]u8{0x01, 0x02}} };
    for (values) |v| {
        try writePacket(&writer, v[0], v[1]);
    }
    try writer.flush();

    const bytes = [_]u8{
        0b00000101,
        0b00000001,
        'T', 'e', 's', 't',
        0b00000001,
        0b11111111,

        0b00000011,
        0b00010000,
        0b00000001, 0b00000010,
    };
    for (bytes, 0..) |b, i| {
        std.testing.expect(buf[i] == b) catch |err| {
            print("wrote 0b{b:0>8}, expected 0b{b:0>8} at index {}\n", .{buf[i], b, i});
            return err;
        };
    }

    for (values, 0..) |v, i| {
        const read_value = try readPacket(&reader);
        std.testing.expect(read_value[0] == v[0]) catch |err| {
            print("read 0x{x:0>2}, expected 0x{x:0>2} at index {}\n", .{read_value[0], v[0], i});
            return err;
        };
        std.testing.expect(std.mem.eql(u8, read_value[1], v[1])) catch |err| {
            print("read 0x{x}, expected 0x{x} at index {}\n", .{read_value[1], v[1], i});
            return err;
        };
    }

    try writeVarInt(&writer, 0); // invalid length
    try writer.flush();
    try std.testing.expectError(error.InvalidPacketLength, readPacket(&reader));
}

// replace non-printable characters in a string for logging purposes
pub fn sanitizeString(str: []const u8) ![]const u8 {
    var sanitized = try std.heap.page_allocator.dupe(u8, str);
    for (sanitized, 0..sanitized.len) |c, i| {
        if (c >= 32 and c < 127) {
            sanitized[i] = c;
        } else {
            sanitized[i] = '?';
        }
    }
    return sanitized;
}
