const std = @import("std");
const net = std.net;
const io = @import("io.zig");

const State = enum {
    Handshaking,
    Status,
    Login,
    Play,
};

pub fn startServer() !void {
    const in = try net.Ip4Address.parse("0.0.0.0", 25565);
    const address = net.Address{ .in = in };
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.log.info("Listening on {f}", .{server.listen_address});

    while (true) {
        const client = try server.accept();
        try handleClient(client);
    }
}

fn handleClient(client: net.Server.Connection) !void {
    std.log.info("Client connected: {f}", .{client.address});
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
                std.log.info("Client disconnected: {f}", .{client.address});
                return;
            }
            std.log.err("Error reading packet: {}", .{err});
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
    std.log.debug("Received packet: length {d}, id 0x{x:0>2}, data 0x{x} ({s})", .{ length, packet_id, data, try sanitizeString(data) });
    return .{packet_id, data};
}

fn writePacket(tcp_writer: *std.io.Writer, packet_id: u8, data: []const u8) !void {
    try io.writeVarInt(tcp_writer, @intCast(data.len + 1));
    try tcp_writer.writeByte(packet_id);
    try tcp_writer.writeAll(data);
    try tcp_writer.flush();
    std.log.debug("Sent packet: length {d}, id 0x{x:0>2}, data 0x{x} ({s})", .{ data.len + 1, packet_id, data, try sanitizeString(data) });
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
        std.log.info("handshake: protocol_version {d}, server_address {s}, server_port {d}, intent {d}", .{ protocol_version, server_address, server_port, intent });

        if (intent == 1) {
            setState(state, State.Status);
        } else if (intent == 2) {
            setState(state, State.Login);
        }

    } else if (state.* == State.Status and packet_id == 0x00) {
        // status request
        std.log.info("status_request", .{});

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
        std.log.info("ping_request: timestamp {d}", .{timestamp});

        // pong response
        try io.writeLong(res_writer, timestamp);
        try writePacket(tcp_writer, 0x01, res_writer.buffered());

    } else if (state.* == State.Login and packet_id == 0x00) {
        // hello request
        const name = try io.readString(req_reader);
        std.log.info("hello: name {s}", .{name});

        // login success response (skip encryption)
        try io.writeString(res_writer, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"); // uuid
        try io.writeString(res_writer, name); // username
        try writePacket(tcp_writer, 0x02, res_writer.buffered());

        setState(state, State.Play);

        // // disconnect
        // _ = res_writer.consumeAll();
        // try io.writeString(res_writer, "{\"text\": \">:)\"}");
        // try writePacket(tcp_writer, 0x1A, res_writer.buffered());

        // join game
        _ = res_writer.consumeAll();
        try io.writeInt(res_writer, 0); // entity id
        try io.writeByte(res_writer, 1); // gamemode
        try io.writeInt(res_writer, 0); // dimension
        try io.writeByte(res_writer, 0); // difficulty
        try io.writeByte(res_writer, 0); // max players
        try io.writeString(res_writer, "flat"); // level type
        try io.writeBool(res_writer, false); // reduced debug info
        try writePacket(tcp_writer, 0x23, res_writer.buffered());

        // spawn position
        _ = res_writer.consumeAll();
        try io.writeInt(res_writer, 0); // x
        try io.writeInt(res_writer, 0); // z
        try writePacket(tcp_writer, 0x46, res_writer.buffered());

        // chunk data
        _ = res_writer.consumeAll();
        try io.writeInt(res_writer, 0); // chunk x
        try io.writeInt(res_writer, 0); // chunk z
        try io.writeBool(res_writer, true); // continuous
        try io.writeVarInt(res_writer, 0b1); // primary bit mask
        try io.writeVarInt(res_writer, 0 + 256); // data length
        try res_writer.writeAll(&[_]u8{}); // data
        try res_writer.writeAll(&[_]u8{0} ** 256); // biomes
        try io.writeVarInt(res_writer, 0); // number of block entities
        try writePacket(tcp_writer, 0x20, res_writer.buffered());

    } else if (state.* == State.Play and packet_id == 0x04) {
        // client settings
        const locale = try io.readString(req_reader);
        const view_distance = try io.readByte(req_reader);
        const chat_mode = try io.readVarInt(req_reader);
        const chat_colors = try io.readBool(req_reader);
        const skin_parts = try io.readByte(req_reader);
        const main_hand = try io.readVarInt(req_reader);
        std.log.info("client_settings: locale {s}, view_distance {d}, chat_mode {d}, chat_colors {}, skin_parts {d}, main_hand {d}", .{ locale, view_distance, chat_mode, chat_colors, skin_parts, main_hand });

    } else if (state.* == State.Play and packet_id == 0x09) {
        // plugin message
        const channel = try io.readString(req_reader);
        const payload = try req_reader.allocRemaining(std.heap.page_allocator, std.io.Limit.unlimited);
        std.log.info("plugin_message: channel {s}, payload 0x{x} ({s})", .{ channel, payload, payload });

    } else if (state.* == State.Play and packet_id == 0x0d) {
        // position update
        const x = try io.readDouble(req_reader);
        const y = try io.readDouble(req_reader);
        const z = try io.readDouble(req_reader);
        const on_ground = try io.readBool(req_reader);
        std.log.info("position_update: x {}, y {}, z {}, on_ground {}", .{ x, y, z, on_ground });

    } else if (state.* == State.Play and packet_id == 0x0e) {
        // position and look update
        const x = try io.readDouble(req_reader);
        const y = try io.readDouble(req_reader);
        const z = try io.readDouble(req_reader);
        const yaw = try io.readFloat(req_reader);
        const pitch = try io.readFloat(req_reader);
        const on_ground = try io.readBool(req_reader);
        std.log.info("position_look_update: x {}, y {}, z {}, yaw {}, pitch {}, on_ground {}", .{ x, y, z, yaw, pitch, on_ground });

    } else if (state.* == State.Play and packet_id == 0x0f) {
        // look update
        const yaw = try io.readFloat(req_reader);
        const pitch = try io.readFloat(req_reader);
        const on_ground = try io.readBool(req_reader);
        std.log.info("look_update: yaw {}, pitch {}, on_ground {}", .{ yaw, pitch, on_ground });

    } else {
        std.log.info("unknown packet id 0x{x:0>2} in state {s}", .{ packet_id, @tagName(state.*) });
    }
}

fn setState(state: *State, newState: State) void {
    std.log.info("State change: {s} -> {s}", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}

fn sanitizeString(str: []const u8) ![]const u8 {
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
