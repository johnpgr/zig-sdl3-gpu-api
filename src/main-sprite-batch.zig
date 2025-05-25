const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const IMAGES_BASE_PATH = "assets/images/";
const SPRITE_COUNT: u32 = 8192;
const Matrix4x4 = [4][4]f32;

pub const Vertex = struct {
    x: f32,
    y: f32,
    z: f32,
    colour: c.SDL_FColor,
    uv: c.SDL_FPoint,
};

const SpriteInstance = packed struct {
    x: f32,
    y: f32,
    z: f32,
    rotation: f32,
    w: f32,
    h: f32,
    padding_a: f32,
    padding_b: f32,
    tex_u: f32,
    tex_v: f32,
    tex_w: f32,
    tex_h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
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
        .{
            (left + right) / (left - right),
            (top + bottom) / (bottom - top),
            z_near_plane / (z_near_plane - z_far_plane),
            1,
        },
    };
}

pub fn loadImage(image_filename: []const u8, desired_channels: u32) !*c.SDL_Surface {
    var full_path_buf: [256]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(
        &full_path_buf,
        "{s}{s}",
        .{ IMAGES_BASE_PATH, image_filename },
    );

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

const Game = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    render_pipeline: *c.SDL_GPUGraphicsPipeline,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    sprite_data_transfer_buffer: *c.SDL_GPUTransferBuffer,
    sprite_data_buffer: *c.SDL_GPUBuffer,
    running: bool,
    paused: bool,

    pub fn init() !Game {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
            return error.SDL_InitFailed;
        }
        errdefer c.SDL_Quit();

        c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_VERBOSE);

        if (!c.TTF_Init()) {
            c.SDL_Log("TTF_Init failed");
            return error.TTF_InitFailed;
        }
        errdefer c.TTF_Quit();

        const window = c.SDL_CreateWindow(
            "Hello, World!",
            640,
            480,
            c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse {
            c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
            return error.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        const device = c.SDL_CreateGPUDevice(
            c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL,
            true,
            null,
        ) orelse {
            c.SDL_Log("SDL_CreateGPUDevice failed: %s", c.SDL_GetError());
            return error.DeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            c.SDL_Log("SDL_ClaimWindowForGPUDevice failed: %s", c.SDL_GetError());
            return error.ClaimWindowFailed;
        }
        errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);

        if (!c.SDL_ShowWindow(window)) {
            c.SDL_Log("SDL_ShowWindow failed: %s", c.SDL_GetError());
            return error.WindowShowFailed;
        }

        const present_mode = setupPresentMode(device, window);
        _ = c.SDL_SetGPUSwapchainParameters(
            device,
            window,
            c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
            present_mode,
        );

        c.SDL_srand(0);

        const render_pipeline = try setupGraphicsPipeline(device, window);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, render_pipeline);

        const texture_data = try setupTextureData(device);
        errdefer {
            c.SDL_ReleaseGPUSampler(device, texture_data.sampler);
            c.SDL_ReleaseGPUTexture(device, texture_data.texture);
        }
        const sprite_buffers = try setupSpriteBuffers(device);
        errdefer {
            c.SDL_ReleaseGPUBuffer(device, sprite_buffers.storage_buffer);
            c.SDL_ReleaseGPUTransferBuffer(device, sprite_buffers.transfer_buffer);
        }

        return Game{
            .device = device,
            .window = window,
            .render_pipeline = render_pipeline,
            .texture = texture_data.texture,
            .sampler = texture_data.sampler,
            .sprite_data_transfer_buffer = sprite_buffers.transfer_buffer,
            .sprite_data_buffer = sprite_buffers.storage_buffer,
            .running = true,
            .paused = false,
        };
    }

    fn setupPresentMode(device: *c.SDL_GPUDevice, window: *c.SDL_Window) c.SDL_GPUPresentMode {
        if (c.SDL_WindowSupportsGPUPresentMode(device, window, c.SDL_GPU_PRESENTMODE_MAILBOX))
            return c.SDL_GPU_PRESENTMODE_MAILBOX;
        if (c.SDL_WindowSupportsGPUPresentMode(device, window, c.SDL_GPU_PRESENTMODE_IMMEDIATE))
            return c.SDL_GPU_PRESENTMODE_IMMEDIATE;
        return c.SDL_GPU_PRESENTMODE_VSYNC;
    }

    fn setupTextPipeline(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !*c.SDL_GPUGraphicsPipeline {
        const vertex_shader = try loadShader(device, "shader.vert", 0, 1, 0, 0); // Assuming 1 UBO for MVP
        defer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const frag_shader = try loadShader(device, "shader.frag", 1, 0, 0, 0); // 1 sampler
        defer c.SDL_ReleaseGPUShader(device, frag_shader);

        const color_target_descriptions = [_]c.SDL_GPUColorTargetDescription{
            .{
                .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
                .blend_state = .{
                    .enable_blend = true,
                    .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .color_write_mask = 0xF,
                    .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_DST_ALPHA,
                    .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                },
            },
        };
        const pipeline_crete_info = c.SDL_GPUGraphicsPipelineCreateInfo{
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &color_target_descriptions,
                .has_depth_stencil_target = false,
                .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            },
            .vertex_input_state = .{
                .num_vertex_buffers = 1,
                .vertex_buffer_descriptions = &[_]c.SDL_GPUVertexBufferDescription{
                    .{
                        .slot = 0,
                        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                        .instance_step_rate = 0,
                        .pitch = @sizeOf(Vertex),
                    },
                },
                .num_vertex_attributes = 3,
                .vertex_attributes = &[_]c.SDL_GPUVertexAttribute{
                    .{
                        .buffer_slot = 0,
                        .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                        .location = 0,
                        .offset = 0,
                    },
                    .{
                        .buffer_slot = 0,
                        .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                        .location = 1,
                        .offset = @sizeOf(f32) * 3,
                    },
                    .{
                        .buffer_slot = 0,
                        .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                        .location = 2,
                        .offset = @sizeOf(f32) * 7,
                    },
                },
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .vertex_shader = vertex_shader,
            .fragment_shader = frag_shader,
        };

        return c.SDL_CreateGPUGraphicsPipeline(
            device,
            &pipeline_crete_info,
        ) orelse return error.TextPipelineCreationFailed;
    }

    fn setupGraphicsPipeline(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !*c.SDL_GPUGraphicsPipeline {
        const vertex_shader = try loadShader(device, "pull-sprite-batch.vert", 0, 1, 1, 0);
        defer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const frag_shader = try loadShader(device, "textured-quad-color.frag", 1, 0, 0, 0);
        defer c.SDL_ReleaseGPUShader(device, frag_shader);

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

        return c.SDL_CreateGPUGraphicsPipeline(
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
        ) orelse return error.GraphicsPipelineCreationFailed;
    }

    fn setupTextureData(device: *c.SDL_GPUDevice) !struct { texture: *c.SDL_GPUTexture, sampler: *c.SDL_GPUSampler } {
        const image_data = try loadImage("ravioli_atlas.bmp", 4);
        defer c.SDL_DestroySurface(image_data);

        const texture_transfer_buffer = c.SDL_CreateGPUTransferBuffer(
            device,
            &.{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = @intCast(image_data.*.pitch * image_data.*.h),
            },
        ) orelse return error.TransferBufferCreationFailed;
        defer c.SDL_ReleaseGPUTransferBuffer(device, texture_transfer_buffer);

        const texture_transfer_ptr = c.SDL_MapGPUTransferBuffer(
            device,
            texture_transfer_buffer,
            false,
        ) orelse return error.TransferBufferMappingFailed;

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
        ) orelse return error.TextureCreationFailed;

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
        ) orelse return error.SamplerCreationFailed;

        const upload_cmd_buf = c.SDL_AcquireGPUCommandBuffer(device) orelse
            return error.CommandBufferAcquisitionFailed;

        const copy_pass = c.SDL_BeginGPUCopyPass(upload_cmd_buf) orelse
            return error.CopyPassCreationFailed;

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

        return .{ .texture = texture, .sampler = sampler };
    }

    fn setupSpriteBuffers(device: *c.SDL_GPUDevice) !struct { transfer_buffer: *c.SDL_GPUTransferBuffer, storage_buffer: *c.SDL_GPUBuffer } {
        const sprite_data_transfer_buffer = c.SDL_CreateGPUTransferBuffer(
            device,
            &.{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
            },
        ) orelse return error.SpriteDataTransferBufferCreationFailed;

        const sprite_data_buffer = c.SDL_CreateGPUBuffer(
            device,
            &.{
                .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
                .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
            },
        ) orelse return error.SpriteDataBufferCreationFailed;

        return .{
            .transfer_buffer = sprite_data_transfer_buffer,
            .storage_buffer = sprite_data_buffer,
        };
    }

    fn updateSprites(sprite_data: [*]SpriteInstance) void {
        var i: u32 = 0;
        while (i < SPRITE_COUNT) : (i += 1) {
            const ravioli = c.SDL_rand(4);
            sprite_data[i] = .{
                .x = @floatFromInt(c.SDL_rand(640)),
                .y = @floatFromInt(c.SDL_rand(480)),
                .z = 0,
                .rotation = c.SDL_randf() * c.SDL_PI_F * 2,
                .w = 64,
                .h = 64,
                .tex_u = u_coords[@intCast(ravioli)],
                .tex_v = v_coords[@intCast(ravioli)],
                .tex_w = 0.5,
                .tex_h = 0.5,
                .r = 1.0,
                .g = 1.0,
                .b = 1.0,
                .a = 1.0,
                .padding_a = 0,
                .padding_b = 0,
            };
        }
    }

    fn uploadSpriteData(self: *Game, cmd_buffer: *c.SDL_GPUCommandBuffer) !void {
        const raw_ptr = c.SDL_MapGPUTransferBuffer(
            self.device,
            self.sprite_data_transfer_buffer,
            true,
        ) orelse return error.SpriteDataBufferMappingFailed;

        const sprite_data_ptr: [*]SpriteInstance = @ptrCast(@alignCast(raw_ptr));
        Game.updateSprites(sprite_data_ptr);
        c.SDL_UnmapGPUTransferBuffer(self.device, self.sprite_data_transfer_buffer);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buffer) orelse return error.CopyPassCreationFailed;
        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &.{
                .transfer_buffer = self.sprite_data_transfer_buffer,
                .offset = 0,
            },
            &.{
                .buffer = self.sprite_data_buffer,
                .offset = 0,
                .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
            },
            true,
        );
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    fn render(self: *Game) !void {
        if (self.paused) return;

        const camera_matrix = createOrtographicOffCenter(0, 640, 480, 0, 0, -1);
        const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.CommandBufferAcquisitionFailed;

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buffer, self.window, @ptrCast(&swapchain_texture), null, null))
            return error.SwapchainTextureAcquisitionFailed;

        if (swapchain_texture) |texture| {
            try self.uploadSpriteData(cmd_buffer);

            const render_pass = c.SDL_BeginGPURenderPass(
                cmd_buffer,
                &.{
                    .texture = texture,
                    .cycle = false,
                    .load_op = c.SDL_GPU_LOADOP_CLEAR,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                    .clear_color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
                },
                1,
                null,
            ) orelse return error.RenderPassCreationFailed;

            c.SDL_BindGPUGraphicsPipeline(render_pass, self.render_pipeline);
            c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &self.sprite_data_buffer, 1);
            c.SDL_BindGPUFragmentSamplers(
                render_pass,
                0,
                &.{
                    .texture = self.texture,
                    .sampler = self.sampler,
                },
                1,
            );
            c.SDL_PushGPUVertexUniformData(cmd_buffer, 0, &camera_matrix, @sizeOf(Matrix4x4));
            c.SDL_DrawGPUPrimitives(render_pass, SPRITE_COUNT * 6, 1, 0, 0);
            c.SDL_EndGPURenderPass(render_pass);
        }

        if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer))
            return error.CommandBufferSubmissionFailed;
    }

    fn deinit(self: *Game) void {
        c.SDL_ReleaseGPUBuffer(self.device, self.sprite_data_buffer);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.sprite_data_transfer_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.render_pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
        c.TTF_Quit();
        c.SDL_Quit();
    }

    fn handleEvents(self: *Game) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => self.running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    switch (event.key.key) {
                        c.SDLK_Q, c.SDLK_ESCAPE => self.running = false,
                        c.SDLK_P => self.paused = !self.paused,
                        else => {},
                    }
                },
                else => {},
            }
        }
    }
};

pub fn main() !void {
    var game = try Game.init();
    defer game.deinit();

    while (game.running) {
        game.handleEvents();
        try game.render();
    }
}
