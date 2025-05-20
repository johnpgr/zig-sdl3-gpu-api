const std = @import("std");
const utils = @import("utils.zig");

const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
});

pub const WIDTH = 1280;
pub const HEIGHT = 720;
pub var global_running: bool = true;
pub var global_window: *c.SDL_Window = undefined;
pub var global_device: *c.SDL_GPUDevice = undefined;
pub var global_pipeline: *c.SDL_GPUGraphicsPipeline = undefined;

pub fn drawScene() void { }

pub fn handleAppEvent(event: *c.SDL_Event) void {
    while (c.SDL_PollEvent(event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                global_running = false;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;

                switch (key) {
                    c.SDLK_Q, c.SDLK_ESCAPE => {
                        global_running = false;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_VERBOSE);

    const device = c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL,
        true,
        null,
    ) orelse {
        return error.DeviceCreationFailed;
    };
    errdefer c.SDL_DestroyGPUDevice(device);

    const window = c.SDL_CreateWindow("Hello, SDL3", 1280, 720, 0) orelse {
        return error.WindowCreationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    defer {
        c.SDL_ReleaseWindowFromGPUDevice(device, window);
        c.SDL_DestroyWindow(window);
        c.SDL_DestroyGPUDevice(device);
    }

    while (global_running) {
        var event: *c.SDL_Event = undefined;
        handleAppEvent(&event);
    }

    var present_mode: c.SDL_GPUPresentMode = c.SDL_GPU_PRESENTMODE_VSYNC;
    if (c.SDL_WindowSupportsGPUPresentMode(device, window, c.SDL_GPU_PRESENTMODE_IMMEDIATE)) {
        present_mode = c.SDL_GPU_PRESENTMODE_IMMEDIATE;
    } else if (c.SDL_WindowSupportsGPUPresentMode(device, window, c.SDL_GPU_PRESENTMODE_MAILBOX)) {
        present_mode = c.SDL_GPU_PRESENTMODE_MAILBOX;
    }

    if (!c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, present_mode)) {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to set swapchain parameters: %s", c.SDL_GetError());
        return error.SwapchainParametersFailed;
    }

    const vert_shader = try utils.loadShader(
        device,
        "assets/shaders/compiled/quad.vert.spv",
        0,
        0,
        0,
        0,
    );

    const frag_shader = try utils.loadShader(
        device,
        "assets/shaders/compiled/quad.frag.spv",
        0,
        0,
        0,
        0,
    );

    const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &.{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &.{
                .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
            },
        },
    }) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Pipeline creation failed %s", c.SDL_GetError());
        return error.PipelineCreationFailed;
    };
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    c.SDL_ReleaseGPUShader(device, vert_shader);
    c.SDL_ReleaseGPUShader(device, frag_shader);

    const sprite_atlas = try utils.loadGPUTexture(device, "assets/textures/SPRITE_ATLAS.png");
    defer c.SDL_ReleaseGPUTexture(device, sprite_atlas);

    while (global_running) {
        var event: c.SDL_Event = undefined;
        handleAppEvent(&event);
        drawScene() catch |err| {
            c.SDL_LogError(
                c.SDL_LOG_CATEGORY_RENDER,
                "Render error: %s",
                &err,
            );
        };
    }
}
