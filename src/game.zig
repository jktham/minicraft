const std = @import("std");

const _player = @import("player.zig");
const data = @import("data.zig");
const entities = @import("entities.zig");
const ids = @import("ids.zig");
const inventory = @import("inventory.zig");
const server = @import("server.zig");
const utils = @import("utils.zig");
const world = @import("world.zig");

pub const Game = struct {
    players: std.ArrayList(_player.Player),
    world: world.World,
    entities: entities.Entities,
    time: i64, // world time in ticks (20 ticks per second)

    pub fn init() Game {
        return .{
            .players = std.ArrayList(_player.Player).empty,
            .world = world.World.init(),
            .entities = entities.Entities.init(),
            .time = 0,
        };
    }

    /// populate player fields, check if rejoining by comparing name
    pub fn addPlayer(self: *Game, gpa: std.mem.Allocator, name: []const u8) !void {
        var existing_player: ?*_player.Player = null;
        for (self.players.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                existing_player = p;
                break;
            }
        }

        if (existing_player == null) {
            std.log.info("Player {s} joined the game for the first time", .{name});

            var player = _player.Player.init();
            player.name = try gpa.dupe(u8, name); // reallocate to keep persistent
            player.eid = entities.randomEID();
            player.uuid = entities.randomUUID();
            player.gamemode = 0; // 0=survival, 1=creative

            player.inventory.slots[36] = inventory.Stack{
                .id = ids.Item.IronPickaxe,
                .count = 99,
                .damage = 0,
                .nbt = &[_]u8{0},
            };
            player.inventory.changed[36] = true;

            const center = @as(f32, world.N_CHUNKS * world.N_BLOCKS) / 2.0;
            player.position = entities.fPos{ .x = center, .y = 20, .z = center };
            player.look = [2]f32{ 0, 0 };

            try self.players.append(gpa, player);
        } else {
            std.log.info("Player {s} rejoined the game", .{name});
            existing_player.?.selected_slot = 0;
        }
    }

    /// validate and break block, then update client
    pub fn breakBlock(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player, position: data.Position) !void {
        const block = try self.world.getBlock(@intCast(position.x), @intCast(position.y), @intCast(position.z));
        if (block == ids.Block.Air) {
            std.log.warn("Cannot break block at ({}, {}, {}) because it is already air", .{ position.x, position.y, position.z });
            try self.sendBlockChange(gpa, tcp_writer, state, position); // sync client
            return;
        }

        try self.world.setBlock(@intCast(position.x), @intCast(position.y), @intCast(position.z), ids.Block.Air);
        player.xp += 1;

        // create item entity
        const item: entities.ItemEntity = .{
            .eid = entities.randomEID(),
            .uuid = entities.randomUUID(),
            .position = entities.fPos{
                .x = @as(f32, @floatFromInt(position.x)) + 0.5,
                .y = @as(f32, @floatFromInt(position.y)) + 0.5,
                .z = @as(f32, @floatFromInt(position.z)) + 0.5,
            },
            .stack = .{
                .id = block.toItem(),
                .count = 1,
                .damage = 0,
                .nbt = &[_]u8{0},
            },
        };
        try self.entities.spawnItem(gpa, item);

        // update client
        try self.sendBlockChange(gpa, tcp_writer, state, position);
        try self.sendXP(gpa, tcp_writer, state, player);
        try self.sendItemEntities(gpa, tcp_writer, state);
    }

    /// validate and place block, then update client
    pub fn placeBlock(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player, position: data.Position) !void {
        const slot = 36 + player.selected_slot; // TODO: offhand
        const stack = player.inventory.slots[slot];
        const block = stack.id.toBlock();
        var valid = true;

        // inventory checks
        if (valid and block == ids.Block.Air) {
            std.log.warn("Cannot place item {}", .{stack.id});
            valid = false;
        }
        if (valid and player.inventory.slots[slot].count == 0) {
            std.log.warn("Cannot place block at ({}, {}, {}) because slot {} is empty", .{ position.x, position.y, position.z, slot });
            valid = false;
        }

        // world checks
        if (valid and !world.checkBounds(position.x, position.y, position.z)) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is outside world bounds", .{ position.x, position.y, position.z });
            valid = false;
        }
        const current_block = try self.world.getBlock(position.x, position.y, position.z);
        if (valid and current_block != ids.Block.Air) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is occupied by block {}", .{ position.x, position.y, position.z, current_block });
            valid = false;
        }

        // player checks
        const position_center = entities.fPos{
            .x = @as(f64, @floatFromInt(position.x)) + 0.5,
            .y = @as(f64, @floatFromInt(position.y)) + 0.5,
            .z = @as(f64, @floatFromInt(position.z)) + 0.5,
        };
        if (valid and utils.distance(player.position, position_center) > 6.0) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is too far away", .{ position.x, position.y, position.z });
            valid = false;
        }
        if (valid and utils.sameBlock(player.position, position_center) or utils.sameBlock(.{ .x = player.position.x, .y = player.position.y + 1, .z = player.position.z }, position_center)) {
            std.log.warn("Cannot place block at ({}, {}, {}) because it is blocked by player", .{ position.x, position.y, position.z });
            valid = false;
        }

        if (!valid) { // update client to prevent desync, since it may make different choices about validity
            player.inventory.changed[slot] = true; // force inventory update to client
            try self.sendBlockChange(gpa, tcp_writer, state, position);
            try self.sendInventory(gpa, tcp_writer, state, player);
            return;
        }

        std.log.info("Placing block {} at ({}, {}, {})", .{ block, position.x, position.y, position.z });
        try player.inventory.removeCount(slot, 1);
        try self.world.setBlock(position.x, position.y, position.z, block);

        // update client
        try self.sendBlockChange(gpa, tcp_writer, state, position);
        try self.sendInventory(gpa, tcp_writer, state, player);
    }

    pub fn dropItem(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player, drop_stack: bool) !void {
        const slot = 36 + player.selected_slot;
        const stack = player.inventory.slots[slot];
        if (stack.count == 0) {
            std.log.warn("Cannot drop item from slot {} because it is empty", .{slot});
            player.inventory.changed[slot] = true;
            try self.sendInventory(gpa, tcp_writer, state, player);
            return;
        }
        try player.inventory.removeCount(slot, if (drop_stack) stack.count else 1);

        // create item entity
        const item: entities.ItemEntity = .{
            .eid = entities.randomEID(),
            .uuid = entities.randomUUID(),
            .position = entities.fPos{
                .x = player.position.x - std.math.sin(player.look[0] / 180.0 * std.math.pi) * 2,
                .y = player.position.y + 0.5,
                .z = player.position.z + std.math.cos(player.look[0] / 180.0 * std.math.pi) * 2,
            },
            .stack = .{
                .id = stack.id,
                .count = if (drop_stack) stack.count else 1,
                .damage = stack.damage,
                .nbt = stack.nbt,
            },
        };
        try self.entities.spawnItem(gpa, item);

        // update client
        try self.sendInventory(gpa, tcp_writer, state, player);
        try self.sendItemEntities(gpa, tcp_writer, state);
    }

    pub fn processChat(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player, message: []const u8) !void {
        const message_json = try std.fmt.allocPrint(gpa, "{{\"text\": \"{s}: {s}\"}}", .{ player.name, message });
        defer gpa.free(message_json);
        try self.sendMessage(gpa, tcp_writer, state, message_json, 0);
    }

    pub fn processCommand(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player, message: []const u8) !void {
        if (std.mem.eql(u8, message, "/ping")) {
            const message_json = try std.fmt.allocPrint(gpa, "{{\"text\": \"ping: {d} ms\"}}", .{player.ping});
            defer gpa.free(message_json);
            try self.sendMessage(gpa, tcp_writer, state, message_json, 1);
        } else {
            const message_json = try std.fmt.allocPrint(gpa, "{{\"text\": \"Unknown command: {s}\"}}", .{message});
            defer gpa.free(message_json);
            try self.sendMessage(gpa, tcp_writer, state, message_json, 1);
        }
    }

    /// main game loop, called every tick to update game state and send updates to client. delta is time in ms since last tick
    pub fn tick(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, delta: i64) !void {
        _ = delta; // autofix
        var res_data: [1000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        // std.log.info("Game tick, time: {d}, delta: {d}", .{ self.time, delta });
        self.time += 1;

        // time update
        if (@mod(self.time, 20) == 0) { // every second
            try data.writeLong(res_writer, self.time); // world age in ticks
            try data.writeLong(res_writer, @mod(self.time, 24000)); // time of day in ticks (0-23999)
            try server.sendPacket(gpa, tcp_writer, .{ .id = 0x47, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
        }

        // pick up nearby items
        for (self.players.items) |*player| {
            const close_items = try self.entities.getCloseItems(gpa, .{ .x = player.position.x, .y = player.position.y + 1.0, .z = player.position.z }, 1.2);
            for (close_items) |item| {
                player.inventory.addStack(item.stack) catch |err| {
                    if (err == error.InventoryFull) {
                        std.log.warn("Inventory full, cannot pick up item with eid 0x{x}", .{item.eid});
                        continue;
                    }
                };

                // collect item
                try data.writeVarInt(res_writer, item.eid); // collected
                try data.writeVarInt(res_writer, player.eid); // collector
                try data.writeVarInt(res_writer, item.stack.count); // count
                try server.sendPacket(gpa, tcp_writer, .{ .id = 0x4b, .data = res_writer.buffered() }, state.*);
                _ = res_writer.consumeAll();

                // set inventory
                try self.sendInventory(gpa, tcp_writer, state, player);

                // destroy item entity
                try self.entities.destroyItem(item.eid);

                try data.writeVarInt(res_writer, 1); // count
                try data.writeVarInt(res_writer, item.eid); // entity id
                try server.sendPacket(gpa, tcp_writer, .{ .id = 0x32, .data = res_writer.buffered() }, state.*);
                _ = res_writer.consumeAll();
            }
        }
    }

    /// send current inventory state to client, only changed slots for efficiency
    pub fn sendInventory(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player) !void {
        _ = self; // autofix
        var res_data: [1000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        std.log.info("Sending inventory", .{});
        for (player.inventory.slots, 0..) |slot, i| {
            if (player.inventory.changed[i]) {
                try data.writeByte(res_writer, 0); // window id (0 for player inventory)
                try data.writeShort(res_writer, @intCast(i)); // slot id
                try data.writeStack(res_writer, slot); // slot data
                try server.sendPacket(gpa, tcp_writer, .{ .id = 0x16, .data = res_writer.buffered() }, state.*);
                _ = res_writer.consumeAll();
                player.inventory.changed[i] = false;
            }
        }
    }

    /// send current block state at position to client
    pub fn sendBlockChange(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, position: data.Position) !void {
        var res_data: [1000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        std.log.info("Sending block change", .{});
        const block = try self.world.getBlock(@intCast(position.x), @intCast(position.y), @intCast(position.z));
        try data.writePosition(res_writer, position); // position
        try data.writeVarInt(res_writer, ids.palette[@intFromEnum(block)]); // block id
        try server.sendPacket(gpa, tcp_writer, .{ .id = 0x0B, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    }

    /// send current xp state to client
    pub fn sendXP(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, player: *_player.Player) !void {
        _ = self; // autofix
        var res_data: [1000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        std.log.info("Sending xp", .{});
        // set experience, http://minecraft.gamepedia.com/Experience%23Leveling_up
        try data.writeFloat(res_writer, @as(f32, @floatFromInt(@mod(player.xp, 10))) / 10.0); // xp bar (0.0-1.0)
        try data.writeVarInt(res_writer, @divFloor(player.xp, 10)); // level
        try data.writeVarInt(res_writer, player.xp); // total xp
        try server.sendPacket(gpa, tcp_writer, .{ .id = 0x40, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    }

    /// send all item entities to client
    pub fn sendItemEntities(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State) !void {
        var res_data: [1000000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        std.log.info("Sending item entities", .{});
        for (self.entities.items.items) |item| {
            // spawn object
            try data.writeVarInt(res_writer, item.eid); // entity id
            try data.writeUUID(res_writer, item.uuid); // entity uuid
            try data.writeByte(res_writer, 2); // type
            try data.writeDouble(res_writer, item.position.x); // x
            try data.writeDouble(res_writer, item.position.y); // y
            try data.writeDouble(res_writer, item.position.z); // z
            try data.writeByte(res_writer, 0); // pitch
            try data.writeByte(res_writer, 0); // yaw
            try data.writeInt(res_writer, 1); // data
            try data.writeShort(res_writer, 0); // velocity x
            try data.writeShort(res_writer, 0); // velocity y
            try data.writeShort(res_writer, 0); // velocity z
            try server.sendPacket(gpa, tcp_writer, .{ .id = 0x00, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();

            // update entity metadata https://c4k3.github.io/wiki.vg/Entities.html#Item
            try data.writeVarInt(res_writer, item.eid); // entity id
            try data.writeByte(res_writer, 6); // index (slot for items)
            try data.writeVarInt(res_writer, 5); // type (5 for slot)
            try data.writeStack(res_writer, item.stack);
            try data.writeByte(res_writer, 0xff); // end of metadata
            try server.sendPacket(gpa, tcp_writer, .{ .id = 0x3c, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
        }
    }

    pub fn sendChunkData(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State) !void {
        var res_data: [1000000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        std.log.info("Sending chunk data", .{});
        var indices = try world.getChunkSpiralIndices(gpa);
        defer indices.deinit(gpa);
        for (indices.items) |chunk_index| {
            const chunk_x = chunk_index[0];
            const chunk_z = chunk_index[1];
            var chunk_data: [1000000]u8 = undefined;
            var cw = std.Io.Writer.fixed(&chunk_data);
            const chunk_writer = &cw;

            for (0..world.N_SUBCHUNKS) |chunk_y| {
                try data.writeByte(chunk_writer, 8); // bits per block
                try data.writeVarInt(chunk_writer, ids.palette.len); // palette length
                for (ids.palette) |p| {
                    try data.writeVarInt(chunk_writer, p); // palette entry
                }
                try data.writeVarInt(chunk_writer, (4096 * 8) / 64); // data length (number of longs)
                try data.writeBytes(chunk_writer, try self.world.getChunkPointer(@intCast(chunk_x), @intCast(chunk_y), @intCast(chunk_z))); // block data (4096 blocks per subchunk)
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
            try server.sendPacket(gpa, tcp_writer, .{ .id = 0x20, .data = res_writer.buffered() }, state.*);
            _ = res_writer.consumeAll();
        }
    }

    /// send chat message to client, mode is 0 for chat, 1 for system message, 2 for above hotbar
    pub fn sendMessage(self: *Game, gpa: std.mem.Allocator, tcp_writer: *std.Io.Writer, state: *server.State, message: []const u8, mode: u8) !void {
        _ = self; // autofix
        var res_data: [1000]u8 = undefined;
        var w = std.Io.Writer.fixed(&res_data);
        const res_writer = &w;

        std.log.info("Sending message", .{});
        try data.writeString(res_writer, message); // message
        try data.writeByte(res_writer, mode); // position (0 for chat, 1 for system message, 2 for above hotbar)
        try server.sendPacket(gpa, tcp_writer, .{ .id = 0x0f, .data = res_writer.buffered() }, state.*);
        _ = res_writer.consumeAll();
    }
};
