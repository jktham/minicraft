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
    const tcp_reader: *std.io.Reader = r.interface();

    var write_buf: [10000]u8 = undefined;
    var w = client.stream.writer(&write_buf);
    const tcp_writer: *std.io.Writer = &w.interface;
    
    var state: State = State.Handshaking;

    while (true) {
        const packet_id, const data = readPacket(tcp_reader) catch |err| {
            if (err == error.EndOfStream) {
                print("Client disconnected: {f}\n", .{client.address});
                return;
            }
            print("Error reading packet: {}\n", .{err});
            return;
        };
        try processPacket(tcp_writer, &state, packet_id, data);
    }
}

fn readPacket(tcp_reader: *std.io.Reader) !struct{u8, []u8} {
    const length = try io.readVarInt(tcp_reader);
    if (length == 0) {
        return error.EmptyPacket;
    }
    const packet_id = try tcp_reader.takeByte();
    const data = try tcp_reader.take(@intCast(length - 1)); // packet_id is 1 byte
    print("  ⇣ Received packet: length {d}, id 0x{x:0>2}, data 0x{x}\n", .{ length, packet_id, data });
    return .{packet_id, data};
}

fn writePacket(tcp_writer: *std.io.Writer, packet_id: u8, data: []const u8) !void {
    try io.writeVarInt(tcp_writer, @intCast(data.len + 1));
    try tcp_writer.writeByte(packet_id);
    try tcp_writer.writeAll(data);
    try tcp_writer.flush();
    print("  ⇡ Sent packet: length {d}, id 0x{x:0>2}, data 0x{x}\n", .{ data.len + 1, packet_id, data });
}

fn processPacket(tcp_writer: *std.io.Writer, state: *State, packet_id: u8, req_data: []const u8) !void {
    var r = std.io.Reader.fixed(req_data);
    const req_reader = &r;

    var res_data: [10000]u8 = undefined;
    var w = std.io.Writer.fixed(&res_data);
    const res_writer = &w;

    if (state.* == State.Handshaking and packet_id == 0x00) {
        // handshake request
        const protocol_version = try io.readVarInt(req_reader);
        const server_address = try io.readString(req_reader);
        const server_port = try io.readShort(req_reader);
        const intent = try io.readVarInt(req_reader);
        print("        intention: protocol_version {d}, server_address {s}, server_port {d}, intent {d}\n", .{ protocol_version, server_address, server_port, intent });

        if (intent == 1) {
            setState(state, State.Status);
        } else if (intent == 2) {
            setState(state, State.Login);
        }

    } else if (state.* == State.Status and packet_id == 0x00) {
        // status request
        print("        status_request\n", .{});

        const status =
            \\{
            \\    "version": {
            \\        "name": "1.12.2",
            \\        "protocol": 340
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
        try io.writeString(res_writer, status);
        try writePacket(tcp_writer, 0x00, res_writer.buffered());

    } else if (state.* == State.Status and packet_id == 0x01) {
        // ping request
        const timestamp = try io.readLong(req_reader);
        print("        ping_request: timestamp {d}\n", .{timestamp});

        // pong response
        try io.writeLong(res_writer, timestamp);
        try writePacket(tcp_writer, 0x01, res_writer.buffered());

    } else if (state.* == State.Login and packet_id == 0x00) {
        // hello request
        const name = try io.readString(req_reader);
        print("        hello: name {s}\n", .{name});

        // login success response (skip encryption)
        try io.writeString(res_writer, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"); // uuid
        try io.writeString(res_writer, name); // username
        try writePacket(tcp_writer, 0x02, res_writer.buffered());

        setState(state, State.Play);

        _ = res_writer.consumeAll();
        try io.writeString(res_writer, "{\"text\": \">:)\"}");
        try writePacket(tcp_writer, 0x1A, res_writer.buffered());

    } else {
        print("        unknown packet id 0x{x:0>2} in state {d}\n", .{ packet_id, state.* });
    }
}

fn setState(state: *State, newState: State) void {
    print("        State change: {s} -> {s}\n", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}
