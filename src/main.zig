const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
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

pub fn gpu_render(window: *c.SDL_Window, gpu: *c.SDL_GPUDevice, pipeline: *c.SDL_GPUGraphicsPipeline) !void {
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

    const color_target_info: c.SDL_GPUColorTargetInfo = .{
        .texture = swapchain_texture,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .clear_color = .{
            .r = 0.3,
            .g = 0.0,
            .b = 0.3,
            .a = 1.0,
        },
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };
    const render_pass = c.SDL_BeginGPURenderPass(
        cmd_buffer,
        &color_target_info,
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

    const sprite_atlas = try loadTexture(gpu_device, "src/assets/textures/SPRITE_ATLAS.png");
    defer c.SDL_ReleaseGPUTexture(gpu_device, sprite_atlas);

    while (running) {
        process_events(window);
        gpu_render(window, gpu_device, gpu_pipeline) catch |err| {
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

pub fn loadTexture(device: *c.SDL_GPUDevice, comptime path: []const u8) !*c.SDL_GPUTexture {
    var surface = c.IMG_Load(@ptrCast(path)) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to load image: %s", c.SDL_GetError());
        return error.TextureLoadFailed;
    };
    defer c.SDL_DestroySurface(surface);

    if (surface.*.format != c.SDL_PIXELFORMAT_RGBA8888) {
        const converted = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA8888) orelse {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to convert image: %s", c.SDL_GetError());
            return error.TextureConversionFailed;
        };
        c.SDL_DestroySurface(surface);
        surface = converted;
    }

    const create_info: c.SDL_GPUTextureCreateInfo = .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = @intCast(surface.*.w),
        .height = @intCast(surface.*.h),
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    };

    const texture = c.SDL_CreateGPUTexture(
        device,
        &create_info,
    ) orelse {
        return error.TextureCreationFailed;
    };
    errdefer c.SDL_ReleaseGPUTexture(device, texture);

    const transfer_size: u32 = @intCast(surface.*.pitch * surface.*.h);
    const transfer_info: c.SDL_GPUTransferBufferCreateInfo = .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = transfer_size,
        .props = 0,
    };
    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to create transfer buffer: %s", c.SDL_GetError());
        return error.TransferBufferCreationFailed;
    };
    const mapped_data = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to map transfer buffer: %s", c.SDL_GetError());
        return error.TransferBufferMappingFailed;
    };
    const dst_ptr: [*]u8 = @ptrCast(mapped_data);
    const src_ptr: [*]const u8 = @ptrCast(surface.*.pixels);
    std.mem.copyForwards(u8, dst_ptr[0..transfer_size], src_ptr[0..transfer_size]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to acquire command buffer: %s", c.SDL_GetError());
        return error.CommandBufferAcquisitionFailed;
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buffer) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to begin copy pass: %s", c.SDL_GetError());
        return error.CopyPassBeginFailed;
    };

    const transfer_info2: c.SDL_GPUTextureTransferInfo = .{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
        .pixels_per_row = @intCast(surface.*.w),
        .rows_per_layer = @intCast(surface.*.h),
    };

    const texture_region: c.SDL_GPUTextureRegion = .{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = @intCast(surface.*.w),
        .h = @intCast(surface.*.h),
        .d = 1,
    };

    c.SDL_UploadToGPUTexture(copy_pass, &transfer_info2, &texture_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer)) {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to submit command buffer");
        return error.CommandBufferSubmissionFailed;
    }

    return texture;
}
