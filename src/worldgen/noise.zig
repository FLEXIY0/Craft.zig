//! Gradient noise: the only source of "randomness" the terrain shape uses.
//!
//! Everything here is deterministic given a seed, and everything is a plain
//! function of coordinates, so a chunk can be generated on any thread, in any
//! order, without touching a single byte of shared state.

const std = @import("std");

/// Improved Perlin gradient noise (Ken Perlin, 2002).
/// Values are in [-1, 1], and are exactly 0 on the integer lattice.
pub const Perlin = struct {
    /// Permutation table, doubled so that lookups never need a modulo
    perm: [512]u8,
    /// Sampling offset, so that two generators with the same seed differ
    offset: [3]f64,

    pub fn init(random: std.Random) Perlin {
        var self: Perlin = undefined;

        var base: [256]u8 = undefined;
        for (&base, 0..) |*value, i|
            value.* = @intCast(i);
        random.shuffle(u8, &base);

        for (&self.perm, 0..) |*value, i|
            value.* = base[i & 255];

        self.offset = .{
            random.float(f64) * 256.0,
            random.float(f64) * 256.0,
            random.float(f64) * 256.0,
        };

        return self;
    }

    /// Noise value at a point in space
    pub fn sample3(self: *const Perlin, x: f64, y: f64, z: f64) f64 {
        const px = x + self.offset[0];
        const py = y + self.offset[1];
        const pz = z + self.offset[2];

        // Unit cube containing the point
        const xi: i32 = @intFromFloat(@floor(px));
        const yi: i32 = @intFromFloat(@floor(py));
        const zi: i32 = @intFromFloat(@floor(pz));

        const cx: usize = @intCast(xi & 255);
        const cy: usize = @intCast(yi & 255);
        const cz: usize = @intCast(zi & 255);

        // Position inside that cube
        const fx = px - @floor(px);
        const fy = py - @floor(py);
        const fz = pz - @floor(pz);

        const u = fade(fx);
        const v = fade(fy);
        const w = fade(fz);

        // Hash the eight corners
        const a = @as(usize, self.perm[cx]) + cy;
        const aa = @as(usize, self.perm[a & 511]) + cz;
        const ab = @as(usize, self.perm[(a + 1) & 511]) + cz;
        const b = @as(usize, self.perm[(cx + 1) & 511]) + cy;
        const ba = @as(usize, self.perm[b & 511]) + cz;
        const bb = @as(usize, self.perm[(b + 1) & 511]) + cz;

        // Blend the gradients of the eight corners
        return lerp(w, lerp(v, lerp(u, grad(self.perm[aa & 511], fx, fy, fz), grad(self.perm[ba & 511], fx - 1, fy, fz)), lerp(u, grad(self.perm[ab & 511], fx, fy - 1, fz), grad(self.perm[bb & 511], fx - 1, fy - 1, fz))), lerp(v, lerp(u, grad(self.perm[(aa + 1) & 511], fx, fy, fz - 1), grad(self.perm[(ba + 1) & 511], fx - 1, fy, fz - 1)), lerp(u, grad(self.perm[(ab + 1) & 511], fx, fy - 1, fz - 1), grad(self.perm[(bb + 1) & 511], fx - 1, fy - 1, fz - 1))));
    }

    /// Noise value on a horizontal plane
    pub inline fn sample2(self: *const Perlin, x: f64, z: f64) f64 {
        return self.sample3(x, 0.5, z);
    }

    inline fn fade(t: f64) f64 {
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    }

    inline fn lerp(t: f64, a: f64, b: f64) f64 {
        return a + t * (b - a);
    }

    /// Dot product of the point with one of the twelve edge gradients
    inline fn grad(hash: u8, x: f64, y: f64, z: f64) f64 {
        const h = hash & 15;
        const u = if (h < 8) x else y;
        const v = if (h < 4) y else if (h == 12 or h == 14) x else z;
        return (if (h & 1 == 0) u else -u) + (if (h & 2 == 0) v else -v);
    }
};

/// A sum of `octave_count` Perlin noises of doubling frequency and halving
/// amplitude. The classic way to turn smooth noise into something that looks
/// like terrain.
pub fn Fbm(comptime octave_count: usize) type {
    comptime std.debug.assert(octave_count > 0);

    return struct {
        const Self = @This();

        octaves: [octave_count]Perlin,
        /// Sum of the amplitudes, to bring the result back to [-1, 1]
        normalizer: f64,

        pub fn init(random: std.Random) Self {
            var self: Self = undefined;

            var total: f64 = 0;
            var amplitude: f64 = 1;
            for (&self.octaves) |*octave| {
                octave.* = .init(random);
                total += amplitude;
                amplitude *= 0.5;
            }
            self.normalizer = 1.0 / total;

            return self;
        }

        /// Sample in space, at the given base frequency
        pub fn sample3(self: *const Self, x: f64, y: f64, z: f64, frequency: f64) f64 {
            var sum: f64 = 0;
            var amplitude: f64 = 1;
            var scale = frequency;

            for (&self.octaves) |*octave| {
                sum += octave.sample3(x * scale, y * scale, z * scale) * amplitude;
                amplitude *= 0.5;
                scale *= 2.0;
            }

            return sum * self.normalizer;
        }

        /// Sample on a horizontal plane, at the given base frequency
        pub fn sample2(self: *const Self, x: f64, z: f64, frequency: f64) f64 {
            var sum: f64 = 0;
            var amplitude: f64 = 1;
            var scale = frequency;

            for (&self.octaves) |*octave| {
                sum += octave.sample2(x * scale, z * scale) * amplitude;
                amplitude *= 0.5;
                scale *= 2.0;
            }

            return sum * self.normalizer;
        }
    };
}

test "perlin stays in range and is deterministic" {
    var rng = std.Random.DefaultPrng.init(42);
    const noise: Perlin = .init(rng.random());

    var again = std.Random.DefaultPrng.init(42);
    const same: Perlin = .init(again.random());

    var x: f64 = -20;
    while (x < 20) : (x += 0.37) {
        const value = noise.sample3(x, x * 0.5, -x);
        try std.testing.expect(value >= -1.0 and value <= 1.0);
        try std.testing.expectEqual(value, same.sample3(x, x * 0.5, -x));
    }
}

test "perlin is smooth" {
    var rng = std.Random.DefaultPrng.init(7);
    const noise: Perlin = .init(rng.random());

    // Two nearby points can not differ wildly, that is the whole point of
    // gradient noise: no salt and pepper terrain
    var x: f64 = 0;
    while (x < 10) : (x += 0.1) {
        const a = noise.sample3(x, 3, 4);
        const b = noise.sample3(x + 0.01, 3, 4);
        try std.testing.expect(@abs(a - b) < 0.1);
    }
}

test "fbm stays in range" {
    var rng = std.Random.DefaultPrng.init(1234);
    const noise: Fbm(6) = .init(rng.random());

    var x: f64 = -50;
    while (x < 50) : (x += 1.3) {
        const value = noise.sample2(x, x * 2, 0.01);
        try std.testing.expect(value >= -1.0 and value <= 1.0);
    }
}
