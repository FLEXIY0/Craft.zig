//! Where a frame goes.
//!
//! The frame rate on its own says very little: a capped frame and a frame that
//! spends all its time waiting for the driver both read as "60". This splits the
//! frame in the three parts that can actually be acted on, so that a slow frame
//! points at the code that made it slow:
//!
//! - `update`: the simulation, the meshing pipeline and the world generation,
//!   i.e. everything this engine does on the main thread
//! - `submit`: walking the loaded chunks and handing them to the driver
//! - `present`: the buffer swap, which is where waiting for the gpu and the
//!   frame rate cap both end up
//!
//! Values are exponential moving averages: a single frame is far too noisy to
//! read off a debug overlay.

const std = @import("std");

const FrameStats = @This();

/// Weight of the newest sample. Slow enough to be readable, fast enough to react
const smoothing = 0.1;

/// Simulation, meshing pipeline and world generation, in milliseconds
update: f32 = 0,
/// Issuing the draw calls, in milliseconds
submit: f32 = 0,
/// Buffer swap: waiting for the gpu, and for the frame rate cap, in milliseconds
present: f32 = 0,
/// Chunks that passed the frustum test and were drawn last frame
chunks_drawn: u32 = 0,
/// Sections that passed the frustum test and were drawn last frame
sections_drawn: u32 = 0,
/// Chunks currently loaded
chunks_loaded: u32 = 0,
/// Triangles handed to the driver last frame
triangles: u32 = 0,
/// Draw calls issued last frame
draw_calls: u32 = 0,

/// Folds one sample into a running average
fn feed(average: *f32, sample_ns: u64) void {
    const ms = @as(f32, @floatFromInt(sample_ns)) / std.time.ns_per_ms;
    average.* += (ms - average.*) * smoothing;
}

pub fn addUpdate(self: *FrameStats, sample_ns: u64) void {
    feed(&self.update, sample_ns);
}

pub fn addSubmit(self: *FrameStats, sample_ns: u64) void {
    feed(&self.submit, sample_ns);
}

pub fn addPresent(self: *FrameStats, sample_ns: u64) void {
    feed(&self.present, sample_ns);
}

/// Milliseconds this engine is responsible for, i.e. everything but the wait on
/// the driver. This is the number that says whether the engine is the bottleneck
pub fn cpuTime(self: FrameStats) f32 {
    return self.update + self.submit;
}

/// Frame rate the engine alone would allow, if drawing the pixels were free.
/// The gap between this and the measured frame rate is the graphics card's share
pub fn cpuBoundFps(self: FrameStats) f32 {
    const cpu = self.cpuTime();
    return if (cpu > 0) 1000.0 / cpu else 0;
}

/// Prints the breakdown, for `--stats`
pub fn log(self: FrameStats) void {
    std.log.info(
        "frame {d:.2} ms | engine {d:.2} ms (update {d:.2} + submit {d:.2}) -> {d:.0} fps if drawing were free | present {d:.2} ms | {} chunks, {} sections, {} tris, {} draw calls",
        .{
            self.cpuTime() + self.present,
            self.cpuTime(),
            self.update,
            self.submit,
            self.cpuBoundFps(),
            self.present,
            self.chunks_drawn,
            self.sections_drawn,
            self.triangles,
            self.draw_calls,
        },
    );
}

test "averages converge on a steady sample" {
    var stats: FrameStats = .{};
    for (0..200) |_|
        stats.addUpdate(2 * std.time.ns_per_ms);

    try std.testing.expectApproxEqAbs(@as(f32, 2), stats.update, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 2), stats.cpuTime(), 0.01);
}
