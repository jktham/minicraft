const std = @import("std");
const data = @import("data.zig");
const player = @import("player.zig");
const world = @import("world.zig");
const entities = @import("entities.zig");
const utils = @import("utils.zig");
const inventory = @import("inventory.zig");

// 1.12.2 protocol: https://minecraft.wiki/w/Protocol?oldid=2772385, https://c4k3.github.io/wiki.vg/Protocol.html
// 1.12.2 block/item/entity ids: https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening

const State = enum {
    Handshaking,
    Status,
    Login,
    Play,
};

pub fn startServer(io: std.Io, gpa: std.mem.Allocator) !void {
    const in = try std.Io.net.Ip4Address.parse("0.0.0.0", 25565);
    const address = std.Io.net.IpAddress{ .ip4 = in };
    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);

    try world.generate();

    std.log.info("Listening on {f}", .{server.socket.address});
    while (true) {
        const client = try server.accept(io);
        handleClient(io, gpa, client) catch |err| {
            if (err == error.EndOfStream) {
                std.log.info("Client disconnected: {f}", .{client.socket.address});
                continue;
            }
            std.log.err("Error reading packet: {}", .{err});
            continue;
        };
    }
}

fn handleClient(io: std.Io, gpa: std.mem.Allocator, client: std.Io.net.Stream) !void {
    std.log.info("Client connected: {f}", .{client.socket.address});
    defer client.close(io);

    var read_buf: [10000]u8 = undefined;
    var r = client.reader(io, &read_buf);
    const tcp_reader: *std.Io.Reader = &r.interface;

    var write_buf: [10000]u8 = undefined;
    var w = client.writer(io, &write_buf);
    const tcp_writer: *std.Io.Writer = &w.interface;
    
    var state: State = State.Handshaking;
    var lastUpdate: i64 = utils.getTime(io);
    var lastKeepAlive: i64 = utils.getTime(io);

    while (true) {
        try updateNetwork(io, gpa, tcp_reader, tcp_writer, &state);
        try updateFixed(io, gpa, tcp_writer, &state, &lastUpdate, &lastKeepAlive);
    }
}

/// on receiving a packet, update server state and send responses as needed \
/// TODO: fix blocking behavior when no more tcp packets to read from socket
fn updateNetwork(io: std.Io, gpa: std.mem.Allocator, tcp_reader: *std.Io.Reader, tcp_writer: *std.Io.Writer, state: *State) !void {
    const packet_id, const packet_data = try data.readPacket(gpa, tcp_reader);
    try processPacket(io, gpa, tcp_writer, state, packet_id, packet_data);
}

fn processPacket(io: std.Io, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *State, packet_id: u8, req_data: []const u8) !void {
    var r = std.Io.Reader.fixed(req_data);
    const req_reader = &r;

    var res_data: [10000000]u8 = undefined;
    var w = std.Io.Writer.fixed(&res_data);
    const res_writer = &w;

    const time = utils.getTime(io);

    if (state.* == State.Handshaking and packet_id == 0x00) {
        // handshake request
        const protocol_version = try data.readVarInt(req_reader);
        const server_address = try data.readString(req_reader);
        const server_port = try data.readShort(req_reader);
        const intent = try data.readVarInt(req_reader);
        std.log.info("handshake: protocol_version {d}, server_address {s}, server_port {d}, intent {d}", .{ protocol_version, server_address, server_port, intent });

        if (intent == 1) {
            setState(state, State.Status);
        } else if (intent == 2) {
            setState(state, State.Login);
        }

    } else if (state.* == State.Status and packet_id == 0x00) {
        // status request
        std.log.info("status_request", .{});
        const status = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, "res/status.json", gpa, std.Io.Limit.unlimited);
        defer gpa.free(status);

        // status response
        try data.writeString(res_writer, status);
        try data.writePacket(gpa, tcp_writer, 0x00, res_writer.buffered());
        _ = res_writer.consumeAll();

    } else if (state.* == State.Status and packet_id == 0x01) {
        // ping request
        const timestamp = try data.readLong(req_reader);
        std.log.info("ping_request: timestamp {d}", .{timestamp});

        player.ping = @truncate((time - timestamp) * 2);

        // pong response
        try data.writeLong(res_writer, timestamp);
        try data.writePacket(gpa, tcp_writer, 0x01, res_writer.buffered());
        _ = res_writer.consumeAll();

    } else if (state.* == State.Login and packet_id == 0x00) {
        // hello request
        const name = try data.readString(req_reader);
        std.log.info("hello: name {s}", .{name});

        player.name = name;
        player.uuid = 0xf81d4fae7dec11d0a76500a0c91e6bf6; // dummy uuid
        // login success response (skip encryption)
        try data.writeString(res_writer, try data.UUIDtoString(gpa, player.uuid.?)); // uuid as string
        try data.writeString(res_writer, player.name.?); // username
        try data.writePacket(gpa, tcp_writer, 0x02, res_writer.buffered());
        _ = res_writer.consumeAll();

        setState(state, State.Play);

        // // disconnect
        // try io.writeString(res_writer, "{\"text\": \">:)\"}");
        // try io.writePacket(tcp_writer, 0x1A, res_writer.buffered());
        // _ = res_writer.consumeAll();

        // set spawn position (doesnt work idk)
        try data.writePosition(res_writer, 0, 64, 0); // x, y, z
        try data.writePacket(gpa, tcp_writer, 0x46, res_writer.buffered());
        _ = res_writer.consumeAll();

        // join game
        player.eid = 0xbeef; // dummy entity id
        player.gamemode = 0; // 0=survival, 1=creative
        try data.writeInt(res_writer, player.eid.?); // entity id
        try data.writeByte(res_writer, player.gamemode.?); // gamemode
        try data.writeInt(res_writer, 0); // dimension
        try data.writeByte(res_writer, 2); // difficulty
        try data.writeByte(res_writer, 0); // max players
        try data.writeString(res_writer, "default"); // level type
        try data.writeBool(res_writer, false); // reduced debug info
        try data.writePacket(gpa, tcp_writer, 0x23, res_writer.buffered());
        _ = res_writer.consumeAll();

        // set slot
        try data.writeByte(res_writer, 0); // window id (0 for player inventory)
        try data.writeShort(res_writer, 36); // slot id, (36-44 for hotbar)
        try data.writeSlot(res_writer, .{ .id = inventory.Item.IronPickaxe, .count = 1, .damage = 0, .nbt = &[_]u8{0} });
        try data.writePacket(gpa, tcp_writer, 0x16, res_writer.buffered());
        _ = res_writer.consumeAll();

        // update player list
        try data.writeVarInt(res_writer, 0); // action: add
        try data.writeVarInt(res_writer, 1); // number of players
        try data.writeUUID(res_writer, player.uuid.?); // player uuid
        try data.writeString(res_writer, player.name.?); // player name
        try data.writeVarInt(res_writer, 0); // properties
        try data.writeVarInt(res_writer, player.gamemode.?); // gamemode
        try data.writeVarInt(res_writer, player.ping orelse 0); // ping
        try data.writeBool(res_writer, false); // has display name
        try data.writePacket(gpa, tcp_writer, 0x2e, res_writer.buffered());
        _ = res_writer.consumeAll();

        // update client position (ends loading screen)
        const center = @as(f32, world.N_CHUNKS * world.N_BLOCKS) / 2.0;
        if (player.position == null and player.look == null) {
            player.position = [3]f64{ center, 20, center };
            player.look = [2]f32{ 0, 0 };
        }
        try data.writeDouble(res_writer, player.position.?[0]); // x
        try data.writeDouble(res_writer, player.position.?[1]); // y
        try data.writeDouble(res_writer, player.position.?[2]); // z
        try data.writeFloat(res_writer, player.look.?[0]); // yaw
        try data.writeFloat(res_writer, player.look.?[1]); // pitch
        try data.writeByte(res_writer, 0b00000000); // flags (relative)
        try data.writeVarInt(res_writer, @truncate(time & 0x7FFFFFFF)); // teleport id
        try data.writePacket(gpa, tcp_writer, 0x2f, res_writer.buffered());
        _ = res_writer.consumeAll();

        // chunk data
        std.log.info("chunk_data", .{});
        for (0..world.N_CHUNKS) |chunk_x| {
            for (0..world.N_CHUNKS) |chunk_z| {
                var chunk_data: [10000000]u8 = undefined;
                var cw = std.Io.Writer.fixed(&chunk_data);
                const chunk_writer = &cw;

                for (0..world.N_SUBCHUNKS) |chunk_y| {
                    try data.writeByte(chunk_writer, 8); // bits per block
                    try data.writeVarInt(chunk_writer, world.palette.len); // palette length
                    for (world.palette) |p| {
                        try data.writeVarInt(chunk_writer, p); // palette entry
                    }
                    try data.writeVarInt(chunk_writer, (4096 * 8) / 64); // data length (number of longs)
                    try data.writeBytes(chunk_writer, try world.getChunkPointer(@intCast(chunk_x), @intCast(chunk_y), @intCast(chunk_z))); // block data (4096 blocks per subchunk)
                    try data.writeBytes(chunk_writer, &[_]u8{0xff} ** 2048); // block light (4 bits per block)
                    try data.writeBytes(chunk_writer, &[_]u8{0xff} ** 2048); // sky light (4 bits per block)
                }

                try data.writeInt(res_writer, @as(i32, @intCast(chunk_x))); // chunk x
                try data.writeInt(res_writer, @as(i32, @intCast(chunk_z))); // chunk z
                try data.writeBool(res_writer, true); // ground up continuous
                try data.writeVarInt(res_writer, 0xffff); // primary bit mask
                try data.writeVarInt(res_writer, @intCast(chunk_writer.buffered().len + 256)); // data length
                try data.writeBytes(res_writer, chunk_writer.buffered()); // data
                try data.writeBytes(res_writer, &[_]u8{127} ** 256); // biomes
                try data.writeVarInt(res_writer, 0); // number of block entities
                try data.writePacket(gpa, tcp_writer, 0x20, res_writer.buffered());
                _ = res_writer.consumeAll();
            }
        }

    } else if (state.* == State.Play and packet_id == 0x04) {
        // client settings
        const locale = try data.readString(req_reader);
        const view_distance = try data.readByte(req_reader);
        const chat_mode = try data.readVarInt(req_reader);
        const chat_colors = try data.readBool(req_reader);
        const skin_parts = try data.readByte(req_reader);
        const main_hand = try data.readVarInt(req_reader);
        std.log.info("client_settings: locale {s}, view_distance {d}, chat_mode {d}, chat_colors {}, skin_parts {d}, main_hand {d}", .{ locale, view_distance, chat_mode, chat_colors, skin_parts, main_hand });

    } else if (state.* == State.Play and packet_id == 0x09) {
        // plugin message
        const channel = try data.readString(req_reader);
        const payload = try req_reader.allocRemaining(gpa, std.Io.Limit.unlimited); // unknown size
        defer gpa.free(payload);
        std.log.info("plugin_message: channel {s}, payload 0x{x} ({s})", .{ channel, payload, try data.sanitizeString(gpa, payload) });

    } else if (state.* == State.Play and packet_id == 0x0c) {
        // player update
        const on_ground = try data.readBool(req_reader);
        std.log.info("player_update: on_ground {}", .{ on_ground });

    } else if (state.* == State.Play and packet_id == 0x0d) {
        // position update
        const x = try data.readDouble(req_reader);
        const y = try data.readDouble(req_reader);
        const z = try data.readDouble(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("position_update: position ({}, {}, {}), on_ground {}", .{ x, y, z, on_ground });

        player.position = [3]f64{ x, y, z };

    } else if (state.* == State.Play and packet_id == 0x0e) {
        // position and look update
        const x = try data.readDouble(req_reader);
        const y = try data.readDouble(req_reader);
        const z = try data.readDouble(req_reader);
        const yaw = try data.readFloat(req_reader);
        const pitch = try data.readFloat(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("position_look_update: position ({}, {}, {}), yaw {}, pitch {}, on_ground {}", .{ x, y, z, yaw, pitch, on_ground });

        player.position = [3]f64{ x, y, z };
        player.look = [2]f32{ yaw, pitch };

    } else if (state.* == State.Play and packet_id == 0x0f) {
        // look update
        const yaw = try data.readFloat(req_reader);
        const pitch = try data.readFloat(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("look_update: yaw {}, pitch {}, on_ground {}", .{ yaw, pitch, on_ground });

        player.look = [2]f32{ yaw, pitch };

    } else if (state.* == State.Play and packet_id == 0x00) {
        // teleport confirm
        const teleport_id = try data.readVarInt(req_reader);
        std.log.info("teleport_confirm: id {}", .{teleport_id});

    } else if (state.* == State.Play and packet_id == 0x0b) {
        // keep alive
        const id = try data.readLong(req_reader);
        std.log.info("keep_alive: id {}", .{id});

    } else if (state.* == State.Play and packet_id == 0x14) {
        // player digging
        const status = try data.readVarInt(req_reader);
        const x, const y, const z = try data.readPosition(req_reader);
        const face = try data.readByte(req_reader);
        std.log.info("player_digging: status {}, position ({}, {}, {}), face {}", .{ status, x, y, z, face });

        if (player.gamemode == 1 and status == 0 or player.gamemode == 0 and status == 2) {
            // finish digging, set block to air
            const block = try world.getBlock(@intCast(x), @intCast(y), @intCast(z));
            try world.setBlock(@intCast(x), @intCast(y), @intCast(z), world.Block.Air);

            // // spawn xp orb
            // try io.writeVarInt(res_writer, entities.randomEID()); // entity id
            // try io.writeDouble(res_writer, @floatFromInt(x)); // x
            // try io.writeDouble(res_writer, @floatFromInt(y)); // y
            // try io.writeDouble(res_writer, @floatFromInt(z)); // z
            // try io.writeShort(res_writer, 10); // count
            // try io.writePacket(tcp_writer, 0x01, res_writer.buffered());
            // _ = res_writer.consumeAll();

            if (player.xp == null) {
                player.xp = 0;
            }
            player.xp.? += 1; // dummy xp amount
            // set experience, http://minecraft.gamepedia.com/Experience%23Leveling_up
            try data.writeFloat(res_writer, @as(f32, @floatFromInt(@mod(player.xp.?, 10))) / 10.0); // xp bar (0.0-1.0)
            try data.writeVarInt(res_writer, @divFloor(player.xp.?, 10)); // level
            try data.writeVarInt(res_writer, player.xp.?); // total xp
            try data.writePacket(gpa, tcp_writer, 0x40, res_writer.buffered());
            _ = res_writer.consumeAll();

            // spawn item entity
            const eid = entities.randomEID();
            const uuid = entities.randomUUID();
            const position = [3]f64{ @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5, @as(f64, @floatFromInt(z)) + 0.5 };
            try data.writeVarInt(res_writer, eid); // entity id
            try data.writeUUID(res_writer, uuid); // entity uuid
            try data.writeByte(res_writer, 2); // type
            try data.writeDouble(res_writer, position[0]); // x
            try data.writeDouble(res_writer, position[1]); // y
            try data.writeDouble(res_writer, position[2]); // z
            try data.writeByte(res_writer, 0); // pitch
            try data.writeByte(res_writer, 0); // yaw
            try data.writeInt(res_writer, 1); // data
            try data.writeShort(res_writer, 0); // velocity x
            try data.writeShort(res_writer, 0); // velocity y
            try data.writeShort(res_writer, 0); // velocity z
            try data.writePacket(gpa, tcp_writer, 0x00, res_writer.buffered());
            _ = res_writer.consumeAll();

            // update item entity metadata, https://c4k3.github.io/wiki.vg/Entities.html#Item
            const slot = inventory.Slot{
                .id = inventory.blockToItem(block),
                .count = 1,
                .damage = 0,
                .nbt = &[_]u8{0},
            };
            try entities.spawnItem(gpa, eid, uuid, position, slot);

            try data.writeVarInt(res_writer, eid); // entity id
            try data.writeByte(res_writer, 6); // index (slot for items)
            try data.writeVarInt(res_writer, 5); // type (5 for slot)
            try data.writeSlot(res_writer, slot);
            try data.writeByte(res_writer, 0xff); // end of metadata
            try data.writePacket(gpa, tcp_writer, 0x3c, res_writer.buffered());
            _ = res_writer.consumeAll();

        }

    } else if (state.* == State.Play and packet_id == 0x1f) {
        // player block placement
        const x, const y, const z = try data.readPosition(req_reader);
        const face = try data.readVarInt(req_reader);
        const hand = try data.readVarInt(req_reader);
        const cursor_x = try data.readFloat(req_reader);
        const cursor_y = try data.readFloat(req_reader);
        const cursor_z = try data.readFloat(req_reader);
        std.log.info("player_block_placement: position ({}, {}, {}), face {}, hand {}, cursor ({}, {}, {})", .{ x, y, z, face, hand, cursor_x, cursor_y, cursor_z });

    } else if (state.* == State.Play and packet_id == 0x1d) {
        // player animation
        const hand = try data.readVarInt(req_reader);
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
        const slot = try data.readShort(req_reader);
        std.log.info("player_slot_selection: slot {}", .{slot});

    } else if (state.* == State.Play and packet_id == 0x15) {
        // entity action
        const entity_id = try data.readVarInt(req_reader);
        const action_id = try data.readVarInt(req_reader);
        const jump_boost = try data.readVarInt(req_reader);
        std.log.info("entity_action: entity_id {}, action_id {}, jump_boost {}", .{ entity_id, action_id, jump_boost });

    } else {
        std.log.warn("unknown packet id 0x{x:0>2} in state {s}", .{ packet_id, @tagName(state.*) });
    }
}

/// once per tick, update server state and send data to client
fn updateFixed(io: std.Io, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *State, lastUpdate: *i64, lastKeepAlive: *i64) !void {
    var res_data: [10000000]u8 = undefined;
    var w = std.Io.Writer.fixed(&res_data);
    const res_writer = &w;

    const time = utils.getTime(io);
    const delta = time - lastUpdate.*;
    lastUpdate.* = time;
    std.log.debug("updateFixed: delta {d} ms", .{delta});

    if (state.* == State.Play and time - lastKeepAlive.* > 10000) {
        // keep alive
        lastKeepAlive.* = time;
        try data.writeLong(res_writer, time); // id
        try data.writePacket(gpa, tcp_writer, 0x1f, res_writer.buffered());
        _ = res_writer.consumeAll();
        std.log.info("Sent keep alive", .{});
    }

    // collect nearby items
    if (state.* == State.Play and player.position != null and player.eid != null) {
        const close_items = try entities.getCloseItems(gpa, player.position.?, 1.0);
        for (close_items) |item| {
            // collect item
            try data.writeVarInt(res_writer, item.eid); // collected
            try data.writeVarInt(res_writer, player.eid.?); // collector
            try data.writeVarInt(res_writer, item.slot.count); // count
            try data.writePacket(gpa, tcp_writer, 0x4b, res_writer.buffered());
            _ = res_writer.consumeAll();

            // set slot
            try data.writeByte(res_writer, 0); // window id (0 for player inventory)
            try data.writeShort(res_writer, 37); // slot id, (36-44 for hotbar)
            try data.writeSlot(res_writer, item.slot); // item data
            try data.writePacket(gpa, tcp_writer, 0x16, res_writer.buffered());
            _ = res_writer.consumeAll();

            // destroy item entity
            try data.writeVarInt(res_writer, 1); // count
            try data.writeVarInt(res_writer, item.eid); // entity id
            try data.writePacket(gpa, tcp_writer, 0x32, res_writer.buffered());
            _ = res_writer.consumeAll();

            try entities.destroyItem(item.eid);
        }
    }
}

fn setState(state: *State, newState: State) void {
    std.log.info("State change: {s} -> {s}", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}
