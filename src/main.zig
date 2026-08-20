const std = @import("std");
const builtin = @import("builtin");
const io = @import("io");
const network = @import("network");

const is_android = builtin.target.abi.isAndroid();

pub const tracy_impl = @import("tracy_impl");

pub const tracy = @import("tracy");
pub const tracy_options: tracy.Options = .{
    .on_demand = false,
    .no_broadcast = false,
    .only_localhost = true,
    .only_ipv4 = false,
    .delayed_init = false,
    .manual_lifetime = false,
    .verbose = false,
    .data_port = null,
    .broadcast_port = null,
    .default_callstack_depth = 0,
};

// On Android the process is not started, a library is opened: the NDK's glue
// calls `main` by name from `android_main`, and zig only writes that entry
// point for an executable. Without this the library loads with `main`
// undefined, the dynamic linker refuses it, and the activity closes at once
// with nothing in the log that looks like a failure.
comptime {
    if (is_android)
        @export(&androidMain, .{ .name = "main", .linkage = .strong });
}

fn androidMain(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    // A library has no start code, so the few things a process would have been
    // handed have to be handed over here. raylib passes one argument.
    if (argc > 0)
        std.os.argv = @ptrCast(argv[0..@intCast(argc)]);

    main() catch |err| {
        std.log.err("Stopped: {}", .{err});
        return 1;
    };
    return 0;
}

/// Anything written to stderr on Android goes nowhere, which is why a client
/// that fails to start looks like a client that closed for no reason. This puts
/// the log where `adb logcat -s Craft.zig` can see it.
pub const std_options: std.Options = if (is_android) .{ .logFn = androidLog } else .{};

extern fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

fn androidLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // The numbers android/log.h gives these
    const priority: c_int = switch (level) {
        .debug => 3,
        .info => 4,
        .warn => 5,
        .err => 6,
    };

    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, prefix ++ format, args) catch blk: {
        // A line that does not fit is still worth having, cut short
        buffer[buffer.len - 1] = 0;
        break :blk buffer[0 .. buffer.len - 1 :0];
    };

    _ = __android_log_write(priority, "Craft.zig", text);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.log.debug("Loading network", .{});
    try network.init();
    defer network.deinit();
    std.log.debug("Network ready", .{});

    std.log.info("Running frontend \"{s}\"", .{io.frontend_name});
    try io.main(alloc);
    std.log.info("Exitting", .{});
}
