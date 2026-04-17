const std = @import("std");
const minicraft = @import("minicraft");
const net = std.net;
const print = std.debug.print;
const io = minicraft.io;

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
    print("Client connected: {f}\n", .{client.address});
    defer client.stream.close();

    var read_buf: [1024]u8 = undefined;
    var r = client.stream.reader(&read_buf);
    const reader: *std.io.Reader = r.interface();

    var write_buf: [1024]u8 = undefined;
    var w = client.stream.writer(&write_buf);
    const writer: *std.io.Writer = &w.interface;

    var state: u32 = 0;

    while (true) {
        readPacket(reader, writer, &state) catch |err| {
            if (err == error.EndOfStream) {
                print("Client disconnected: {f}\n", .{client.address});
                return;
            }
            print("Error reading packet: {}\n", .{err});
            return;
        };
    }
}

fn readPacket(reader: *std.io.Reader, writer: *std.io.Writer, state: *u32) !void {
    const length = try io.readVarInt(reader);
    const packet_id = try reader.takeByte();
    print("Received packet {d}, length {d}\n", .{ packet_id, length });

    if (packet_id == 0 and state.* == 0) {
        // handshake packet
        const protocol_version = try io.readVarInt(reader);
        const server_address = try io.readString(reader);
        const server_port = try io.readShort(reader);
        const intent = try io.readVarInt(reader);
        print("Handshake packet: {d}, {s}, {d}, {d}\n", .{ protocol_version, server_address, server_port, intent });
        state.* = 1;
    }
    if (packet_id == 0 and state.* == 1) {
        print("Status request packet\n", .{});

        const status =
            \\{
            \\    "version": {
            \\        "name": "1.21.8",
            \\        "protocol": 772
            \\    },
            \\    "players": {
            \\        "max": 20,
            \\        "online": 1,
            \\        "sample": [
            \\            {
            \\                "name": "thinkofdeath",
            \\                "id": "4566e69f-c907-48ee-8d71-d7ba5aa00d20"
            \\            }
            \\        ]
            \\    },
            \\    "description": {
            \\        "text": "helooo c:"
            \\    },
            \\    "favicon": "data:image/png;base64,<data>",
            \\    "enforcesSecureChat": false
            \\}
        ;

        print("Status response packet: {s}\n", .{status});

        try io.writeVarInt(writer, @intCast(io.computeStringByteLength(status) + 1));
        try writer.writeByte(0); // packet id
        try io.writeString(writer, status);
        try writer.flush();
        state.* = 2;
    }
}
