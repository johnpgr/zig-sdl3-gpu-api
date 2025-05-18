const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

pub var running = true;

pub fn processEvents(window: *c.SDL_Window) void {
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
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "SDL_Init failed: %s", c.SDL_GetError());
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

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        return error.ClaimWindowFailed;
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

    const vert_shader = try loadShader(
        device,
        "assets/shaders/compiled/quad.vert.spv",
        0,
        0,
        0,
        0,
    );

    const frag_shader = try loadShader(
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

    const sprite_atlas = try loadTexture(device, "assets/textures/SPRITE_ATLAS.png");
    defer c.SDL_ReleaseGPUTexture(device, sprite_atlas);

    while (running) {
        processEvents(window);
        render(window, device, pipeline) catch |err| {
            c.SDL_LogError(
                c.SDL_LOG_CATEGORY_RENDER,
                "Render error: %s",
                &err,
            );
        };
    }
}

pub fn loadShader(
    device: *c.SDL_GPUDevice,
    comptime filepath: []const u8,
    sampler_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    storage_texture_count: u32,
) !*c.SDL_GPUShader {
    const stage: c.SDL_GPUShaderStage =
        if (c.SDL_strstr(filepath.ptr, ".vert") != null)
            c.SDL_GPU_SHADERSTAGE_VERTEX
        else if (c.SDL_strstr(filepath.ptr, ".frag") != null)
            c.SDL_GPU_SHADERSTAGE_FRAGMENT
        else {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Invalid shader stage for file: %s", &filepath);
            return error.InvalidShaderStage;
        };

    const backend_formats = c.SDL_GetGPUShaderFormats(device);
    var format: c.SDL_GPUShaderFormat = c.SDL_GPU_SHADERFORMAT_INVALID;
    var entrypoint: []const u8 = "main";

    if (backend_formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
        format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    } else if (backend_formats & c.SDL_GPU_SHADERFORMAT_DXIL != 0) {
        format = c.SDL_GPU_SHADERFORMAT_DXIL;
    } else if (backend_formats & c.SDL_GPU_SHADERFORMAT_MSL != 0) {
        format = c.SDL_GPU_SHADERFORMAT_MSL;
        entrypoint = "main0";
    } else {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Unrecognized shader format for file: %s", &filepath);
        return error.NoSupportedShaderFormats;
    }

    var code_size: usize = 0;
    const code = c.SDL_LoadFile(filepath.ptr, &code_size) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to load shader file: %s", &filepath);
        return error.ShaderFileLoadFailed;
    };
    defer c.SDL_free(code);

    const create_info: c.SDL_GPUShaderCreateInfo = .{
        .code = @ptrCast(code),
        .code_size = code_size,
        .entrypoint = entrypoint.ptr,
        .format = format,
        .stage = stage,
        .num_samplers = sampler_count,
        .num_uniform_buffers = uniform_buffer_count,
        .num_storage_buffers = storage_buffer_count,
        .num_storage_textures = storage_texture_count,
    };
    return c.SDL_CreateGPUShader(device, &create_info) orelse {
        return error.ShaderCreationFailed;
    };
}

pub fn convertSurfacePixelFormat(surface: *[*c]c.SDL_Surface, pixel_format: c.SDL_PixelFormat) !void {
    if (surface.*.*.format != pixel_format) {
        const converted = c.SDL_ConvertSurface(surface.*, pixel_format) orelse {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to convert image: %s", c.SDL_GetError());
            return error.SurfaceConversionFailed;
        };
        c.SDL_DestroySurface(surface.*);
        surface.* = converted;
    }
}

pub fn loadTexture(device: *c.SDL_GPUDevice, comptime path: []const u8) !*c.SDL_GPUTexture {
    var surface = c.IMG_Load(@ptrCast(path)) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to load image: %s", c.SDL_GetError());
        return error.TextureLoadFailed;
    };
    defer c.SDL_DestroySurface(surface);

    if (surface.*.format != c.SDL_PIXELFORMAT_RGBA8888) {
        try convertSurfacePixelFormat(&surface, c.SDL_PIXELFORMAT_RGBA8888);
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

    const texture_data_size: u32 = @intCast(surface.*.pitch * surface.*.h);
    const transfer_info: c.SDL_GPUTransferBufferCreateInfo = .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = texture_data_size,
        .props = 0,
    };
    const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &transfer_info) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to create transfer buffer: %s", c.SDL_GetError());
        return error.TransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);
    const mapped_data = c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to map transfer buffer: %s", c.SDL_GetError());
        return error.TransferBufferMappingFailed;
    };
    const texture_data = @as([*]u8, @ptrCast(mapped_data))[0..texture_data_size];
    const source_data = @as([*]const u8, @ptrCast(surface.*.pixels))[0..texture_data_size];
    std.mem.copyForwards(u8, texture_data, source_data);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    try uploadTextureData(
        device,
        transfer_buffer,
        texture,
        @intCast(surface.*.w),
        @intCast(surface.*.h),
    );

    return texture;
}

fn uploadTextureData(
    device: *c.SDL_GPUDevice,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
) !void {
    const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to acquire command buffer: %s", c.SDL_GetError());
        return error.CommandBufferAcquisitionFailed;
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buffer) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to begin copy pass: %s", c.SDL_GetError());
        return error.CopyPassBeginFailed;
    };

    const transfer_info: c.SDL_GPUTextureTransferInfo = .{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
        .pixels_per_row = width,
        .rows_per_layer = height,
    };

    const texture_region: c.SDL_GPUTextureRegion = .{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = width,
        .h = height,
        .d = 1,
    };

    c.SDL_UploadToGPUTexture(copy_pass, &transfer_info, &texture_region, false);
    c.SDL_EndGPUCopyPass(copy_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer)) {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to submit command buffer");
        return error.CommandBufferSubmissionFailed;
    }
}
