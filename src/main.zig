const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
});

pub var running = true;

pub fn process_events(window: *c.SDL_Window) void {
    _ = window;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                running = false;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;

                switch (key) {
                    c.SDLK_Q, c.SDLK_ESCAPE => {
                        running = false;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

pub fn update() void {}

pub fn render(window: *c.SDL_Window, gpu: *c.SDL_GPUDevice, pipeline: *c.SDL_GPUGraphicsPipeline) !void {
    const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(gpu) orelse {
        return error.CommandBufferAcquisitionFailed;
    };

    var swapchain_texture: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(
        cmd_buffer,
        window,
        &swapchain_texture,
        null,
        null,
    )) {
        return error.SwapchainAcquisitionFailed;
    }
    const render_pass = c.SDL_BeginGPURenderPass(
        cmd_buffer,
        &.{
            .texture = swapchain_texture,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .clear_color = .{
                .r = 0.0,
                .g = 0.2,
                .b = 0.4,
                .a = 1.0,
            },
            .store_op = c.SDL_GPU_STOREOP_STORE,
        },
        1,
        null,
    ) orelse {
        return error.RenderPassBeginFailed;
    };

    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
    c.SDL_DrawGPUPrimitives(render_pass, 6, 1, 0, 0);
    c.SDL_EndGPURenderPass(render_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer)) {
        return error.CommandBufferSubmissionFailed;
    }
}

pub fn main() !void {
    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();
    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_VERBOSE);

    const window = c.SDL_CreateWindow("Hello, SDL3", 1280, 720, 0) orelse {
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const gpu_device = c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV,
        true,
        null,
    ) orelse {
        return error.DeviceCreationFailed;
    };
    defer c.SDL_DestroyGPUDevice(gpu_device);

    if (!c.SDL_ClaimWindowForGPUDevice(gpu_device, window)) {
        return error.ClaimWindowFailed;
    }

    const vertex_shader = try loadShader(
        gpu_device,
        "assets/shaders/compiled/quad.vert.spv",
        c.SDL_GPU_SHADERSTAGE_VERTEX,
    );

    const fragment_shader = try loadShader(
        gpu_device,
        "assets/shaders/compiled/quad.frag.spv",
        c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    );

    const gpu_pipeline = c.SDL_CreateGPUGraphicsPipeline(gpu_device, &.{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &.{
                .format = c.SDL_GetGPUSwapchainTextureFormat(gpu_device, window),
            },
        },
    }) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Pipeline creation failed %s", c.SDL_GetError());
        return error.PipelineCreationFailed;
    };
    defer c.SDL_ReleaseGPUGraphicsPipeline(gpu_device, gpu_pipeline);

    c.SDL_ReleaseGPUShader(gpu_device, vertex_shader);
    c.SDL_ReleaseGPUShader(gpu_device, fragment_shader);

    while (running) {
        process_events(window);
        render(window, gpu_device, gpu_pipeline) catch |err| {
            c.SDL_LogError(
                c.SDL_LOG_CATEGORY_RENDER,
                "Render error: %s",
                &err,
            );
        };
    }
}

pub fn loadShader(gpu_device: *c.SDL_GPUDevice, comptime path: []const u8, stage: c.SDL_GPUShaderStage) !*c.SDL_GPUShader {
    const shader_code = @embedFile(path);

    return c.SDL_CreateGPUShader(gpu_device, &.{
        .code = shader_code.ptr,
        .code_size = shader_code.len,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = stage,
    }) orelse {
        return error.ShaderCreationFailed;
    };
}
