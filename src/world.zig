const std = @import("std");

const data = @import("data.zig");
const ids = @import("ids.zig");

pub const N_CHUNKS = 9; // number of chunks in each direction (x and z)
pub const N_SUBCHUNKS = 16; // number of subchunks per column (y direction)
pub const N_BLOCKS = 16; // number of blocks in each direction within a subchunk

pub const World = struct {
    /// chunk xzy, local yzx
    chunks: [N_CHUNKS][N_CHUNKS][N_SUBCHUNKS][N_BLOCKS][N_BLOCKS][N_BLOCKS]u8,

    pub fn init() World {
        return .{
            .chunks = undefined,
        };
    }

    pub fn generate(self: *World) !void {
        std.log.info("Generating world...", .{});
        for (0..N_CHUNKS) |chunk_x| {
            for (0..N_CHUNKS) |chunk_z| {
                for (0..N_SUBCHUNKS) |chunk_y| {
                    for (0..N_BLOCKS) |local_y| {
                        for (0..N_BLOCKS) |local_x| {
                            for (0..N_BLOCKS) |local_z| {
                                const global_x: i32 = @intCast(chunk_x * N_BLOCKS + local_x);
                                const global_y: i32 = @intCast(chunk_y * N_BLOCKS + local_y);
                                const global_z: i32 = @intCast(chunk_z * N_BLOCKS + local_z);

                                if (global_y == 8) {
                                    try self.setBlock(global_x, global_y, global_z, ids.Block.Grass);
                                } else if (global_y == 0) {
                                    try self.setBlock(global_x, global_y, global_z, ids.Block.Bedrock);
                                } else if (global_y < 8) {
                                    try self.setBlock(global_x, global_y, global_z, ids.Block.Stone);
                                } else {
                                    try self.setBlock(global_x, global_y, global_z, ids.Block.Air);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn setBlock(self: *World, x: i32, y: i32, z: i32, block: ids.Block) !void {
        if (!checkBounds(x, y, z)) {
            return error.OutOfBounds;
        }

        const chunk_x = @divFloor(x, 16);
        const chunk_y = @divFloor(y, 16);
        const chunk_z = @divFloor(z, 16);

        const local_x = @mod(7 - x, 16); // alignment with chunk data
        const local_y = @mod(y, 16);
        const local_z = @mod(z, 16);

        self.chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)][@intCast(local_y)][@intCast(local_z)][@intCast(local_x)] = @intFromEnum(block);
    }

    pub fn getBlock(self: *World, x: i32, y: i32, z: i32) !ids.Block {
        if (!checkBounds(x, y, z)) {
            return error.OutOfBounds;
        }

        const chunk_x = @divFloor(x, 16);
        const chunk_y = @divFloor(y, 16);
        const chunk_z = @divFloor(z, 16);

        const local_x = @mod(7 - x, 16); // alignment with chunk data
        const local_y = @mod(y, 16);
        const local_z = @mod(z, 16);

        return @enumFromInt(self.chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)][@intCast(local_y)][@intCast(local_z)][@intCast(local_x)]);
    }

    /// pointer to flat array of 4096 blocks in the subchunk, for direct writing to network buffer in local yzx order
    pub fn getChunkPointer(self: *World, chunk_x: i32, chunk_y: i32, chunk_z: i32) !*[4096]u8 {
        if (chunk_x < 0 or chunk_x >= N_CHUNKS or chunk_y < 0 or chunk_y >= N_SUBCHUNKS or chunk_z < 0 or chunk_z >= N_CHUNKS) {
            std.log.err("Attempted to get chunk pointer outside of world bounds at ({}, {}, {})", .{ chunk_x, chunk_y, chunk_z });
            return error.OutOfBounds;
        }
        return @ptrCast(&self.chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)]);
    }
};

pub fn checkBounds(x: i32, y: i32, z: i32) bool {
    const chunk_x = @divFloor(x, 16);
    const chunk_y = @divFloor(y, 16);
    const chunk_z = @divFloor(z, 16);
    return chunk_x >= 0 and chunk_x < N_CHUNKS and chunk_y >= 0 and chunk_y < N_SUBCHUNKS and chunk_z >= 0 and chunk_z < N_CHUNKS;
}

const EPS = 0.000001;
pub fn applyFaceOffset(x: i32, y: i32, z: i32, face: i32) data.Position {
    return switch (face) {
        0 => .{ .x = @intCast(x + 0), .y = @intCast(y - 1), .z = @intCast(z + 0) },
        1 => .{ .x = @intCast(x + 0), .y = @intCast(y + 1), .z = @intCast(z + 0) },
        2 => .{ .x = @intCast(x + 0), .y = @intCast(y + 0), .z = @intCast(z - 1) },
        3 => .{ .x = @intCast(x + 0), .y = @intCast(y + 0), .z = @intCast(z + 1) },
        4 => .{ .x = @intCast(x - 1), .y = @intCast(y + 0), .z = @intCast(z + 0) },
        5 => .{ .x = @intCast(x + 1), .y = @intCast(y + 0), .z = @intCast(z + 0) },
        else => .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) },
    };
}
