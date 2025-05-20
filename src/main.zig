const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
});

const IMAGES_BASE_PATH = "assets/images/";
const SPRITE_COUNT: u32 = 8192;
const Matrix4x4 = [4][4]f32;

const SpriteInstance = packed struct {
    x: f32, y: f32, z: f32, rotation: f32,
    w: f32, h: f32, padding_a: f32, padding_b: f32,
    tex_u: f32, tex_v: f32, tex_w: f32, tex_h: f32,
    r: f32, g: f32, b: f32, a: f32,
};

const u_coords: [4]f32 = .{ 0.0, 0.5, 0.0, 0.5 };
const v_coords: [4]f32 = .{ 0.0, 0.0, 0.5, 0.5 };

pub fn createOrtographicOffCenter(
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    z_near_plane: f32,
    z_far_plane: f32,
) Matrix4x4 {
    return .{
        .{ 2 / (right - left), 0, 0, 0 },
        .{ 0, 2 / (top - bottom), 0, 0 },
        .{ 0, 0, 1.0 / (z_near_plane - z_far_plane), 0 },
        .{ (left + right) / (left - right), (top + bottom) / (bottom - top), z_near_plane / (z_near_plane - z_far_plane), 1 },
    };
}

pub fn loadImage(image_filename: []const u8, desired_channels: u32) !*c.SDL_Surface {
    var full_path_buf: [256]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_path_buf, "{s}{s}", .{ IMAGES_BASE_PATH, image_filename });

    const result = c.SDL_LoadBMP(full_path.ptr) orelse {
        c.SDL_Log("Failed to load BMP: %s", c.SDL_GetError());
        return error.LoadBMPFailed;
    };
    errdefer c.SDL_DestroySurface(result);

    const format = switch (desired_channels) {
        4 => c.SDL_PIXELFORMAT_ABGR8888,
        else => {
            c.SDL_Log("Unexpected desired_channels: %d", desired_channels);
            return error.UnsupportedChannelCount;
        },
    };

    if (result.*.format != format) {
        const converted = c.SDL_ConvertSurface(result, format) orelse {
            c.SDL_Log("Failed to convert surface: %s", c.SDL_GetError());
            return error.SurfaceConversionFailed;
        };
        c.SDL_DestroySurface(result);
        return converted;
    }

    return result;
}

pub fn loadShader(
    device: *c.SDL_GPUDevice,
    comptime shader_name: []const u8,
    sampler_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    storage_texture_count: u32,
) !*c.SDL_GPUShader {
    const stage: c.SDL_GPUShaderStage =
        if (c.SDL_strstr(shader_name.ptr, ".vert") != null)
            c.SDL_GPU_SHADERSTAGE_VERTEX
        else if (c.SDL_strstr(shader_name.ptr, ".frag") != null)
            c.SDL_GPU_SHADERSTAGE_FRAGMENT
        else {
            c.SDL_Log("Invalid shader stage for file: %s", &shader_name);
            return error.InvalidShaderStage;
        };

    const backend_formats = c.SDL_GetGPUShaderFormats(device);
    var format: c.SDL_GPUShaderFormat = c.SDL_GPU_SHADERFORMAT_INVALID;
    var extension: []const u8 = undefined;
    var entrypoint: []const u8 = "main";

    if (backend_formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
        format = c.SDL_GPU_SHADERFORMAT_SPIRV;
        extension = ".spv";
    } else if (backend_formats & c.SDL_GPU_SHADERFORMAT_DXIL != 0) {
        format = c.SDL_GPU_SHADERFORMAT_DXIL;
        extension = ".dxil";
    } else if (backend_formats & c.SDL_GPU_SHADERFORMAT_MSL != 0) {
        format = c.SDL_GPU_SHADERFORMAT_MSL;
        extension = ".msl";
        entrypoint = "main0";
    } else {
        c.SDL_Log("Unrecognized shader format for file: %s", &shader_name);
        return error.NoSupportedShaderFormats;
    }

    var shader_path_buf: [256]u8 = undefined;
    const shader_path = try std.fmt.bufPrintZ(&shader_path_buf, "assets/shaders/compiled/{s}{s}", .{ shader_name, extension });

    var code_size: usize = 0;
    const code = c.SDL_LoadFile(shader_path.ptr, &code_size) orelse {
        c.SDL_Log("Failed to load shader file: %s", shader_path.ptr);
        return error.ShaderFileLoadFailed;
    };
    defer c.SDL_free(code);

    return c.SDL_CreateGPUShader(device, &.{
        .code = @ptrCast(code),
        .code_size = code_size,
        .entrypoint = entrypoint.ptr,
        .format = format,
        .stage = stage,
        .num_samplers = sampler_count,
        .num_uniform_buffers = uniform_buffer_count,
        .num_storage_buffers = storage_buffer_count,
        .num_storage_textures = storage_texture_count,
    }) orelse {
        return error.ShaderCreationFailed;
    };
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDL_InitFailed;
    }
    defer c.SDL_Quit();
    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_VERBOSE);

    const window = c.SDL_CreateWindow(
        "Hello, World!",
        640,
        480,
        c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const device = c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL,
        true,
        null,
    ) orelse {
        c.SDL_Log("SDL_CreateGPUDevice failed: %s", c.SDL_GetError());
        return error.DeviceCreationFailed;
    };
    defer c.SDL_DestroyGPUDevice(device);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        c.SDL_Log("SDL_ClaimWindowForGPUDevice failed: %s", c.SDL_GetError());
        return error.ClaimWindowFailed;
    }
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    if (!c.SDL_ShowWindow(window)) {
        c.SDL_Log("SDL_ShowWindow failed: %s", c.SDL_GetError());
        return error.WindowShowFailed;
    }

    const present_mode: c.SDL_GPUPresentMode = if (c.SDL_WindowSupportsGPUPresentMode(
        device,
        window,
        c.SDL_GPU_PRESENTMODE_MAILBOX,
    ))
        c.SDL_GPU_PRESENTMODE_MAILBOX
    else if (c.SDL_WindowSupportsGPUPresentMode(
        device,
        window,
        c.SDL_GPU_PRESENTMODE_IMMEDIATE,
    ))
        c.SDL_GPU_PRESENTMODE_IMMEDIATE
    else
        c.SDL_GPU_PRESENTMODE_VSYNC;

    if (!c.SDL_SetGPUSwapchainParameters(
        device,
        window,
        c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
        present_mode,
    )) {
        c.SDL_Log("SDL_SetGPUSwapchainParameters failed");
    }

    c.SDL_srand(0);

    const vertex_shader = try loadShader(
        device,
        "pull-sprite-batch.vert",
        0,
        1,
        1,
        0,
    );

    const frag_shader = try loadShader(
        device,
        "textured-quad-color.frag",
        1,
        0,
        0,
        0,
    );

    const color_target_descriptions = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
        .blend_state = .{
            .enable_blend = true,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        },
    };

    const render_pipeline = c.SDL_CreateGPUGraphicsPipeline(
        device,
        &.{
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &color_target_descriptions,
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .vertex_shader = vertex_shader,
            .fragment_shader = frag_shader,
        },
    ) orelse {
        c.SDL_ReleaseGPUShader(device, vertex_shader);
        c.SDL_ReleaseGPUShader(device, frag_shader);
        c.SDL_Log("SDL_CreateGPUGraphicsPipeline failed: %s", c.SDL_GetError());
        return error.GraphicsPipelineCreationFailed;
    };
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, render_pipeline);

    c.SDL_ReleaseGPUShader(device, vertex_shader);
    c.SDL_ReleaseGPUShader(device, frag_shader);

    const image_data = try loadImage("ravioli_atlas.bmp", 4);

    const texture_transfer_buffer = c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @intCast(image_data.*.pitch * image_data.*.h),
        },
    ) orelse {
        c.SDL_Log("SDL_CreateGPUTransferBuffer failed: %s", c.SDL_GetError());
        return error.TransferBufferCreationFailed;
    };

    const texture_transfer_ptr = c.SDL_MapGPUTransferBuffer(
        device,
        texture_transfer_buffer,
        false,
    ) orelse {
        c.SDL_Log("SDL_MapGPUTransferBuffer failed: %s", c.SDL_GetError());
        return error.TransferBufferMappingFailed;
    };

    _ = c.SDL_memcpy(texture_transfer_ptr, image_data.pixels, @intCast(image_data.w * image_data.h * 4));
    c.SDL_UnmapGPUTransferBuffer(device, texture_transfer_buffer);

    const texture = c.SDL_CreateGPUTexture(
        device,
        &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .width = @intCast(image_data.w),
            .height = @intCast(image_data.h),
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        },
    ) orelse {
        c.SDL_Log("SDL_CreateGPUTexture failed: %s", c.SDL_GetError());
        return error.TextureCreationFailed;
    };
    defer c.SDL_ReleaseGPUTexture(device, texture);

    const sampler = c.SDL_CreateGPUSampler(
        device,
        &.{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = c.SDL_GPU_FILTER_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        },
    ) orelse {
        c.SDL_Log("SDL_CreateGPUSampler failed: %s", c.SDL_GetError());
        return error.SamplerCreationFailed;
    };
    defer c.SDL_ReleaseGPUSampler(device, sampler);

    const sprite_data_transfer_buffer = c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
        },
    ) orelse {
        c.SDL_Log("SDL_CreateGPUTransferBuffer failed: %s", c.SDL_GetError());
        return error.SpriteDataTransferBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(device, sprite_data_transfer_buffer);

    const sprite_data_buffer = c.SDL_CreateGPUBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
        },
    ) orelse {
        c.SDL_Log("SDL_CreateGPUBuffer failed: %s", c.SDL_GetError());
        return error.SpriteDataBufferCreationFailed;
    };
    defer c.SDL_ReleaseGPUBuffer(device, sprite_data_buffer);

    const upload_cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_Log("SDL_AcquireGPUCommandBuffer failed: %s", c.SDL_GetError());
        return error.CommandBufferAcquisitionFailed;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd_buf) orelse {
        c.SDL_Log("SDL_BeginGPUCopyPass failed: %s", c.SDL_GetError());
        return error.CopyPassCreationFailed;
    };

    c.SDL_UploadToGPUTexture(
        copy_pass,
        &.{
            .transfer_buffer = texture_transfer_buffer,
            .offset = 0,
        },
        &.{
            .texture = texture,
            .w = @intCast(image_data.w),
            .h = @intCast(image_data.h),
            .d = 1,
        },
        false,
    );

    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf);

    c.SDL_DestroySurface(image_data);
    c.SDL_ReleaseGPUTransferBuffer(device, texture_transfer_buffer);

    var running: bool = true;
    var event: c.SDL_Event = undefined;

    while (running) {
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    running = false;
                },
                else => {},
            }
        }

        const camera_matrix = createOrtographicOffCenter(
            0,
            640,
            480,
            0,
            0,
            -1,
        );

        const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
            c.SDL_Log("SDL_AcquireGPUCommandBuffer failed: %s", c.SDL_GetError());
            return error.CommandBufferAcquisitionFailed;
        };

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buffer, window, @ptrCast(&swapchain_texture), null, null)) {
            c.SDL_Log("SDL_WaitAndAcquireGPUSwapchainTexture failed: %s", c.SDL_GetError());
            return error.SwapchainTextureAcquisitionFailed;
        }

        if (swapchain_texture != null) {
            const raw_ptr = c.SDL_MapGPUTransferBuffer(
                device,
                sprite_data_transfer_buffer,
                true,
            ) orelse {
                c.SDL_Log("SDL_MapGPUTransferBuffer failed: %s", c.SDL_GetError());
                return error.SpriteDataBufferMappingFailed;
            };
            const sprite_data_ptr: [*]SpriteInstance = @ptrCast(@alignCast(raw_ptr));

            var i: u32 = 0;
            while (i < SPRITE_COUNT) : (i += 1) {
                const ravioli = c.SDL_rand(4);
                sprite_data_ptr[i].x = @floatFromInt(c.SDL_rand(640));
                sprite_data_ptr[i].y = @floatFromInt(c.SDL_rand(480));
                sprite_data_ptr[i].z = 0;
                sprite_data_ptr[i].rotation = c.SDL_randf() * c.SDL_PI_F * 2;
                sprite_data_ptr[i].w = 32;
                sprite_data_ptr[i].h = 32;
                sprite_data_ptr[i].tex_u = u_coords[@intCast(ravioli)];
                sprite_data_ptr[i].tex_v = v_coords[@intCast(ravioli)];
                sprite_data_ptr[i].tex_w = 0.5;
                sprite_data_ptr[i].tex_h = 0.5;
                sprite_data_ptr[i].r = 1.0;
                sprite_data_ptr[i].g = 1.0;
                sprite_data_ptr[i].b = 1.0;
                sprite_data_ptr[i].a = 1.0;
            }
            c.SDL_UnmapGPUTransferBuffer(device, sprite_data_transfer_buffer);

            const copy_pass2 = c.SDL_BeginGPUCopyPass(cmd_buffer) orelse {
                c.SDL_Log("SDL_BeginGPUCopyPass failed: %s", c.SDL_GetError());
                return error.CopyPassCreationFailed;
            };
            c.SDL_UploadToGPUBuffer(
                copy_pass2,
                &.{
                    .transfer_buffer = sprite_data_transfer_buffer,
                    .offset = 0,
                },
                &.{
                    .buffer = sprite_data_buffer,
                    .offset = 0,
                    .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
                },
                true,
            );
            c.SDL_EndGPUCopyPass(copy_pass2);

            const render_pass = c.SDL_BeginGPURenderPass(
                cmd_buffer,
                &.{
                    .texture = swapchain_texture,
                    .cycle = false,
                    .load_op = c.SDL_GPU_LOADOP_CLEAR,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                    .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
                },
                1,
                null,
            ) orelse {
                c.SDL_Log("SDL_BeginGPURenderPass failed: %s", c.SDL_GetError());
                return error.RenderPassCreationFailed;
            };

            c.SDL_BindGPUGraphicsPipeline(render_pass, render_pipeline);
            c.SDL_BindGPUVertexStorageBuffers(
                render_pass,
                0,
                &sprite_data_buffer,
                1,
            );
            c.SDL_BindGPUFragmentSamplers(
                render_pass,
                0,
                &.{
                    .texture = texture,
                    .sampler = sampler,
                },
                1,
            );
            c.SDL_PushGPUVertexUniformData(
                cmd_buffer,
                0,
                &camera_matrix,
                @sizeOf(Matrix4x4),
            );
            c.SDL_DrawGPUPrimitives(
                render_pass,
                SPRITE_COUNT * 6,
                1,
                0,
                0,
            );
            c.SDL_EndGPURenderPass(render_pass);
        }

        if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer)) {
            c.SDL_Log("SDL_SubmitGPUCommandBuffer failed: %s", c.SDL_GetError());
            return error.CommandBufferSubmissionFailed;
        }
    }
}
