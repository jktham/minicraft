const std = @import("std");
const minicraft = @import("minicraft");
const net = std.net;
const print = std.debug.print;
const io = minicraft.io;

const State = enum {
    Handshaking,
    Status,
    Login,
};

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

    var state: State = State.Handshaking;

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

fn readPacket(reader: *std.io.Reader, writer: *std.io.Writer, state: *State) !void {
    const length = try io.readVarInt(reader);
    if (length == 0) {
        print("Received empty packet\n", .{});
        return;
    }
    const packet_id = try reader.takeByte();
    const data = try reader.peek(@intCast(length - 1)); // packet_id is 1 byte
    print("Received packet: id {d}, length {d}, data 0x{x}\n", .{ packet_id, length, data });

    if (state.* == State.Handshaking and packet_id == 0) {
        // handshake packet
        const protocol_version = try io.readVarInt(reader);
        const server_address = try io.readString(reader);
        const server_port = try io.readShort(reader);
        const intent = try io.readVarInt(reader);
        print("Handshake request: protocol_version {d}, server_address {s}, server_port {d}, intent {d}\n", .{ protocol_version, server_address, server_port, intent });

        if (intent == 1) {
            state.* = State.Status;
        } else if (intent == 2) {
            state.* = State.Login;
        }

    } else if (state.* == State.Status and packet_id == 0) {
        // status request
        print("Status request\n", .{});

        const status =
            \\{
            \\    "version": {
            \\        "name": "26.1.2",
            \\        "protocol": 775
            \\    },
            \\    "players": {
            \\        "max": 20,
            \\        "online": 1,
            \\        "sample": [
            \\            {
            \\                "name": "goob",
            \\                "id": "4566e69f-c907-48ee-8d71-d7ba5aa00d20"
            \\            }
            \\        ]
            \\    },
            \\    "description": {
            \\        "text": "<3"
            \\    },
            \\    "favicon": "data:image/png;base64,<data>",
            \\    "enforcesSecureChat": false
            \\}
        ;

        try io.writeVarInt(writer, @intCast(io.computeStringByteLength(status) + 1));
        try writer.writeByte(0); // packet id
        try io.writeString(writer, status);
        try writer.flush();

    } else if (state.* == State.Status and packet_id == 1) {
        // ping request
        const timestamp = try io.readLong(reader);
        print("Ping request: timestamp {d}\n", .{timestamp});

        try io.writeVarInt(writer, 9); // length of packet_id + timestamp
        try writer.writeByte(1); // packet id
        try io.writeLong(writer, timestamp);
        try writer.flush();

    } else {
        print("Unknown packet id {d} in state {d}\n", .{ packet_id, state.* });
    }
}
