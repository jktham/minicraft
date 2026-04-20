const std = @import("std");
const minicraft = @import("minicraft");
const net = std.net;
const print = std.debug.print;
const io = minicraft.io;

const State = enum {
    Handshaking,
    Status,
    Login,
    Play,
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

    var read_buf: [10000]u8 = undefined;
    var r = client.stream.reader(&read_buf);
    const reader: *std.io.Reader = r.interface();

    var write_buf: [10000]u8 = undefined;
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
    print("Received packet: id 0x{x:0>2}, length {d}, data 0x{x}\n", .{ packet_id, length, data });
    
    if (state.* == State.Handshaking and packet_id == 0x00) {
        // handshake request
        const protocol_version = try io.readVarInt(reader);
        const server_address = try io.readString(reader);
        const server_port = try io.readShort(reader);
        const intent = try io.readVarInt(reader);
        print("  intention: protocol_version {d}, server_address {s}, server_port {d}, intent {d}\n", .{ protocol_version, server_address, server_port, intent });

        if (intent == 1) {
            state.* = State.Status;
        } else if (intent == 2) {
            state.* = State.Login;
        }

    } else if (state.* == State.Status and packet_id == 0x00) {
        // status request
        print("  status_request\n", .{});

        const status =
            \\{
            \\    "version": {
            \\        "name": "1.20.1",
            \\        "protocol": 763
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

        // status response
        try io.writeVarInt(writer, @intCast(io.computeStringByteLength(status) + 1));
        try writer.writeByte(0x00); // packet id
        try io.writeString(writer, status);
        try writer.flush();

    } else if (state.* == State.Status and packet_id == 0x01) {
        // ping request
        const timestamp = try io.readLong(reader);
        print("  ping_request: timestamp {d}\n", .{timestamp});

        // pong response
        try io.writeVarInt(writer, 9); // length of packet_id + timestamp
        try writer.writeByte(0x01); // packet id
        try io.writeLong(writer, timestamp);
        try writer.flush();

    } else if (state.* == State.Login and packet_id == 0x00) {
        // hello request
        const name = try io.readString(reader);
        const hasUUID = try io.readBool(reader);
        var uuid: u128 = 0;
        if (hasUUID) {
            uuid = try io.readUUID(reader);
        }
        print("  hello: name {s}, uuid 0x{x:0>32}\n", .{name, uuid});

        // login success response (skip encryption)
        try io.writeVarInt(writer, 1 + 16 + @as(i32, @intCast(io.computeStringByteLength(name))) + 1); // packet length
        try writer.writeByte(0x02); // packet id
        try io.writeUUID(writer, uuid); // uuid
        try io.writeString(writer, name); // username
        try io.writeVarInt(writer, 0); // length of properties array (0 for now)
        try writer.flush();
        state.* = State.Play;

        try io.writeVarInt(writer, @as(i32, @intCast(io.computeStringByteLength("{\"text\": \">:)\"}"))) + 1); // packet length
        try writer.writeByte(0x1A);
        try io.writeString(writer, "{\"text\": \">:)\"}");
        try writer.flush();

    } else {
        print("  Unknown packet id 0x{x:0>2} in state {d}\n", .{ packet_id, state.* });
    }
}
