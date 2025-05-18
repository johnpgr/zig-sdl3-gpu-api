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

    // Ensure shader output directory exists
    const make_shader_dir = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        "assets/shaders/compiled",
    });

    // Create shader compilation steps
    const vertex_shader = b.addSystemCommand(&.{
        "glslc",
        "assets/shaders/quad.vert",
        "-o",
        "assets/shaders/compiled/quad.vert.spv",
    });
    vertex_shader.step.dependOn(&make_shader_dir.step);

    const fragment_shader = b.addSystemCommand(&.{
        "glslc",
        "assets/shaders/quad.frag",
        "-o",
        "assets/shaders/compiled/quad.frag.spv",
    });
    fragment_shader.step.dependOn(&make_shader_dir.step);

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

    switch (target_os) {
        .macos => {
            exe.linkSystemLibrary("SDL3");
            exe.linkSystemLibrary("SDL3_image");
            exe.linkSystemLibrary("vulkan");
            exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
            exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        },
        .linux => {
            exe.linkLibC();
            exe.linkSystemLibrary("SDL3");
            exe.linkSystemLibrary("SDL3_image");
            exe.linkSystemLibrary("SDL3_ttf");
            exe.linkSystemLibrary("vulkan");
        },
        .windows => {
            if(optimize != .Debug) {
                exe.subsystem = .Windows;
            }

            exe.linkLibC();
            exe.linkSystemLibrary("SDL3");
            exe.linkSystemLibrary("SDL3_image");
            exe.linkSystemLibrary("SDL3_ttf");
            exe.linkSystemLibrary("vulkan-1");
            
            exe.addLibraryPath(.{ .cwd_relative = "thirdparty/SDL3_3.2.14-win32-x64/" });
            exe.addLibraryPath(.{ .cwd_relative = "thirdparty/SDL3_image-3.2.4-win32-x64/" });
            exe.addLibraryPath(.{ .cwd_relative = "thirdparty/SDL3_ttf-3.2.2-win32-x64/" });
            exe.addLibraryPath(.{ .cwd_relative = "thirdparty/Vulkan_1.4.313.0-win32-x64/" });

            const sdl_dll_dep = b.addInstallBinFile(
                b.path("thirdparty/SDL3_3.2.14-win32-x64/SDL3.dll"),
                "SDL3.dll",
            );
            const sdl_image_dll_dep = b.addInstallBinFile(
                b.path("thirdparty/SDL3_image-3.2.4-win32-x64/SDL3_image.dll"),
                "SDL3_image.dll",
            );
            const sdl_ttf_dll_dep = b.addInstallBinFile(
                b.path("thirdparty/SDL3_ttf-3.2.2-win32-x64/SDL3_ttf.dll"),
                "SDL3_ttf.dll",
            );
            exe.step.dependOn(&sdl_dll_dep.step);
            exe.step.dependOn(&sdl_image_dll_dep.step);
            exe.step.dependOn(&sdl_ttf_dll_dep.step);
        },
        else => {
            std.log.debug("Unsupported target OS: {}", .{target_os});
            return;
        },
    }

    // Make the executable depend on shader compilation
    exe.step.dependOn(&vertex_shader.step);
    exe.step.dependOn(&fragment_shader.step);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

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
