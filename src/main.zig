const std = @import("std");
const minicraft = @import("minicraft");
const net = std.net;
const print = std.debug.print;

pub fn main() !void {
    const loopback = try net.Ip4Address.parse("127.0.0.1", 25565);
    const localhost = net.Address{ .in = loopback };
    var server = try localhost.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    const addr = server.listen_address;
    print("Listening on {}\n", .{addr.getPort()});

    while (true) {
        const client = try server.accept();
        try handleClient(client);
    }
}

fn handleClient(client: net.Server.Connection) !void {
    print("Accepted connection from {f}\n", .{client.address});
    defer client.stream.close();

    var read_buf: [1024]u8 = undefined;
    var r = client.stream.reader(&read_buf);
    const reader: *std.io.Reader = r.interface();

    var write_buf: [1024]u8 = undefined;
    var w = client.stream.writer(&write_buf);
    const writer: *std.io.Writer = &w.interface;

    while (true) {
        readPacket(reader, writer) catch |err| {
            print("Error reading packet: {}\n", .{err});
            return;
        };
    }
}

fn readPacket(reader: *std.io.Reader, writer: *std.io.Writer) !void {
    const length = try readVarInt(reader);
    const packet_id = try reader.takeByte();
    print("Received packet with packet_id {d} and length {d}\n", .{ packet_id, length });

    if (packet_id == 0 and length != 1) {
        // handshake packet
        const protocol_version = try readVarInt(reader);
        const server_address = try readString(reader);
        const server_port = try readShort(reader);
        const intent = try readVarInt(reader);
        print("Handshake packet: {d}, {s}, {d}, {d}\n", .{ protocol_version, server_address, server_port, intent });
    } else if (packet_id == 0) {
        print("Status request packet\n", .{});

        const status = "{\"version\": {\"name\": \"1.21.8\",\"protocol\": 772},\"description\": {\"text\": \"<3\"}}";

        print("Status response packet: {s}\n", .{status});

        try writer.writeByte(status.len + 2);
        try writer.writeByte(0);
        try writer.writeByte(status.len);
        try writer.writeAll(status);
        try writer.flush();
    }
}

fn readVarInt(reader: *std.io.Reader) !u40 {
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

    print("VarInt: {d}\n", .{value});
    return value;
}

fn readShort(reader: *std.io.Reader) !i16 {
    const bytes = try reader.take(2);
    const short: i16 = @as(i16, bytes[0]) << 8 | @as(i16, bytes[1]);

    print("Short: {d}\n", .{short});
    return short;
}

fn readString(reader: *std.io.Reader) ![]u8 {
    const length = try readVarInt(reader);
    const string = try reader.take(@intCast(length));

    print("String: {s}\n", .{string});
    return string;
}
