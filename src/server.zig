const std = @import("std");

const _game = @import("game.zig");
const data = @import("data.zig");
const entities = @import("entities.zig");
const inventory = @import("inventory.zig");
const utils = @import("utils.zig");
const world = @import("world.zig");

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

    var game = _game.Game.init();
    try game.world.generate();

    std.log.info("Listening on {f}", .{server.socket.address});
    while (true) {
        const client = try server.accept(io);
        clientConnect(io, gpa, client, &game) catch |err| {
            if (err == error.EndOfStream) {
                std.log.info("Client disconnected: {f}", .{client.socket.address});
                continue;
            }
            std.log.err("Error reading packet: {}", .{err});
            continue;
        };
    }
}

fn clientConnect(io: std.Io, gpa: std.mem.Allocator, client: std.Io.net.Stream, game: *_game.Game) !void {
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
        const packet = try receivePacket(gpa, tcp_reader, state); // TODO: fix blocking behavior when no more tcp packets to read from socket
        try updateNetwork(io, gpa, tcp_writer, game, &state, packet);
        try updateFixed(io, gpa, tcp_writer, game, &state, &lastUpdate, &lastKeepAlive);
    }
}

/// on receiving a packet, update server state and send responses as needed
fn updateNetwork(io: std.Io, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, game: *_game.Game, state: *State, packet: data.Packet) !void {
    var r = std.Io.Reader.fixed(packet.data);
    const req_reader = &r;

    var res_data: [10000000]u8 = undefined;
    var w = std.Io.Writer.fixed(&res_data);
    const res_writer = &w;

    const time = utils.getTime(io);

    if (state.* == State.Handshaking and packet.id == 0x00) {
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
    } else if (state.* == State.Status and packet.id == 0x00) {
        // status request
        std.log.info("status_request", .{});
        const status = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, "res/status.json", gpa, std.Io.Limit.unlimited);
        defer gpa.free(status);

        // status response
        try data.writeString(res_writer, status);
        try sendPacket(gpa, tcp_writer, .{ .id = 0x00, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    } else if (state.* == State.Status and packet.id == 0x01) {
        // ping request
        const timestamp = try data.readLong(req_reader);
        std.log.info("ping_request: timestamp {d}", .{timestamp});

        game.player.ping = @truncate((time - timestamp) * 2);

        // pong response
        try data.writeLong(res_writer, timestamp);
        try sendPacket(gpa, tcp_writer, .{ .id = 0x01, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    } else if (state.* == State.Login and packet.id == 0x00) {
        // hello request
        const name = try data.readString(req_reader);
        std.log.info("hello: name {s}", .{name});

        game.player.name = try gpa.dupe(u8, name); // reallocate to keep persistent
        game.player.uuid = 0xf81d4fae7dec11d0a76500a0c91e6bf6; // dummy uuid
        // login success response (skip encryption)
        const uuid_str = try data.UUIDtoString(gpa, game.player.uuid);
        defer gpa.free(uuid_str);
        try data.writeString(res_writer, uuid_str); // uuid as string
        try data.writeString(res_writer, game.player.name); // username
        try sendPacket(gpa, tcp_writer, .{ .id = 0x02, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        setState(state, State.Play);

        // // disconnect
        // try io.writeString(res_writer, "{\"text\": \">:)\"}");
        // try io.writePacket(tcp_writer, 0x1A, res_writer.buffered());
        // _ = res_writer.consumeAll();

        // set spawn position (doesnt work idk)
        try data.writePosition(res_writer, .{ .x = 0, .y = 64, .z = 0 }); // x, y, z
        try sendPacket(gpa, tcp_writer, .{ .id = 0x46, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        // join game
        game.player.eid = 0xbeef; // dummy entity id
        game.player.gamemode = 0; // 0=survival, 1=creative
        try data.writeInt(res_writer, game.player.eid); // entity id
        try data.writeByte(res_writer, game.player.gamemode); // gamemode
        try data.writeInt(res_writer, 0); // dimension
        try data.writeByte(res_writer, 2); // difficulty
        try data.writeByte(res_writer, 0); // max players
        try data.writeString(res_writer, "default"); // level type
        try data.writeBool(res_writer, false); // reduced debug info
        try sendPacket(gpa, tcp_writer, .{ .id = 0x23, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        game.player.inventory.slots[36] = inventory.Stack{
            .id = inventory.Item.IronPickaxe,
            .count = 99,
            .damage = 0,
            .nbt = &[_]u8{0},
        };
        // set full inventory
        for (0..inventory.N_SLOTS) |i| {
            try data.writeByte(res_writer, 0); // window id (0 for player inventory)
            try data.writeShort(res_writer, @intCast(i)); // slot id
            try data.writeStack(res_writer, game.player.inventory.slots[i]); // slot data
            try sendPacket(gpa, tcp_writer, .{ .id = 0x16, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
            game.player.inventory.changed[i] = false; // reset changed status after sending initial inventory
        }

        // set experience
        try data.writeFloat(res_writer, @as(f32, @floatFromInt(@mod(game.player.xp, 10))) / 10.0); // xp bar (0.0-1.0)
        try data.writeVarInt(res_writer, @divFloor(game.player.xp, 10)); // level
        try data.writeVarInt(res_writer, game.player.xp); // total xp
        try sendPacket(gpa, tcp_writer, .{ .id = 0x40, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        // update player list
        try data.writeVarInt(res_writer, 0); // action: add
        try data.writeVarInt(res_writer, 1); // number of players
        try data.writeUUID(res_writer, game.player.uuid); // player uuid
        try data.writeString(res_writer, game.player.name); // player name
        try data.writeVarInt(res_writer, 0); // properties
        try data.writeVarInt(res_writer, game.player.gamemode); // gamemode
        try data.writeVarInt(res_writer, game.player.ping); // ping
        try data.writeBool(res_writer, false); // has display name
        try sendPacket(gpa, tcp_writer, .{ .id = 0x2e, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        // update client position (ends loading screen)
        if (std.meta.eql(game.player.position, entities.fPos{ .x = 0, .y = 0, .z = 0 })) { // ideally only on initial join
            const center = @as(f32, world.N_CHUNKS * world.N_BLOCKS) / 2.0;
            game.player.position = entities.fPos{ .x = center, .y = 20, .z = center };
            game.player.look = [2]f32{ 0, 0 };
        }
        try data.writeDouble(res_writer, game.player.position.x); // x
        try data.writeDouble(res_writer, game.player.position.y); // y
        try data.writeDouble(res_writer, game.player.position.z); // z
        try data.writeFloat(res_writer, game.player.look[0]); // yaw
        try data.writeFloat(res_writer, game.player.look[1]); // pitch
        try data.writeByte(res_writer, 0b00000000); // flags (relative)
        try data.writeVarInt(res_writer, @truncate(time & 0x7FFFFFFF)); // teleport id
        try sendPacket(gpa, tcp_writer, .{ .id = 0x2f, .data = res_writer.buffered() }, state.*);
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
                    try data.writeBytes(chunk_writer, try game.world.getChunkPointer(@intCast(chunk_x), @intCast(chunk_y), @intCast(chunk_z))); // block data (4096 blocks per subchunk)
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
                try sendPacket(gpa, tcp_writer, .{ .id = 0x20, .data = res_writer.buffered() }, state.*);
                _ = res_writer.consumeAll();
            }
        }
    } else if (state.* == State.Play and packet.id == 0x04) {
        // client settings
        const locale = try data.readString(req_reader);
        const view_distance = try data.readByte(req_reader);
        const chat_mode = try data.readVarInt(req_reader);
        const chat_colors = try data.readBool(req_reader);
        const skin_parts = try data.readByte(req_reader);
        const main_hand = try data.readVarInt(req_reader);
        std.log.info("client_settings: locale {s}, view_distance {d}, chat_mode {d}, chat_colors {}, skin_parts {d}, main_hand {d}", .{ locale, view_distance, chat_mode, chat_colors, skin_parts, main_hand });
    } else if (state.* == State.Play and packet.id == 0x09) {
        // plugin message
        const channel = try data.readString(req_reader);
        const payload = try req_reader.allocRemaining(gpa, std.Io.Limit.unlimited); // unknown size
        defer gpa.free(payload);
        std.log.info("plugin_message: channel {s}, payload 0x{x} ({s})", .{ channel, payload, try utils.sanitizeString(gpa, payload) });
    } else if (state.* == State.Play and packet.id == 0x0c) {
        // player update
        const on_ground = try data.readBool(req_reader);
        std.log.info("player_update: on_ground {}", .{on_ground});
    } else if (state.* == State.Play and packet.id == 0x0d) {
        // position update
        const x = try data.readDouble(req_reader);
        const y = try data.readDouble(req_reader);
        const z = try data.readDouble(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("position_update: position ({}, {}, {}), on_ground {}", .{ x, y, z, on_ground });

        game.player.position = entities.fPos{ .x = x, .y = y, .z = z };
    } else if (state.* == State.Play and packet.id == 0x0e) {
        // position and look update
        const x = try data.readDouble(req_reader);
        const y = try data.readDouble(req_reader);
        const z = try data.readDouble(req_reader);
        const yaw = try data.readFloat(req_reader);
        const pitch = try data.readFloat(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("position_look_update: position ({}, {}, {}), yaw {}, pitch {}, on_ground {}", .{ x, y, z, yaw, pitch, on_ground });

        game.player.position = entities.fPos{ .x = x, .y = y, .z = z };
        game.player.look = [2]f32{ yaw, pitch };
    } else if (state.* == State.Play and packet.id == 0x0f) {
        // look update
        const yaw = try data.readFloat(req_reader);
        const pitch = try data.readFloat(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("look_update: yaw {}, pitch {}, on_ground {}", .{ yaw, pitch, on_ground });

        game.player.look = [2]f32{ yaw, pitch };
    } else if (state.* == State.Play and packet.id == 0x00) {
        // teleport confirm
        const teleport_id = try data.readVarInt(req_reader);
        std.log.info("teleport_confirm: id {}", .{teleport_id});
    } else if (state.* == State.Play and packet.id == 0x0b) {
        // keep alive
        const id = try data.readLong(req_reader);
        std.log.info("keep_alive: id {}", .{id});
    } else if (state.* == State.Play and packet.id == 0x14) {
        // player digging
        const status = try data.readVarInt(req_reader);
        const pos = try data.readPosition(req_reader);
        const face = try data.readByte(req_reader);
        std.log.info("player_digging: status {}, position ({}, {}, {}), face {}", .{ status, pos.x, pos.y, pos.z, face });

        if (game.player.gamemode == 1 and status == 0 or game.player.gamemode == 0 and status == 2) { // TODO: saplings are broken without sending end digging
            // finish digging, set block to air
            const block = try game.world.getBlock(@intCast(pos.x), @intCast(pos.y), @intCast(pos.z));
            std.log.info("Breaking block {} at ({}, {}, {})", .{ block, pos.x, pos.y, pos.z });
            try game.world.setBlock(@intCast(pos.x), @intCast(pos.y), @intCast(pos.z), world.Block.Air);

            // block change response
            try data.writePosition(res_writer, pos); // position
            try data.writeVarInt(res_writer, world.palette[@intFromEnum(world.Block.Air)]); // block id
            try sendPacket(gpa, tcp_writer, .{ .id = 0x0B, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();

            // // spawn xp orb
            // try io.writeVarInt(res_writer, entities.randomEID()); // entity id
            // try io.writeDouble(res_writer, @floatFromInt(pos.x)); // x
            // try io.writeDouble(res_writer, @floatFromInt(pos.y)); // y
            // try io.writeDouble(res_writer, @floatFromInt(pos.z)); // z
            // try io.writeShort(res_writer, 10); // count
            // try io.writePacket(tcp_writer, 0x01, res_writer.buffered());
            // _ = res_writer.consumeAll();

            game.player.xp += 1; // dummy xp amount
            // set experience, http://minecraft.gamepedia.com/Experience%23Leveling_up
            try data.writeFloat(res_writer, @as(f32, @floatFromInt(@mod(game.player.xp, 10))) / 10.0); // xp bar (0.0-1.0)
            try data.writeVarInt(res_writer, @divFloor(game.player.xp, 10)); // level
            try data.writeVarInt(res_writer, game.player.xp); // total xp
            try sendPacket(gpa, tcp_writer, .{ .id = 0x40, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();

            // spawn item entity
            const eid = entities.randomEID();
            const uuid = entities.randomUUID();
            const fpos = entities.fPos{
                .x = @as(f32, @floatFromInt(pos.x)) + 0.5,
                .y = @as(f32, @floatFromInt(pos.y)) + 0.5,
                .z = @as(f32, @floatFromInt(pos.z)) + 0.5,
            };
            try data.writeVarInt(res_writer, eid); // entity id
            try data.writeUUID(res_writer, uuid); // entity uuid
            try data.writeByte(res_writer, 2); // type
            try data.writeDouble(res_writer, fpos.x); // x
            try data.writeDouble(res_writer, fpos.y); // y
            try data.writeDouble(res_writer, fpos.z); // z
            try data.writeByte(res_writer, 0); // pitch
            try data.writeByte(res_writer, 0); // yaw
            try data.writeInt(res_writer, 1); // data
            try data.writeShort(res_writer, 0); // velocity x
            try data.writeShort(res_writer, 0); // velocity y
            try data.writeShort(res_writer, 0); // velocity z
            try sendPacket(gpa, tcp_writer, .{ .id = 0x00, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();

            // update item entity metadata, https://c4k3.github.io/wiki.vg/Entities.html#Item
            const stack = inventory.Stack{
                .id = inventory.blockToItem(block),
                .count = 1,
                .damage = 0,
                .nbt = &[_]u8{0},
            };
            try game.entities.spawnItem(gpa, eid, uuid, fpos, stack);

            try data.writeVarInt(res_writer, eid); // entity id
            try data.writeByte(res_writer, 6); // index (slot for items)
            try data.writeVarInt(res_writer, 5); // type (5 for slot)
            try data.writeStack(res_writer, stack);
            try data.writeByte(res_writer, 0xff); // end of metadata
            try sendPacket(gpa, tcp_writer, .{ .id = 0x3c, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
        }
    } else if (state.* == State.Play and packet.id == 0x1f) {
        // player block placement
        const pos = try data.readPosition(req_reader);
        const face = try data.readVarInt(req_reader);
        const hand = try data.readVarInt(req_reader);
        const cursor_x = try data.readFloat(req_reader);
        const cursor_y = try data.readFloat(req_reader);
        const cursor_z = try data.readFloat(req_reader);
        std.log.info("player_block_placement: position ({}, {}, {}), face {}, hand {}, cursor ({}, {}, {})", .{ pos.x, pos.y, pos.z, face, hand, cursor_x, cursor_y, cursor_z });

        const slot = 36 + game.player.selected_slot; // TODO: offhand
        const stack = game.player.inventory.slots[slot];
        const block = inventory.itemToBlock(stack.id);
        if (block == world.Block.Air) {
            std.log.warn("Cannot place item {}", .{stack.id});
            return;
        }
        const place_pos = world.applyFaceOffset(pos.x, pos.y, pos.z, face);
        const place_pos_center = entities.fPos{
            .x = @as(f64, @floatFromInt(place_pos.x)) + 0.5,
            .y = @as(f64, @floatFromInt(place_pos.y)) + 0.5,
            .z = @as(f64, @floatFromInt(place_pos.z)) + 0.5,
        };
        if (utils.distance(game.player.position, place_pos_center) > 5.0) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is too far away", .{ place_pos.x, place_pos.y, place_pos.z });
            return;
        }
        // TODO: proper collision check
        if (utils.sameBlock(game.player.position, place_pos_center) or utils.sameBlock(.{ .x = game.player.position.x, .y = game.player.position.y + 1, .z = game.player.position.z }, place_pos_center)) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is blocked by player", .{ place_pos.x, place_pos.y, place_pos.z });
            return;
        }
        const current_block = try game.world.getBlock(place_pos.x, place_pos.y, place_pos.z);
        if (current_block != world.Block.Air) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is occupied by block {}", .{ place_pos.x, place_pos.y, place_pos.z, current_block });
            return;
        }
        game.player.inventory.removeCount(slot, 1) catch |err| {
            if (err == error.NotEnoughItems) {
                std.log.warn("Not enough items in slot {}", .{slot});
                return;
            }
        };
        std.log.info("Placing block {} at ({}, {}, {})", .{ block, place_pos.x, place_pos.y, place_pos.z });
        try game.world.setBlock(place_pos.x, place_pos.y, place_pos.z, block);

        // block change response
        try data.writePosition(res_writer, place_pos); // position
        try data.writeVarInt(res_writer, world.palette[@intFromEnum(block)]); // block id
        try sendPacket(gpa, tcp_writer, .{ .id = 0x0B, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        // set inventory
        try data.writeByte(res_writer, 0); // window id (0 for player inventory)
        try data.writeShort(res_writer, @intCast(slot)); // slot id
        try data.writeStack(res_writer, game.player.inventory.slots[slot]); // slot data
        try sendPacket(gpa, tcp_writer, .{ .id = 0x16, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
        game.player.inventory.changed[slot] = false;
    } else if (state.* == State.Play and packet.id == 0x1d) {
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

    } else if (state.* == State.Play and packet.id == 0x1a) {
        // player slot selection
        const slot = try data.readShort(req_reader);
        std.log.info("player_slot_selection: slot {}", .{slot});
        game.player.selected_slot = @intCast(slot);
    } else if (state.* == State.Play and packet.id == 0x15) {
        // entity action
        const entity_id = try data.readVarInt(req_reader);
        const action_id = try data.readVarInt(req_reader);
        const jump_boost = try data.readVarInt(req_reader);
        std.log.info("entity_action: entity_id 0x{x}, action_id {}, jump_boost {}", .{ entity_id, action_id, jump_boost });
    } else if (state.* == State.Play and packet.id == 0x02) {
        // chat message
        const message = try utils.sanitizeString(gpa, try data.readString(req_reader));
        defer gpa.free(message);
        std.log.info("chat_message: {s}", .{message});

        if (message[0] == '/') {
            // command
            if (std.mem.eql(u8, message, "/ping")) {
                const message_json = try std.fmt.allocPrint(gpa, "{{\"text\": \"ping: {d}\"}}", .{game.player.ping});
                defer gpa.free(message_json);
                try data.writeString(res_writer, message_json);
                try data.writeByte(res_writer, 1); // position (0 for chat, 1 for system message, 2 for above hotbar)
                try sendPacket(gpa, tcp_writer, .{ .id = 0x0f, .data = res_writer.buffered() }, state.*);
                _ = res_writer.consumeAll();
            } else {
                const message_json = try std.fmt.allocPrint(gpa, "{{\"text\": \"Unknown command: {s}\"}}", .{message});
                defer gpa.free(message_json);
                try data.writeString(res_writer, message_json);
                try data.writeByte(res_writer, 1); // position (0 for chat, 1 for system message, 2 for above hotbar)
                try sendPacket(gpa, tcp_writer, .{ .id = 0x0f, .data = res_writer.buffered() }, state.*);
                _ = res_writer.consumeAll();
            }
        } else {
            // chat message clientbound
            const message_json = try std.fmt.allocPrint(gpa, "{{\"text\": \"{s}: {s}\"}}", .{ game.player.name, message });
            defer gpa.free(message_json);
            try data.writeString(res_writer, message_json);
            try data.writeByte(res_writer, 0); // position (0 for chat, 1 for system message, 2 for above hotbar)
            try sendPacket(gpa, tcp_writer, .{ .id = 0x0f, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
        }
    } else {
        std.log.warn("Unknown packet id 0x{x:0>2} in state {s}", .{ packet.id, @tagName(state.*) });
    }
}

/// once per tick, update server state and send data to client
fn updateFixed(io: std.Io, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, game: *_game.Game, state: *State, lastUpdate: *i64, lastKeepAlive: *i64) !void {
    var res_data: [10000000]u8 = undefined;
    var w = std.Io.Writer.fixed(&res_data);
    const res_writer = &w;

    const time = utils.getTime(io);
    const delta = time - lastUpdate.*;
    lastUpdate.* = time;
    _ = delta;

    if (state.* == State.Play and time - lastKeepAlive.* > 10000) {
        // keep alive
        lastKeepAlive.* = time;
        try data.writeLong(res_writer, time); // id
        try sendPacket(gpa, tcp_writer, .{ .id = 0x1f, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
        std.log.info("Sent keep alive", .{});
    }

    // collect nearby items
    if (state.* == State.Play) {
        const close_items = try game.entities.getCloseItems(gpa, .{ .x = game.player.position.x, .y = game.player.position.y + 1.0, .z = game.player.position.z }, 1.2);
        for (close_items) |item| {
            game.player.inventory.addStack(item.stack) catch |err| {
                if (err == error.InventoryFull) {
                    std.log.warn("Inventory full, cannot pick up item with eid 0x{x}", .{item.eid});
                    continue;
                }
            };

            // collect item
            try data.writeVarInt(res_writer, item.eid); // collected
            try data.writeVarInt(res_writer, game.player.eid); // collector
            try data.writeVarInt(res_writer, item.stack.count); // count
            try sendPacket(gpa, tcp_writer, .{ .id = 0x4b, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();

            // set inventory
            for (0..inventory.N_SLOTS) |i| {
                if (game.player.inventory.changed[i]) {
                    try data.writeByte(res_writer, 0); // window id (0 for player inventory)
                    try data.writeShort(res_writer, @intCast(i)); // slot id
                    try data.writeStack(res_writer, game.player.inventory.slots[i]); // slot data
                    try sendPacket(gpa, tcp_writer, .{ .id = 0x16, .data = res_writer.buffered() }, state.*);
                    _ = res_writer.consumeAll();
                    game.player.inventory.changed[i] = false;
                }
            }

            // destroy item entity
            try data.writeVarInt(res_writer, 1); // count
            try data.writeVarInt(res_writer, item.eid); // entity id
            try sendPacket(gpa, tcp_writer, .{ .id = 0x32, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();

            try game.entities.destroyItem(item.eid);
        }
    }
}

fn setState(state: *State, newState: State) void {
    std.log.info("State change: {s} -> {s}", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}

/// read packet from tcp, log
fn receivePacket(gpa: std.mem.Allocator, tcp_reader: *std.Io.Reader, state: State) !data.Packet {
    const packet = try data.readPacket(tcp_reader);

    if (packet.data.len > 10000) { // too large to print, stdout slow
        std.log.debug("Received large packet: length {d}, id 0x{x:0>2}/{d}{d}", .{ packet.data.len + 1, packet.id, 0, @intFromEnum(state) });
    } else {
        const str = try utils.sanitizeString(gpa, packet.data);
        defer gpa.free(str);
        std.log.debug("Received packet: length {d}, id 0x{x:0>2}/{d}{d}, data 0x{x} ({s})", .{ packet.data.len + 1, packet.id, 0, @intFromEnum(state), packet.data, str });
    }
    return packet;
}

/// write packet to tcp, flush, log
fn sendPacket(gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, packet: data.Packet, state: State) !void {
    try data.writePacket(tcp_writer, packet);
    try tcp_writer.flush();

    if (packet.data.len > 10000) { // too large to print, stdout slow
        std.log.debug("Sent large packet: length {d}, id 0x{x:0>2}/{d}{d}", .{ packet.data.len + 1, packet.id, 1, @intFromEnum(state) });
    } else {
        const str = try utils.sanitizeString(gpa, packet.data);
        defer gpa.free(str);
        std.log.debug("Sent packet: length {d}, id 0x{x:0>2}/{d}{d}, data 0x{x} ({s})", .{ packet.data.len + 1, packet.id, 1, @intFromEnum(state), packet.data, str });
    }
}
