const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const target_os = target.result.os.tag;

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Check if shadercross is available
    const has_shadercross = blk: {
        const check_result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &[_][]const u8{ "which", "shadercross" },
            .cwd = ".",
        }) catch |err| {
            std.log.debug("Failed to check for shadercross: {}", .{err});
            break :blk false;
        };
        defer {
            b.allocator.free(check_result.stderr);
            b.allocator.free(check_result.stdout);
        }
        break :blk check_result.term.Exited == 0;
    };

    const shader_step = if (has_shadercross) shader_setup: {
        const step = b.step("shaders", "Compile shaders (requires shadercross)");

        const shader_source_dir = "assets/shaders/source";
        const shader_out_dir = "assets/shaders/compiled";

        const shader_types = [_]struct { extension: []const u8 }{
            .{ .extension = ".vert.hlsl" },
            .{ .extension = ".frag.hlsl" },
            .{ .extension = ".comp.hlsl" },
        };

        const shader_output_formats = [_]struct {
            extension: []const u8,
        }{
            .{ .extension = ".spv" },
            .{ .extension = ".msl" },
            .{ .extension = ".dxil" },
        };

        var shader_dir = std.fs.cwd().openDir(shader_source_dir, .{ .iterate = true }) catch |err| {
            std.log.err("Failed to open shader directory: {}", .{err});
            break :shader_setup step;
        };
        defer shader_dir.close();

        var shader_iter = shader_dir.iterate();

        while (shader_iter.next() catch |err| {
            std.log.err("Failed to iterate shader directory: {}", .{err});
            break :shader_setup step;
        }) |entry| {
            if (entry.kind != .file) continue;

            for (shader_types) |shader_input_type| {
                if (std.mem.endsWith(u8, entry.name, shader_input_type.extension)) {
                    const output_file_basename = entry.name[0 .. entry.name.len - 5];

                    for (shader_output_formats) |output_format| {
                        const shader_cmd = b.addSystemCommand(&.{
                            "shadercross",
                            entry.name,
                            "-o",
                            b.fmt(
                                "../{s}/{s}{s}",
                                .{
                                    std.fs.path.basename(shader_out_dir),
                                    output_file_basename,
                                    output_format.extension,
                                },
                            ),
                        });
                        shader_cmd.setCwd(b.path(shader_source_dir));
                        step.dependOn(&shader_cmd.step);
                    }
                    break;
                }
            }
        }
        break :shader_setup step;
    } else b.step("shaders", "Compile shaders (shadercross not found - skipping)");

    // Make sure the executable is installed after the shader step
    b.getInstallStep().dependOn(shader_step);

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "zig_sdl3_gpu_api",
        .root_module = exe_mod,
    });

    exe.linkLibC();
    exe.linkSystemLibrary("SDL3");

    switch (target_os) {
        .linux, .macos => {},
        .windows => {
            if (optimize != .Debug) {
                exe.subsystem = .Windows;
            }
            exe.addLibraryPath(.{ .cwd_relative = "thirdparty/SDL3_3.2.14-win32-x64/" });
            const sdl_dll_dep = b.addInstallBinFile(
                b.path("thirdparty/SDL3_3.2.14-win32-x64/SDL3.dll"),
                "SDL3.dll",
            );
            exe.step.dependOn(&sdl_dll_dep.step);
        },
        else => {
            std.log.debug("Unsupported target OS: {}", .{target_os});
            return;
        },
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // Make sure the executable is installed after the shader step
    b.getInstallStep().dependOn(shader_step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
