const std = @import("std");
const net = std.net;
const io = @import("io.zig");
const player = @import("player.zig");
const world = @import("world.zig");

// 1.12.2 protocol: https://minecraft.wiki/w/Protocol?oldid=2772385, https://c4k3.github.io/wiki.vg/Protocol.html
// 1.12.2 block/item/entity ids: https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening

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

    try world.generate();

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

    var res_data: [10000000]u8 = undefined;
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

        var file = try std.fs.cwd().openFile("res/status.json", .{});
        defer file.close();

        const allocator = std.heap.page_allocator;
        const status = try file.readToEndAlloc(allocator, 100000);
        defer allocator.free(status);

        // status response
        try io.writeString(res_writer, status);
        try io.writePacket(tcp_writer, 0x00, res_writer.buffered());
        _ = res_writer.consumeAll();

    } else if (state.* == State.Status and packet_id == 0x01) {
        // ping request
        const timestamp = try io.readLong(req_reader);
        std.log.info("ping_request: timestamp {d}", .{timestamp});

        player.ping = @truncate((time - timestamp) * 2);

        // pong response
        try io.writeLong(res_writer, timestamp);
        try io.writePacket(tcp_writer, 0x01, res_writer.buffered());
        _ = res_writer.consumeAll();

    } else if (state.* == State.Login and packet_id == 0x00) {
        // hello request
        const name = try io.readString(req_reader);
        std.log.info("hello: name {s}", .{name});

        player.name = name;
        player.uuid = 0xf81d4fae7dec11d0a76500a0c91e6bf6; // dummy uuid
        // login success response (skip encryption)
        try io.writeString(res_writer, try io.UUIDtoString(player.uuid)); // uuid as string
        try io.writeString(res_writer, player.name); // username
        try io.writePacket(tcp_writer, 0x02, res_writer.buffered());
        _ = res_writer.consumeAll();

        setState(state, State.Play);

        // // disconnect
        // try io.writeString(res_writer, "{\"text\": \">:)\"}");
        // try io.writePacket(tcp_writer, 0x1A, res_writer.buffered());
        // _ = res_writer.consumeAll();

        // set spawn position (doesnt work idk)
        try io.writePosition(res_writer, 0, 64, 0); // x, y, z
        try io.writePacket(tcp_writer, 0x46, res_writer.buffered());
        _ = res_writer.consumeAll();

        // join game
        player.gamemode = 0; // creative
        player.eid = 0xbeef; // dummy entity id
        try io.writeInt(res_writer, player.eid); // entity id
        try io.writeByte(res_writer, player.gamemode); // gamemode
        try io.writeInt(res_writer, 0); // dimension
        try io.writeByte(res_writer, 2); // difficulty
        try io.writeByte(res_writer, 0); // max players
        try io.writeString(res_writer, "default"); // level type
        try io.writeBool(res_writer, false); // reduced debug info
        try io.writePacket(tcp_writer, 0x23, res_writer.buffered());
        _ = res_writer.consumeAll();

        // set slot
        try io.writeByte(res_writer, 0); // window id (0 for player inventory)
        try io.writeShort(res_writer, 36); // slot id, (36-44 for hotbar)
        try io.writeShort(res_writer, 257); // item id, -1 for empty (next fields not sent if -1)
        try io.writeByte(res_writer, 1); // item count
        try io.writeShort(res_writer, 0); // item damage
        try io.writeBytes(res_writer, &[_]u8{0}); // item nbt, 0 for none
        try io.writePacket(tcp_writer, 0x16, res_writer.buffered());
        _ = res_writer.consumeAll();

        // update player list
        try io.writeVarInt(res_writer, 0); // action: add
        try io.writeVarInt(res_writer, 1); // number of players
        try io.writeUUID(res_writer, player.uuid); // player uuid
        try io.writeString(res_writer, player.name); // player name
        try io.writeVarInt(res_writer, 0); // properties
        try io.writeVarInt(res_writer, player.gamemode); // gamemode
        try io.writeVarInt(res_writer, player.ping); // ping
        try io.writeBool(res_writer, false); // has display name
        try io.writePacket(tcp_writer, 0x2e, res_writer.buffered());
        _ = res_writer.consumeAll();

        // update client position (ends loading screen)
        const center = @as(f32, world.N_CHUNKS * world.N_BLOCKS) / 2.0;
        try io.writeDouble(res_writer, center); // x
        try io.writeDouble(res_writer, 20); // y
        try io.writeDouble(res_writer, center); // z
        try io.writeFloat(res_writer, 0); // yaw
        try io.writeFloat(res_writer, 0); // pitch
        try io.writeByte(res_writer, 0b00000000); // flags (relative)
        try io.writeVarInt(res_writer, @truncate(time & 0x7FFFFFFF)); // teleport id
        try io.writePacket(tcp_writer, 0x2f, res_writer.buffered());
        _ = res_writer.consumeAll();

        // chunk data
        std.log.info("chunk_data", .{});
        for (0..world.N_CHUNKS) |chunk_x| {
            for (0..world.N_CHUNKS) |chunk_z| {
                var chunk_data: [10000000]u8 = undefined;
                var cw = std.io.Writer.fixed(&chunk_data);
                const chunk_writer = &cw;

                for (0..world.N_SUBCHUNKS) |chunk_y| {
                    try io.writeByte(chunk_writer, 8); // bits per block
                    try io.writeVarInt(chunk_writer, world.palette.len); // palette length
                    for (world.palette) |p| {
                        try io.writeVarInt(chunk_writer, p); // palette entry
                    }
                    try io.writeVarInt(chunk_writer, (4096 * 8) / 64); // data length (number of longs)
                    try io.writeBytes(chunk_writer, try world.getChunkPointer(@intCast(chunk_x), @intCast(chunk_y), @intCast(chunk_z))); // block data (4096 blocks per subchunk)
                    try io.writeBytes(chunk_writer, &[_]u8{0xff} ** 2048); // block light (4 bits per block)
                    try io.writeBytes(chunk_writer, &[_]u8{0xff} ** 2048); // sky light (4 bits per block)
                }

                try io.writeInt(res_writer, @as(i32, @intCast(chunk_x))); // chunk x
                try io.writeInt(res_writer, @as(i32, @intCast(chunk_z))); // chunk z
                try io.writeBool(res_writer, true); // ground up continuous
                try io.writeVarInt(res_writer, 0xffff); // primary bit mask
                try io.writeVarInt(res_writer, @intCast(chunk_writer.buffered().len + 256)); // data length
                try io.writeBytes(res_writer, chunk_writer.buffered()); // data
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

    } else if (state.* == State.Play and packet_id == 0x0c) {
        // player update
        const on_ground = try io.readBool(req_reader);
        std.log.info("player_update: on_ground {}", .{ on_ground });

    } else if (state.* == State.Play and packet_id == 0x0d) {
        // position update
        const x = try io.readDouble(req_reader);
        const y = try io.readDouble(req_reader);
        const z = try io.readDouble(req_reader);
        const on_ground = try io.readBool(req_reader);
        std.log.info("position_update: position ({}, {}, {}), on_ground {}", .{ x, y, z, on_ground });

        player.position = [3]f64{ x, y, z };

    } else if (state.* == State.Play and packet_id == 0x0e) {
        // position and look update
        const x = try io.readDouble(req_reader);
        const y = try io.readDouble(req_reader);
        const z = try io.readDouble(req_reader);
        const yaw = try io.readFloat(req_reader);
        const pitch = try io.readFloat(req_reader);
        const on_ground = try io.readBool(req_reader);
        std.log.info("position_look_update: position ({}, {}, {}), yaw {}, pitch {}, on_ground {}", .{ x, y, z, yaw, pitch, on_ground });

        player.position = [3]f64{ x, y, z };

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

    } else if (state.* == State.Play and packet_id == 0x14) {
        // player digging
        const status = try io.readVarInt(req_reader);
        const x, const y, const z = try io.readPosition(req_reader);
        const face = try io.readByte(req_reader);
        std.log.info("player_digging: status {}, position ({}, {}, {}), face {}", .{ status, x, y, z, face });

        if (player.gamemode == 1 and status == 0 or player.gamemode == 0 and status == 2) {
            // finish digging, set block to air
            const block = try world.getBlock(@intCast(x), @intCast(y), @intCast(z));
            try world.setBlock(@intCast(x), @intCast(y), @intCast(z), world.Block.Air);

            // // spawn xp orb
            // try io.writeVarInt(res_writer, std.crypto.random.int(i32)); // entity id
            // try io.writeDouble(res_writer, @floatFromInt(x)); // x
            // try io.writeDouble(res_writer, @floatFromInt(y)); // y
            // try io.writeDouble(res_writer, @floatFromInt(z)); // z
            // try io.writeShort(res_writer, 10); // count
            // try io.writePacket(tcp_writer, 0x01, res_writer.buffered());
            // _ = res_writer.consumeAll();

            player.xp += 1; // dummy xp amount
            // set experience, http://minecraft.gamepedia.com/Experience%23Leveling_up
            try io.writeFloat(res_writer, @as(f32, @floatFromInt(@mod(player.xp, 10))) / 10.0); // xp bar (0.0-1.0)
            try io.writeVarInt(res_writer, @divFloor(player.xp, 10)); // level
            try io.writeVarInt(res_writer, player.xp); // total xp
            try io.writePacket(tcp_writer, 0x40, res_writer.buffered());
            _ = res_writer.consumeAll();

            // spawn item entity
            const eid = std.crypto.random.int(i32);
            try io.writeVarInt(res_writer, eid); // entity id
            try io.writeUUID(res_writer, std.crypto.random.int(u128)); // entity uuid
            try io.writeByte(res_writer, 2); // type
            try io.writeDouble(res_writer, @as(f64, @floatFromInt(x)) + 0.5); // x
            try io.writeDouble(res_writer, @as(f64, @floatFromInt(y)) + 0.5); // y
            try io.writeDouble(res_writer, @as(f64, @floatFromInt(z)) + 0.5); // z
            try io.writeByte(res_writer, 0); // pitch
            try io.writeByte(res_writer, 0); // yaw
            try io.writeInt(res_writer, 1); // data
            try io.writeShort(res_writer, 0); // velocity x
            try io.writeShort(res_writer, 0); // velocity y
            try io.writeShort(res_writer, 0); // velocity z
            try io.writePacket(tcp_writer, 0x00, res_writer.buffered());
            _ = res_writer.consumeAll();

            // update item entity metadata, https://c4k3.github.io/wiki.vg/Entities.html#Item
            try io.writeVarInt(res_writer, eid); // entity id
            try io.writeByte(res_writer, 6); // index (slot for items)
            try io.writeVarInt(res_writer, 5); // type (5 for slot)
            try io.writeShort(res_writer, @intFromEnum(block)); // item id
            try io.writeByte(res_writer, 1); // item count
            try io.writeShort(res_writer, 0); // item damage
            try io.writeBytes(res_writer, &[_]u8{0}); // item nbt, 0 for none
            try io.writeByte(res_writer, 0xff); // end of metadata
            try io.writePacket(tcp_writer, 0x3c, res_writer.buffered());
            _ = res_writer.consumeAll();

        }

    } else if (state.* == State.Play and packet_id == 0x1f) {
        // player block placement
        const x, const y, const z = try io.readPosition(req_reader);
        const face = try io.readVarInt(req_reader);
        const hand = try io.readVarInt(req_reader);
        const cursor_x = try io.readFloat(req_reader);
        const cursor_y = try io.readFloat(req_reader);
        const cursor_z = try io.readFloat(req_reader);
        std.log.info("player_block_placement: position ({}, {}, {}), face {}, hand {}, cursor ({}, {}, {})", .{ x, y, z, face, hand, cursor_x, cursor_y, cursor_z });

    } else if (state.* == State.Play and packet_id == 0x1d) {
        // player animation
        const hand = try io.readVarInt(req_reader);
        std.log.info("player_animation: hand {}", .{hand});

        // // jump
        // try io.writeVarInt(res_writer, player.eid); // entity id
        // try io.writeShort(res_writer, 0); // velocity x
        // try io.writeShort(res_writer, 10000); // velocity y
        // try io.writeShort(res_writer, 0); // velocity z
        // try io.writePacket(tcp_writer, 0x3e, res_writer.buffered());
        // _ = res_writer.consumeAll();

    } else if (state.* == State.Play and packet_id == 0x1a) {
        // player slot selection
        const slot = try io.readShort(req_reader);
        std.log.info("player_slot_selection: slot {}", .{slot});

    } else if (state.* == State.Play and packet_id == 0x15) {
        // entity action
        const entity_id = try io.readVarInt(req_reader);
        const action_id = try io.readVarInt(req_reader);
        const jump_boost = try io.readVarInt(req_reader);
        std.log.info("entity_action: entity_id {}, action_id {}, jump_boost {}", .{ entity_id, action_id, jump_boost });

    } else {
        std.log.warn("unknown packet id 0x{x:0>2} in state {s}", .{ packet_id, @tagName(state.*) });
    }
}

fn setState(state: *State, newState: State) void {
    std.log.info("State change: {s} -> {s}", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}
