const std = @import("std");

pub const Frontend = enum {
    dummy,
    raylib,
};

/// Writes out the paths zig needs to use the NDK's libc.
///
/// raylib builds one of these for itself, but with the pre 0.15 spelling: it
/// hands the rendered bytes to one list and takes the slice from another, so
/// the file it writes is empty and the build stops on a parse error. Ours is
/// handed to raylib's artifact as well, which is the whole of the workaround.
fn androidLibCFile(b: *std.Build, include: []const u8, crt: []const u8) std.Build.LazyPath {
    var out: std.Io.Writer.Allocating = .init(b.allocator);
    (std.zig.LibCInstallation{
        .include_dir = include,
        .sys_include_dir = include,
        .crt_dir = crt,
    }).render(&out.writer) catch @panic("could not describe the NDK's libc");

    return b.addWriteFiles().add(
        "android-libc.txt",
        out.toOwnedSlice() catch @panic("out of memory"),
    );
}

/// Points a compile step at the NDK: its libc, its headers, its crt and the
/// libraries an app is expected to link. raylib does this for itself, but the
/// app is a separate artifact and has to be told the same things.
fn addAndroidSupport(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    ndk: []const u8,
    api: []const u8,
) void {
    if (ndk.len == 0)
        std.debug.panic("An Android target needs -Dandroid-ndk=<path> or ANDROID_NDK_HOME", .{});

    // The only host tags the NDK ships, per its own documentation
    const host = switch (@import("builtin").target.os.tag) {
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        .macos => "darwin-x86_64",
        else => @panic("unsupported host for an Android build"),
    };

    const triple = switch (target.result.cpu.arch) {
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .aarch64 => "aarch64-linux-android",
        .riscv64 => "riscv64-linux-android",
        else => @panic("no Android ABI for this architecture"),
    };

    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt", host, "sysroot" });
    const include = b.pathJoin(&.{ sysroot, "usr/include" });
    const lib = b.pathJoin(&.{ sysroot, "usr/lib", triple });
    const api_lib = b.pathJoin(&.{ lib, api });
    const glue = b.pathJoin(&.{ ndk, "sources/android/native_app_glue" });

    compile.root_module.addLibraryPath(.{ .cwd_relative = lib });
    compile.root_module.addLibraryPath(.{ .cwd_relative = api_lib });
    compile.root_module.addSystemIncludePath(.{ .cwd_relative = include });
    compile.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ include, triple }) });
    compile.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ include, "asm-generic" }) });
    compile.root_module.addIncludePath(.{ .cwd_relative = glue });

    compile.setLibCFile(androidLibCFile(b, include, api_lib));

    compile.root_module.addCSourceFile(.{
        .file = .{ .cwd_relative = b.pathJoin(&.{ glue, "android_native_app_glue.c" }) },
        .flags = &.{"-std=c99"},
    });

    // NativeActivity looks up ANativeActivity_onCreate by name, so the glue's
    // entry point must survive a linker that sees nothing referring to it
    compile.root_module.linkSystemLibrary("log", .{});
    compile.root_module.linkSystemLibrary("android", .{});
    compile.root_module.linkSystemLibrary("EGL", .{});
    compile.root_module.linkSystemLibrary("GLESv2", .{});
    compile.root_module.linkSystemLibrary("m", .{});
    compile.root_module.linkSystemLibrary("dl", .{});
    compile.root_module.link_libc = true;
    compile.link_emit_relocs = false;
    compile.rdynamic = true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    const frontend = b.option(
        Frontend,
        "frontend",
        "Select the frontend",
    ) orelse .raylib;

    const atlas_path = b.option(
        []const u8,
        "atlas",
        "Path to the texture atlas descriptor (see src/blocks/atlas.zig)",
    ) orelse "src/blocks/atlas.zig";

    const mesher_threads = b.option(
        u32,
        "mesher-threads",
        "Number of chunk meshing worker threads (0 = pick from the cpu count)",
    ) orelse 0;

    // Android is not a target you can just point zig at: the libc is the NDK's,
    // and so are the headers, the crt and the glue that turns a shared library
    // into an app. The path is a build option rather than a guess because there
    // is no sensible place for it to live.
    const android_ndk = b.option(
        []const u8,
        "android-ndk",
        "Path to the Android NDK, for -Dtarget=aarch64-linux-android and friends",
    ) orelse std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME") catch "";

    const android_api = b.option(
        []const u8,
        "android-api",
        "Android API level to build against (21 is Android 5.0, which is as far back as a current NDK goes)",
    ) orelse "21";

    const is_android = target.result.abi.isAndroid();

    const build_options = b.addOptions();
    build_options.addOption(u32, "mesher_threads", mesher_threads);

    // Dependencies
    const network_dep = b.dependency("network", .{});
    const spsc_queue_dep = b.dependency("spsc_queue", .{});
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        // Ignored unless the target is Android. Left at the default OpenGL
        // version on purpose: for Android that is GL ES 2.0, which is what
        // every device made since about 2010 can run.
        .android_ndk = android_ndk,
        .android_api_version = android_api,
    });
    const tracy_dep = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    const tracy_impl_mod = if (tracy_enabled) tracy_dep.module("tracy_impl_enabled") else tracy_dep.module("tracy_impl_disabled");

    // Internal modules
    const inv_mod = b.addModule("inventory", .{
        .root_source_file = b.path("src/inventory/inventory.zig"),
        .target = target,
    });

    const coord_mod = b.addModule("coord", .{
        .root_source_file = b.path("src/coord/coord.zig"),
        .target = target,
    });

    const terrain_mod = b.addModule("terrain", .{
        .root_source_file = b.path("src/terrain/terrain.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "coord", .module = coord_mod },
            .{ .name = "tracy", .module = tracy_dep.module("tracy") },
        },
    });

    // The atlas descriptor is a swappable module: point the build at a generated
    // file to change the texture atlas layout without touching any other code
    const atlas_mod = b.addModule("atlas", .{
        .root_source_file = b.path(atlas_path),
        .target = target,
    });

    const blocks_mod = b.addModule("blocks", .{
        .root_source_file = b.path("src/blocks/blocks.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "coord", .module = coord_mod },
            .{ .name = "atlas", .module = atlas_mod },
        },
    });
    terrain_mod.addImport("blocks", blocks_mod);

    const meshing_mod = b.addModule("meshing", .{
        .root_source_file = b.path("src/meshing/meshing.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "blocks", .module = blocks_mod },
            .{ .name = "coord", .module = coord_mod },
            .{ .name = "terrain", .module = terrain_mod },
            .{ .name = "tracy", .module = tracy_dep.module("tracy") },
        },
    });

    // The world drives the meshing pipeline, and needs to know how many worker
    // threads to start
    terrain_mod.addImport("meshing", meshing_mod);
    terrain_mod.addImport("build_options", build_options.createModule());

    const worldgen_mod = b.addModule("worldgen", .{
        .root_source_file = b.path("src/worldgen/worldgen.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "coord", .module = coord_mod },
            .{ .name = "blocks", .module = blocks_mod },
            .{ .name = "terrain", .module = terrain_mod },
        },
    });

    const raylib_io_mod = b.addModule("io", .{
        .root_source_file = b.path("src/frontend/raylib/io.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "raylib", .module = raylib_dep.module("raylib") },
            .{ .name = "raygui", .module = raylib_dep.module("raygui") },
        },
    });
    raylib_io_mod.linkLibrary(raylib_dep.artifact("raylib"));

    const dummy_io_mod = b.addModule("io", .{
        .root_source_file = b.path("src/frontend/dummy/io.zig"),
        .target = target,
    });

    const io_mod = switch (frontend) {
        .dummy => dummy_io_mod,
        .raylib => raylib_io_mod,
    };
    io_mod.addImport("terrain", terrain_mod);
    io_mod.addImport("coord", coord_mod);
    io_mod.addImport("blocks", blocks_mod);
    io_mod.addImport("meshing", meshing_mod);
    io_mod.addImport("tracy", tracy_dep.module("tracy"));
    terrain_mod.addImport("io", io_mod);
    meshing_mod.addImport("io", io_mod);

    const net_mod = b.addModule("net", .{
        .root_source_file = b.path("src/net/net.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "inventory", .module = inv_mod },
        },
    });

    const engine_mod = b.addModule("engine", .{
        .root_source_file = b.path("src/engine/engine.zig"),
        .target = target,
        .imports = &.{
            // Internal
            .{ .name = "net", .module = net_mod },
            .{ .name = "inventory", .module = inv_mod },
            .{ .name = "io", .module = io_mod },
            .{ .name = "coord", .module = coord_mod },
            .{ .name = "terrain", .module = terrain_mod },
            .{ .name = "blocks", .module = blocks_mod },
            .{ .name = "worldgen", .module = worldgen_mod },
            // Dependencies
            .{ .name = "network", .module = network_dep.module("network") },
            .{ .name = "spsc_queue", .module = spsc_queue_dep.module("spsc_queue") },
            .{ .name = "tracy", .module = tracy_dep.module("tracy") },
        },
    });

    net_mod.addImport("engine", engine_mod);
    io_mod.addImport("engine", engine_mod);

    // Client executable
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            // Internal
            .{ .name = "io", .module = io_mod },
            // Dependencies
            .{ .name = "network", .module = network_dep.module("network") },
            .{ .name = "tracy", .module = tracy_dep.module("tracy") },
        },
    });

    root_mod.addImport("tracy_impl", tracy_impl_mod);

    // An Android app is a shared library that the system's NativeActivity opens
    // and calls ANativeActivity_onCreate in. That symbol comes from the NDK's
    // glue, which raylib expects to be there but does not build, so it is
    // compiled in here.
    const exe = if (is_android) b.addLibrary(.{
        .name = "maincraft",
        .linkage = .dynamic,
        .root_module = root_mod,
    }) else b.addExecutable(.{
        .name = "maincraft",
        .root_module = root_mod,
    });

    if (is_android) {
        addAndroidSupport(b, exe, target, android_ndk, android_api);
        // ...and to raylib, whose own copy of this file comes out empty
        addAndroidSupport(b, raylib_dep.artifact("raylib"), target, android_ndk, android_api);
    }

    b.installArtifact(exe);

    // STEPS

    // Run step and command
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Module tests
    const net_mod_tests = b.addTest(.{
        .root_module = net_mod,
    });
    const run_net_tests = b.addRunArtifact(net_mod_tests);

    const inv_mod_tests = b.addTest(.{
        .root_module = inv_mod,
    });
    const run_inv_tests = b.addRunArtifact(inv_mod_tests);

    const io_mod_tests = b.addTest(.{
        .root_module = io_mod,
    });
    const run_io_tests = b.addRunArtifact(io_mod_tests);

    const coord_mod_tests = b.addTest(.{
        .root_module = coord_mod,
    });
    const run_coord_tests = b.addRunArtifact(coord_mod_tests);

    const terrain_mod_tests = b.addTest(.{
        .root_module = terrain_mod,
    });
    const run_terrain_tests = b.addRunArtifact(terrain_mod_tests);

    const blocks_mod_tests = b.addTest(.{
        .root_module = blocks_mod,
    });
    const run_blocks_tests = b.addRunArtifact(blocks_mod_tests);

    const meshing_mod_tests = b.addTest(.{
        .root_module = meshing_mod,
    });
    const run_meshing_tests = b.addRunArtifact(meshing_mod_tests);

    const worldgen_mod_tests = b.addTest(.{
        .root_module = worldgen_mod,
    });
    const run_worldgen_tests = b.addRunArtifact(worldgen_mod_tests);

    const engine_mod_tests = b.addTest(.{
        .root_module = engine_mod,
    });
    const run_engine_tests = b.addRunArtifact(engine_mod_tests);

    // Client tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // All tests step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_net_tests.step);
    test_step.dependOn(&run_inv_tests.step);
    test_step.dependOn(&run_io_tests.step);
    test_step.dependOn(&run_coord_tests.step);
    test_step.dependOn(&run_terrain_tests.step);
    test_step.dependOn(&run_blocks_tests.step);
    test_step.dependOn(&run_meshing_tests.step);
    test_step.dependOn(&run_worldgen_tests.step);
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Individual test steps
    b.step("test_net", "Run net module tests").dependOn(&run_net_tests.step);
    b.step("test_inv", "Run inventory module tests").dependOn(&run_inv_tests.step);
    b.step("test_io", "Run game i/o module tests").dependOn(&run_io_tests.step);
    b.step("test_coord", "Run coordinates module tests").dependOn(&run_coord_tests.step);
    b.step("test_terrain", "Run terrain module tests").dependOn(&run_terrain_tests.step);
    b.step("test_blocks", "Run blocks module tests").dependOn(&run_blocks_tests.step);
    b.step("test_meshing", "Run meshing module tests").dependOn(&run_meshing_tests.step);
    b.step("test_worldgen", "Run world generation module tests").dependOn(&run_worldgen_tests.step);
    b.step("test_engine", "Run engine tests").dependOn(&run_engine_tests.step);
    b.step("test_exe", "Run NBT module tests").dependOn(&run_exe_tests.step);
}
