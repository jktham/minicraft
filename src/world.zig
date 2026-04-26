const std = @import("std");

// blockid(9) + meta(4)
pub const palette = [_]i32{
    0b000000000_0000, // air
    0b000000010_0000, // grass
    0b000000001_0000, // stone
    0b000000111_0000, // bedrock
};

// index into palette
pub const Block = enum(u8) {
    Air = 0,
    Grass = 1,
    Stone = 2,
    Bedrock = 3,
};

pub const N_CHUNKS = 9; // number of chunks in each direction (x and z)
pub const N_SUBCHUNKS = 16; // number of subchunks per column (y direction)
pub const N_BLOCKS = 16; // number of blocks in each direction within a subchunk

// chunk xzy, local yxz
pub var chunks: [N_CHUNKS][N_CHUNKS][N_SUBCHUNKS][N_BLOCKS][N_BLOCKS][N_BLOCKS]u8 = undefined;

pub fn generate() !void {
    for (0..N_CHUNKS) |chunk_x| {
        for (0..N_SUBCHUNKS) |chunk_y| {
            for (0..N_CHUNKS) |chunk_z| {
                for (0..N_BLOCKS) |local_x| {
                    for (0..N_BLOCKS) |local_y| {
                        for (0..N_BLOCKS) |local_z| {
                            const global_x: i32 = @intCast(chunk_x * N_BLOCKS + local_x);
                            const global_y: i32 = @intCast(chunk_y * N_BLOCKS + local_y);
                            const global_z: i32 = @intCast(chunk_z * N_BLOCKS + local_z);

                            if (global_y == 8) {
                                try setBlock(global_x, global_y, global_z, Block.Grass);
                            } else if (global_y == 0) {
                                try setBlock(global_x, global_y, global_z, Block.Bedrock);
                            } else if (global_y < 8) {
                                try setBlock(global_x, global_y, global_z, Block.Stone);
                            } else {
                                try setBlock(global_x, global_y, global_z, Block.Air);
                            }
                        }
                    }
                }
            }
        }
    }
}

pub fn setBlock(x: i32, y: i32, z: i32, block: Block) !void {
    const chunk_x = @divFloor(x, 16);
    const chunk_y = @divFloor(y, 16);
    const chunk_z = @divFloor(z, 16);

    if (chunk_x < 0 or chunk_x >= N_CHUNKS or chunk_y < 0 or chunk_y >= N_SUBCHUNKS or chunk_z < 0 or chunk_z >= N_CHUNKS) {
        std.log.warn("Attempted to set block outside of world bounds at ({}, {}, {})", .{ x, y, z });
        return error.OutOfBounds;
    }

    const local_x = @mod(x, 16);
    const local_y = @mod(y, 16);
    const local_z = @mod(z, 16);

    chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)][@intCast(local_y)][@intCast(local_x)][@intCast(local_z)] = @intFromEnum(block);
}

pub fn getBlock(x: i32, y: i32, z: i32) !Block {
    const chunk_x = @divFloor(x, 16);
    const chunk_y = @divFloor(y, 16);
    const chunk_z = @divFloor(z, 16);

    if (chunk_x < 0 or chunk_x >= N_CHUNKS or chunk_y < 0 or chunk_y >= N_SUBCHUNKS or chunk_z < 0 or chunk_z >= N_CHUNKS) {
        std.log.warn("Attempted to get block outside of world bounds at ({}, {}, {})", .{ x, y, z });
        return error.OutOfBounds;
    }

    const local_x = @mod(x, 16);
    const local_y = @mod(y, 16);
    const local_z = @mod(z, 16);

    return @enumFromInt(chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)][@intCast(local_y)][@intCast(local_x)][@intCast(local_z)]);
}

// pointer to flat array of 4096 blocks in the subchunk, for direct writing to network buffer in local yxz order
pub fn getChunkPointer(chunk_x: i32, chunk_y: i32, chunk_z: i32) !*[4096]u8 {
    if (chunk_x < 0 or chunk_x >= N_CHUNKS or chunk_y < 0 or chunk_y >= N_SUBCHUNKS or chunk_z < 0 or chunk_z >= N_CHUNKS) {
        std.log.warn("Attempted to get chunk pointer outside of world bounds at ({}, {}, {})", .{ chunk_x, chunk_y, chunk_z });
        return error.OutOfBounds;
    }
    return @ptrCast(&chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)]);
}
