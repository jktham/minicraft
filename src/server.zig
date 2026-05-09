const std = @import("std");

const _game = @import("game.zig");
const data = @import("data.zig");
const entities = @import("entities.zig");
const inventory = @import("inventory.zig");
const utils = @import("utils.zig");
const world = @import("world.zig");

// 1.12.2 protocol: https://minecraft.wiki/w/Protocol?oldid=2772385, https://c4k3.github.io/wiki.vg/Protocol.html
// 1.12.2 block/item/entity ids: https://minecraft.fandom.com/wiki/Java_Edition_data_values/Pre-flattening

pub const State = enum {
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

    var game = _game.Game.init(gpa);
    defer game.deinit(gpa);
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
    const player_index = 0; // TODO: only supporting 1 player for now, player not registered at this point

    while (true) {
        const packet = try receivePacket(gpa, tcp_reader, state); // TODO: fix blocking behavior when no more tcp packets to read from socket
        try updateNetwork(io, gpa, tcp_writer, game, &state, packet, player_index);
        try updateFixed(io, gpa, tcp_writer, game, &state, &lastUpdate, &lastKeepAlive);
    }
}

/// on receiving a packet, update server state and send responses as needed
fn updateNetwork(io: std.Io, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, game: *_game.Game, state: *State, packet: data.Packet, p: usize) !void {
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
        std.log.info("Got handshake: protocol_version {d}, server_address {s}, server_port {d}, intent {d}", .{ protocol_version, server_address, server_port, intent });

        if (intent == 1) {
            setState(state, State.Status);
        } else if (intent == 2) {
            setState(state, State.Login);
        }
    } else if (state.* == State.Status and packet.id == 0x00) {
        // status request
        std.log.info("Got status_request", .{});

        // status response
        const status = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, "res/status.json", gpa, std.Io.Limit.unlimited);
        defer gpa.free(status);
        try data.writeString(res_writer, status);
        try sendPacket(gpa, tcp_writer, .{ .id = 0x00, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    } else if (state.* == State.Status and packet.id == 0x01) {
        // ping request
        const timestamp = try data.readLong(req_reader);
        std.log.info("Got ping_request: timestamp {d}", .{timestamp});

        // ping response
        try data.writeLong(res_writer, timestamp);
        try sendPacket(gpa, tcp_writer, .{ .id = 0x01, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    } else if (state.* == State.Login and packet.id == 0x00) {
        // hello request
        const name = try data.readString(req_reader);
        std.log.info("Got hello: name {s}", .{name});

        // register player
        try game.addPlayer(gpa, name);

        // login success response (skip encryption)
        const uuid_str = try data.UUIDtoString(gpa, game.players.items[p].uuid);
        defer gpa.free(uuid_str);
        try data.writeString(res_writer, uuid_str); // uuid as string
        try data.writeString(res_writer, game.players.items[p].name); // username
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
        try data.writeInt(res_writer, game.players.items[p].eid); // entity id
        try data.writeByte(res_writer, game.players.items[p].gamemode); // gamemode
        try data.writeInt(res_writer, 0); // dimension
        try data.writeByte(res_writer, 2); // difficulty
        try data.writeByte(res_writer, 0); // max players
        try data.writeString(res_writer, "default"); // level type
        try data.writeBool(res_writer, false); // reduced debug info
        try sendPacket(gpa, tcp_writer, .{ .id = 0x23, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        // update client
        game.players.items[p].inventory.changed = [_]bool{true} ** inventory.N_SLOTS; // mark all slots as changed to send full inventory on login
        try game.sendInventory(gpa, tcp_writer, state, &game.players.items[p]);
        try game.sendXP(gpa, tcp_writer, state, &game.players.items[p]);
        try game.sendItemEntities(gpa, tcp_writer, state);

        // update player list
        for (game.players.items) |player| {
            try data.writeVarInt(res_writer, 0); // action: add
            try data.writeVarInt(res_writer, 1); // number of players
            try data.writeUUID(res_writer, player.uuid); // player uuid
            try data.writeString(res_writer, player.name); // player name
            try data.writeVarInt(res_writer, 0); // properties
            try data.writeVarInt(res_writer, player.gamemode); // gamemode
            try data.writeVarInt(res_writer, player.ping); // ping
            try data.writeBool(res_writer, false); // has display name
            try sendPacket(gpa, tcp_writer, .{ .id = 0x2e, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
        }

        // update client position (ends loading screen)
        try data.writeDouble(res_writer, game.players.items[p].position.x); // x
        try data.writeDouble(res_writer, game.players.items[p].position.y); // y
        try data.writeDouble(res_writer, game.players.items[p].position.z); // z
        try data.writeFloat(res_writer, game.players.items[p].look[0]); // yaw
        try data.writeFloat(res_writer, game.players.items[p].look[1]); // pitch
        try data.writeByte(res_writer, 0b00000000); // flags (relative)
        try data.writeVarInt(res_writer, @truncate(time & 0x7FFFFFFF)); // teleport id
        try sendPacket(gpa, tcp_writer, .{ .id = 0x2f, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();

        // chunk data
        try game.sendChunkData(gpa, tcp_writer, state);
    } else if (state.* == State.Play and packet.id == 0x04) {
        // client settings
        const locale = try data.readString(req_reader);
        const view_distance = try data.readByte(req_reader);
        const chat_mode = try data.readVarInt(req_reader);
        const chat_colors = try data.readBool(req_reader);
        const skin_parts = try data.readByte(req_reader);
        const main_hand = try data.readVarInt(req_reader);
        std.log.info("Got client_settings: locale {s}, view_distance {d}, chat_mode {d}, chat_colors {}, skin_parts {d}, main_hand {d}", .{ locale, view_distance, chat_mode, chat_colors, skin_parts, main_hand });
    } else if (state.* == State.Play and packet.id == 0x09) {
        // plugin message
        const channel = try data.readString(req_reader);
        const payload = try req_reader.allocRemaining(gpa, std.Io.Limit.unlimited); // unknown size
        defer gpa.free(payload);
        std.log.info("Got plugin_message: channel {s}, payload 0x{x} ({s})", .{ channel, payload, try utils.sanitizeString(gpa, payload) });
    } else if (state.* == State.Play and packet.id == 0x0c) {
        // player update
        const on_ground = try data.readBool(req_reader);
        std.log.info("Got player_update: on_ground {}", .{on_ground});
    } else if (state.* == State.Play and packet.id == 0x0d) {
        // position update
        const x = try data.readDouble(req_reader);
        const y = try data.readDouble(req_reader);
        const z = try data.readDouble(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("Got position_update: position ({}, {}, {}), on_ground {}", .{ x, y, z, on_ground });

        game.players.items[p].position = entities.fPos{ .x = x, .y = y, .z = z };
    } else if (state.* == State.Play and packet.id == 0x0e) {
        // position and look update
        const x = try data.readDouble(req_reader);
        const y = try data.readDouble(req_reader);
        const z = try data.readDouble(req_reader);
        const yaw = try data.readFloat(req_reader);
        const pitch = try data.readFloat(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("Got position_look_update: position ({}, {}, {}), yaw {}, pitch {}, on_ground {}", .{ x, y, z, yaw, pitch, on_ground });

        game.players.items[p].position = entities.fPos{ .x = x, .y = y, .z = z };
        game.players.items[p].look = [2]f32{ yaw, pitch };
    } else if (state.* == State.Play and packet.id == 0x0f) {
        // look update
        const yaw = try data.readFloat(req_reader);
        const pitch = try data.readFloat(req_reader);
        const on_ground = try data.readBool(req_reader);
        std.log.info("Got look_update: yaw {}, pitch {}, on_ground {}", .{ yaw, pitch, on_ground });

        game.players.items[p].look = [2]f32{ yaw, pitch };
    } else if (state.* == State.Play and packet.id == 0x00) {
        // teleport confirm
        const teleport_id = try data.readVarInt(req_reader);
        std.log.info("Got teleport_confirm: id {}", .{teleport_id});
    } else if (state.* == State.Play and packet.id == 0x0b) {
        // keep alive
        const timestamp = try data.readLong(req_reader);
        std.log.info("Got keep_alive: timestamp {}", .{timestamp});
        game.players.items[p].ping = @truncate((time - timestamp) * 2);
    } else if (state.* == State.Play and packet.id == 0x14) {
        // player digging
        const status = try data.readVarInt(req_reader);
        const pos = try data.readPosition(req_reader);
        const face = try data.readByte(req_reader);
        std.log.info("Got player_digging: status {}, position ({}, {}, {}), face {}", .{ status, pos.x, pos.y, pos.z, face });

        if (game.players.items[p].gamemode == 1 and status == 0 or game.players.items[p].gamemode == 0 and status == 2) { // TODO: saplings are broken without sending end digging
            // finished digging, break block
            try game.breakBlock(gpa, tcp_writer, state, &game.players.items[p], pos);
        } else if (status == 4) {
            // drop single item
            try game.dropItem(gpa, tcp_writer, state, &game.players.items[p], false);
        } else if (status == 3) {
            // drop entire stack
            try game.dropItem(gpa, tcp_writer, state, &game.players.items[p], true);
        }
    } else if (state.* == State.Play and packet.id == 0x1f) {
        // player block placement
        const pos = try data.readPosition(req_reader);
        const face = try data.readVarInt(req_reader);
        const hand = try data.readVarInt(req_reader);
        const cursor_x = try data.readFloat(req_reader);
        const cursor_y = try data.readFloat(req_reader);
        const cursor_z = try data.readFloat(req_reader);
        std.log.info("Got player_block_placement: position ({}, {}, {}), face {}, hand {}, cursor ({}, {}, {})", .{ pos.x, pos.y, pos.z, face, hand, cursor_x, cursor_y, cursor_z });

        const place_pos = world.applyFaceOffset(pos.x, pos.y, pos.z, face);
        try game.placeBlock(gpa, tcp_writer, state, &game.players.items[p], place_pos);
    } else if (state.* == State.Play and packet.id == 0x1d) {
        // player animation
        const hand = try data.readVarInt(req_reader);
        std.log.info("Got player_animation: hand {}", .{hand});

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
        std.log.info("Got player_slot_selection: slot {}", .{slot});
        game.players.items[p].selected_slot = @intCast(slot);
    } else if (state.* == State.Play and packet.id == 0x15) {
        // entity action
        const entity_id = try data.readVarInt(req_reader);
        const action_id = try data.readVarInt(req_reader);
        const jump_boost = try data.readVarInt(req_reader);
        std.log.info("Got entity_action: entity_id 0x{x}, action_id {}, jump_boost {}", .{ entity_id, action_id, jump_boost });
    } else if (state.* == State.Play and packet.id == 0x02) {
        // chat message
        const message = try utils.sanitizeString(gpa, try data.readString(req_reader));
        defer gpa.free(message);
        std.log.info("Got chat_message: {s}", .{message});

        if (message[0] == '/') {
            try game.processCommand(gpa, tcp_writer, state, &game.players.items[p], message);
        } else {
            try game.processChat(gpa, tcp_writer, state, &game.players.items[p], message);
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

    if (state.* == State.Play and time - lastKeepAlive.* > 10000) {
        // keep alive
        std.log.info("Sending keep alive", .{});
        lastKeepAlive.* = time;
        try data.writeLong(res_writer, time); // id
        try sendPacket(gpa, tcp_writer, .{ .id = 0x1f, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    }

    // game tick, TODO: tickspeed reduced when waiting on packages
    if (state.* == State.Play) {
        try game.tick(gpa, tcp_writer, state, delta);
    }
}

fn setState(state: *State, newState: State) void {
    std.log.info("State change: {s} -> {s}", .{ @tagName(state.*), @tagName(newState) });
    state.* = newState;
}

/// read packet from tcp, log
pub fn receivePacket(gpa: std.mem.Allocator, tcp_reader: *std.Io.Reader, state: State) !data.Packet {
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

/// write packet to tcp, flush, log. state needed for logging unique id
pub fn sendPacket(gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, packet: data.Packet, state: State) !void {
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
