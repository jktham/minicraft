const std = @import("std");
const builtin = @import("builtin");

const data = @import("data.zig");
const palette = @import("palette.zig");

pub const N_CHUNKS = if (builtin.mode == .Debug) 9 else 21; // number of chunks in each direction (x and z)
pub const N_SUBCHUNKS = 16; // number of subchunks per column (y direction)
pub const N_BLOCKS = 16; // number of blocks in each direction within a subchunk

pub const World = struct {
    /// chunk xzy, local yzx
    chunks: *[N_CHUNKS][N_CHUNKS][N_SUBCHUNKS][N_BLOCKS][N_BLOCKS][N_BLOCKS]palette.Block,

    pub fn init(gpa: std.mem.Allocator) World {
        return .{
            .chunks = @ptrCast(gpa.alloc(palette.Block, N_CHUNKS * N_CHUNKS * N_SUBCHUNKS * N_BLOCKS * N_BLOCKS * N_BLOCKS) catch unreachable),
        };
    }

    pub fn deinit(self: *World, gpa: std.mem.Allocator) void {
        gpa.free(@as([]palette.Block, @ptrCast(self.chunks)));
    }

    pub fn generate(self: *World) !void {
        std.log.info("Generating world...", .{});
        var count: i32 = 0;
        for (0..N_CHUNKS) |chunk_x| {
            for (0..N_CHUNKS) |chunk_z| {
                for (0..N_SUBCHUNKS) |chunk_y| {
                    for (0..N_BLOCKS) |local_y| {
                        for (0..N_BLOCKS) |local_x| {
                            for (0..N_BLOCKS) |local_z| {
                                const global_x: i32 = @intCast(chunk_x * N_BLOCKS + local_x);
                                const global_y: i32 = @intCast(chunk_y * N_BLOCKS + local_y);
                                const global_z: i32 = @intCast(chunk_z * N_BLOCKS + local_z);

                                const noise_scale: f32 = 0.08;
                                const height_scale: f32 = 64.0;
                                const height_offset: f32 = 32.0;

                                const x: f32 = @floatFromInt(global_x);
                                const z: f32 = @floatFromInt(global_z);

                                const p = perlin(x * noise_scale, z * noise_scale);
                                const height: i32 = @intFromFloat(p * height_scale + height_offset);

                                if (global_y == height) {
                                    try self.setBlock(global_x, global_y, global_z, palette.Block.grass);
                                } else if (global_y == height - 1) {
                                    try self.setBlock(global_x, global_y, global_z, palette.Block.dirt);
                                } else if (global_y == 0) {
                                    try self.setBlock(global_x, global_y, global_z, palette.Block.bedrock);
                                } else if (global_y < height) {
                                    try self.setBlock(global_x, global_y, global_z, palette.Block.stone);
                                } else {
                                    try self.setBlock(global_x, global_y, global_z, palette.Block.air);
                                }

                                if (global_y < 60 and std.meta.eql(try self.getBlock(global_x, global_y, global_z), palette.Block.air)) {
                                    try self.setBlock(global_x, global_y, global_z, palette.Block.water);
                                }
                            }
                        }
                    }
                    count += 1;
                    std.log.info("Chunk {d}/{d}\x1B[A", .{ count, N_CHUNKS * N_CHUNKS * N_SUBCHUNKS });
                }
            }
        }
        std.log.info("Chunk {d}/{d}", .{ count, N_CHUNKS * N_CHUNKS * N_SUBCHUNKS });
    }

    pub fn setBlock(self: *World, x: i32, y: i32, z: i32, block: palette.Block) !void {
        if (!checkBounds(x, y, z)) {
            return error.OutOfBounds;
        }

        const chunk_x = @divFloor(x, 16);
        const chunk_y = @divFloor(y, 16);
        const chunk_z = @divFloor(z, 16);

        const local_x = @mod(x, 16);
        const local_y = @mod(y, 16);
        const local_z = @mod(z, 16);

        self.chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)][@intCast(local_y)][@intCast(local_z)][@intCast(local_x)] = block;
    }

    pub fn getBlock(self: *World, x: i32, y: i32, z: i32) !palette.Block {
        if (!checkBounds(x, y, z)) {
            return error.OutOfBounds;
        }

        const chunk_x = @divFloor(x, 16);
        const chunk_y = @divFloor(y, 16);
        const chunk_z = @divFloor(z, 16);

        const local_x = @mod(x, 16);
        const local_y = @mod(y, 16);
        const local_z = @mod(z, 16);

        return self.chunks[@intCast(chunk_x)][@intCast(chunk_z)][@intCast(chunk_y)][@intCast(local_y)][@intCast(local_z)][@intCast(local_x)];
    }

    /// pointer to flat array of 4096 blocks in the subchunk, for direct writing to network buffer in local yzx order
    pub fn getSubchunkPointer(self: *World, chunk_x: i32, chunk_y: i32, chunk_z: i32) !*[4096]u13 {
        if (chunk_x < 0 or chunk_x >= N_CHUNKS or chunk_y < 0 or chunk_y >= N_SUBCHUNKS or chunk_z < 0 or chunk_z >= N_CHUNKS) {
            std.log.err("Attempted to get subchunk pointer outside of world bounds at ({}, {}, {})", .{ chunk_x, chunk_y, chunk_z });
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

/// returns chunk indices starting from the center and going outwards
pub fn getChunkSpiralIndices(gpa: std.mem.Allocator) !std.ArrayList(struct { usize, usize }) {
    const C = N_CHUNKS / 2;
    var indices = std.ArrayList(struct { usize, usize }).empty;
    for (0..N_CHUNKS + 1) |i| {
        for (0..N_CHUNKS) |x| {
            for (0..N_CHUNKS) |z| {
                const dist_x = @abs(@as(i32, @intCast(x)) - C);
                const dist_z = @abs(@as(i32, @intCast(z)) - C);
                if (dist_x + dist_z == i) {
                    try indices.append(gpa, .{ x, z });
                }
            }
        }
    }
    return indices;
}

fn smoothstep(a: f32, b: f32, w: f32) f32 {
    return (b - a) * (3.0 - w * 2.0) * w * w + a;
}

var prng = std.Random.DefaultPrng.init(0);
fn randomGradient(ix: i32, iy: i32) struct { f32, f32 } {
    prng.seed(@as(u64, @intCast(@as(u32, @bitCast(ix)))) << 32 | @as(u64, @intCast(@as(u32, @bitCast(iy)))));
    const r = std.Random.float(prng.random(), f32) * std.math.pi * 2.0; // [0, 2*pi)
    return .{ std.math.cos(r), std.math.sin(r) }; // [-1, 1]
}

fn dotGridGradient(ix: i32, iy: i32, x: f32, y: f32) f32 {
    const gradient = randomGradient(ix, iy);
    const dx = x - @as(f32, @floatFromInt(ix));
    const dy = y - @as(f32, @floatFromInt(iy));
    return dx * gradient[0] + dy * gradient[1];
}

/// perlin noise implementation stolen from https://en.wikipedia.org/w/index.php?title=Perlin_noise&oldid=1230993513 <3
pub fn perlin(x: f32, y: f32) f32 {
    // grid points
    const x0: i32 = @floor(x);
    const x1: i32 = x0 + 1;
    const y0: i32 = @floor(y);
    const y1: i32 = y0 + 1;

    // interpolation weights
    const sx: f32 = x - @as(f32, @floatFromInt(x0));
    const sy: f32 = y - @as(f32, @floatFromInt(y0));

    // interpolate between grid point gradients
    const n0 = dotGridGradient(x0, y0, x, y);
    const n1 = dotGridGradient(x1, y0, x, y);
    const ix0 = smoothstep(n0, n1, sx);

    const n2 = dotGridGradient(x0, y1, x, y);
    const n3 = dotGridGradient(x1, y1, x, y);
    const ix1 = smoothstep(n2, n3, sx);

    return smoothstep(ix0, ix1, sy) * 0.5 + 0.5; // [0, 1]
}
