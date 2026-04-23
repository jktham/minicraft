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
        const packet_id, const data = io.readPacket(tcp_reader) catch |err| {
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

var lastKeepAlive: i64 = 0;

fn processPacket(tcp_writer: *std.io.Writer, state: *State, packet_id: u8, req_data: []const u8) !void {
    var r = std.io.Reader.fixed(req_data);
    const req_reader = &r;

    var res_data: [100000]u8 = undefined;
    var w = std.io.Writer.fixed(&res_data);
    const res_writer = &w;

    const time = std.time.milliTimestamp();
    if (state.* == State.Play and time - lastKeepAlive > 10000) {
        // keep alive
        lastKeepAlive = time;
        try io.writeLong(res_writer, time); // id
        try io.writePacket(tcp_writer, 0x1f, res_writer.buffered());
        _ = res_writer.consumeAll();
        std.log.info("Sent keep alive", .{});
    }

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
        try io.writePacket(tcp_writer, 0x00, res_writer.buffered());
        _ = res_writer.consumeAll();

    } else if (state.* == State.Status and packet_id == 0x01) {
        // ping request
        const timestamp = try io.readLong(req_reader);
        std.log.info("ping_request: timestamp {d}", .{timestamp});

        // pong response
        try io.writeLong(res_writer, timestamp);
        try io.writePacket(tcp_writer, 0x01, res_writer.buffered());
        _ = res_writer.consumeAll();

    } else if (state.* == State.Login and packet_id == 0x00) {
        // hello request
        const name = try io.readString(req_reader);
        std.log.info("hello: name {s}", .{name});

        // login success response (skip encryption)
        try io.writeString(res_writer, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"); // uuid
        try io.writeString(res_writer, name); // username
        try io.writePacket(tcp_writer, 0x02, res_writer.buffered());
        _ = res_writer.consumeAll();

        setState(state, State.Play);

        // // disconnect
        // try io.writeString(res_writer, "{\"text\": \">:)\"}");
        // try io.writePacket(tcp_writer, 0x1A, res_writer.buffered());
        // _ = res_writer.consumeAll();

        // spawn position
        try io.writeLong(res_writer, 0x0000000000000000);
        try io.writePacket(tcp_writer, 0x46, res_writer.buffered());
        _ = res_writer.consumeAll();

        // join game
        try io.writeInt(res_writer, 0); // entity id
        try io.writeByte(res_writer, 1); // gamemode
        try io.writeInt(res_writer, 0); // dimension
        try io.writeByte(res_writer, 0); // difficulty
        try io.writeByte(res_writer, 0); // max players
        try io.writeString(res_writer, "flat"); // level type
        try io.writeBool(res_writer, false); // reduced debug info
        try io.writePacket(tcp_writer, 0x23, res_writer.buffered());
        _ = res_writer.consumeAll();

        // update client position (ends loading screen)
        try io.writeDouble(res_writer, 0);
        try io.writeDouble(res_writer, 0);
        try io.writeDouble(res_writer, 0);
        try io.writeFloat(res_writer, 0);
        try io.writeFloat(res_writer, 0);
        try io.writeByte(res_writer, 0b00011111); // flags (relative)
        try io.writeVarInt(res_writer, @truncate(time & 0x7FFFFFFF)); // teleport id
        try io.writePacket(tcp_writer, 0x2f, res_writer.buffered());
        _ = res_writer.consumeAll();

        // chunk data
        var chunk_data: [10000]u8 = undefined;
        var cw = std.io.Writer.fixed(&chunk_data);
        const chunk_writer = &cw;

        try io.writeByte(chunk_writer, 8); // bits per block
        try io.writeVarInt(chunk_writer, 2); // palette length
        for ([_]i32{0b0000000100000, 0b0000000010000}) |p| {
            try io.writeVarInt(chunk_writer, p); // palette entry
        }
        try io.writeVarInt(chunk_writer, 4096*8/64); // data length (number of longs)
        try io.writeBytes(chunk_writer, &[_]u8{0x00} ** 4096); // data array (8 bits per block, 16x16x16 blocks)
        try io.writeBytes(chunk_writer, &[_]u8{0x00} ** 2048); // block light (4 bits per block)
        try io.writeBool(chunk_writer, true); // sky light optional
        try io.writeBytes(chunk_writer, &[_]u8{0x00} ** 2048); // sky light (4 bits per block)

        for (0..16) |i| {
            for (0..16) |j| {
                try io.writeInt(res_writer, @as(i32, @intCast(i))-8); // chunk x
                try io.writeInt(res_writer, @as(i32, @intCast(j))-8); // chunk z
                try io.writeBool(res_writer, true); // ground up continuous
                try io.writeVarInt(res_writer, 0b0000000000001000); // primary bit mask
                try io.writeVarInt(res_writer, @intCast(chunk_writer.buffered().len + 1 + 256)); // data length
                try io.writeBytes(res_writer, chunk_writer.buffered()); // data
                try io.writeBool(res_writer, true); // biomes optional
                try io.writeBytes(res_writer, &[_]u8{127} ** 256); // biomes
                try io.writeVarInt(res_writer, 0); // number of block entities
                try io.writePacket(tcp_writer, 0x20, res_writer.buffered());
                _ = res_writer.consumeAll();
            }
        }

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
        const payload = try req_reader.allocRemaining(std.heap.page_allocator, std.io.Limit.unlimited); // unknown size
        std.log.info("plugin_message: channel {s}, payload 0x{x} ({s})", .{ channel, payload, try io.sanitizeString(payload) });

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

        // if (time - lastTeleportTime > 10000) {
        //     // update client
        //     try io.writeDouble(res_writer, x);
        //     try io.writeDouble(res_writer, y);
        //     try io.writeDouble(res_writer, z);
        //     try io.writeFloat(res_writer, yaw);
        //     try io.writeFloat(res_writer, pitch);
        //     try io.writeByte(res_writer, 0); // flags
        //     try io.writeVarInt(res_writer, @truncate(time & 0x7FFFFFFF)); // teleport id
        //     try io.writePacket(tcp_writer, 0x2f, res_writer.buffered());
        //     lastTeleportTime = time;
        // }

    } else if (state.* == State.Play and packet_id == 0x0f) {
        // look update
        const yaw = try io.readFloat(req_reader);
        const pitch = try io.readFloat(req_reader);
        const on_ground = try io.readBool(req_reader);
        std.log.info("look_update: yaw {}, pitch {}, on_ground {}", .{ yaw, pitch, on_ground });

    } else if (state.* == State.Play and packet_id == 0x00) {
        // teleport confirm
        const teleport_id = try io.readVarInt(req_reader);
        std.log.info("teleport_confirm: id {}", .{teleport_id});

    } else if (state.* == State.Play and packet_id == 0x0b) {
        // keep alive
        const id = try io.readLong(req_reader);
        std.log.info("keep_alive: id {}", .{id});

    } else {
        std.log.warn("unknown packet id 0x{x:0>2} in state {s}", .{ packet_id, @tagName(state.*) });
    }
}

fn setState(state: *State, newState: State) void {
    std.log.info("State change: {s} -> {s}", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}
