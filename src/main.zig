const std = @import("std");
const math3d = @import("math3d.zig");

const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const MAX_VERTEX_COUNT = 4000;
const MAX_INDEX_COUNT = 6000;
const SUPPORTED_SHADER_FORMATS =
    c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL;

const Color = c.SDL_FColor;
const Vec2 = c.SDL_FPoint;
const Vec3 = math3d.Vec3;
const Vec4 = math3d.Vec4;
const Mat4x4 = math3d.Mat4x4;

const Vertex = struct {
    pos: Vec3,
    color: Color,
    uv: Vec2,
};

const Context = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: *c.SDL_GPUBuffer,
    index_buffer: *c.SDL_GPUBuffer,
    transfer_buffer: *c.SDL_GPUTransferBuffer,
    sampler: *c.SDL_GPUSampler,
    cmd_buf: ?*c.SDL_GPUCommandBuffer,

    fn init(use_sdf: bool) !Context {
        const window = c.SDL_CreateWindow(
            "SDL Gpu Text Example",
            800,
            600,
            c.SDL_WINDOW_HIDDEN,
        ) orelse {
            return error.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        const device = c.SDL_CreateGPUDevice(
            SUPPORTED_SHADER_FORMATS,
            true,
            null,
        ) orelse {
            return error.DeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            return error.WindowClaimFailed;
        }

        const vertex_shader = try loadShader(
            device,
            "font-shader.vert",
            0,
            1,
            0,
            0,
        );
        errdefer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const fragment_shader = try loadShader(
            device,
            if (use_sdf) "font-shader-sdf.frag" else "font-shader.frag",
            1,
            0,
            0,
            0,
        );
        errdefer c.SDL_ReleaseGPUShader(device, fragment_shader);

        const pipeline_create_info = c.SDL_GPUGraphicsPipelineCreateInfo{
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{.{
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
                }},
                .has_depth_stencil_target = false,
                .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            },
            .vertex_input_state = .{
                .num_vertex_buffers = 1,
                .vertex_buffer_descriptions = &[_]c.SDL_GPUVertexBufferDescription{.{
                    .slot = 0,
                    .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                    .instance_step_rate = 0,
                    .pitch = @sizeOf(Vertex),
                }},
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
            .fragment_shader = fragment_shader,
        };

        const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_create_info) orelse {
            return error.PipelineCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

        c.SDL_ReleaseGPUShader(device, vertex_shader);
        c.SDL_ReleaseGPUShader(device, fragment_shader);

        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &.{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = @sizeOf(Vertex) * MAX_VERTEX_COUNT,
        }) orelse {
            return error.VertexBufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        const index_buffer = c.SDL_CreateGPUBuffer(device, &.{
            .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
            .size = @sizeOf(i32) * MAX_INDEX_COUNT,
        }) orelse {
            return error.IndexBufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, index_buffer);

        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = (@sizeOf(Vertex) * MAX_VERTEX_COUNT) + (@sizeOf(i32) * MAX_INDEX_COUNT),
        }) orelse {
            return error.TransferBufferCreationFailed;
        };

        const sampler = c.SDL_CreateGPUSampler(device, &.{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse {
            return error.SamplerCreationFailed;
        };

        return .{
            .device = device,
            .window = window,
            .pipeline = pipeline,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .transfer_buffer = transfer_buffer,
            .sampler = sampler,
            .cmd_buf = null,
        };
    }

    fn setGeometryData(self: *Context, geometry_data: *GeometryData) !void {
        const transfer_data = c.SDL_MapGPUTransferBuffer(
            self.device,
            self.transfer_buffer,
            false,
        ) orelse {
            return error.TransferBufferMappingFailed;
        };

        const vertex_slice = geometry_data.vertices[0..@intCast(geometry_data.vertex_count)];
        const index_slice = geometry_data.indices[0..@intCast(geometry_data.index_count)];

        const vertex_bytes_to_copy = @sizeOf(Vertex) * vertex_slice.len;
        const index_bytes_to_copy = @sizeOf(i32) * index_slice.len;

        const index_buffer_offset_in_transfer_buffer = @sizeOf(Vertex) * MAX_VERTEX_COUNT;
        const dest_vertices_slice = @as([*]u8, @ptrCast(transfer_data))[0..vertex_bytes_to_copy];
        const dest_indices_ptr = @as([*]u8, @ptrCast(transfer_data)) + index_buffer_offset_in_transfer_buffer;
        const dest_indices_slice = dest_indices_ptr[0..index_bytes_to_copy];

        @memcpy(dest_vertices_slice, std.mem.sliceAsBytes(vertex_slice));
        @memcpy(dest_indices_slice, std.mem.sliceAsBytes(index_slice));

        c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer_buffer);
    }

    fn transferData(self: *Context, geometry_data: *GeometryData) !void {
        const copy_pass = c.SDL_BeginGPUCopyPass(self.cmd_buf) orelse {
            return error.CopyPassStartFailed;
        };

        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &.{
                .transfer_buffer = self.transfer_buffer,
                .offset = 0,
            },
            &.{
                .buffer = self.vertex_buffer,
                .offset = 0,
                .size = @as(u32, @intCast(geometry_data.vertex_count)) * @sizeOf(Vertex),
            },
            false,
        );

        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &.{
                .transfer_buffer = self.transfer_buffer,
                .offset = @sizeOf(Vertex) * MAX_VERTEX_COUNT,
            },
            &.{
                .buffer = self.index_buffer,
                .offset = 0,
                .size = @as(u32, @intCast(geometry_data.index_count)) * @sizeOf(i32),
            },
            false,
        );

        c.SDL_EndGPUCopyPass(copy_pass);
    }

    fn draw(
        self: *Context,
        matrices: []Mat4x4,
        num_matrices: i32,
        draw_sequence: *c.TTF_GPUAtlasDrawSequence,
    ) !void {
        var swapchain_texture: ?*c.SDL_GPUTexture = null;

        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(
            self.cmd_buf,
            self.window,
            &swapchain_texture,
            null,
            null,
        )) {
            return error.SwapchainTextureAcquireFailed;
        }

        if (swapchain_texture != null) {
            const color_target_info = c.SDL_GPUColorTargetInfo{
                .texture = swapchain_texture,
                .clear_color = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1.0 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            };
            const render_pass = c.SDL_BeginGPURenderPass(
                self.cmd_buf,
                &color_target_info,
                1,
                null,
            ) orelse {
                return error.RenderPassStartFailed;
            };

            c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);
            c.SDL_BindGPUVertexBuffers(
                render_pass,
                0,
                &.{ .buffer = self.vertex_buffer, .offset = 0 },
                1,
            );
            c.SDL_BindGPUIndexBuffer(
                render_pass,
                &.{ .buffer = self.index_buffer, .offset = 0 },
                c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
            );
            c.SDL_PushGPUVertexUniformData(
                self.cmd_buf,
                0,
                matrices.ptr,
                @sizeOf(Mat4x4) * @as(u32, @intCast(num_matrices)),
            );

            const index_offsert: i32 = 0;
            const vertex_offset: i32 = 0;
            var seq: ?*c.TTF_GPUAtlasDrawSequence = draw_sequence;
            while (seq != null) : (seq = seq.?.next) {
                c.SDL_BindGPUFragmentSamplers(
                    render_pass,
                    0,
                    &.{
                        .texture = seq.?.atlas_texture,
                        .sampler = self.sampler,
                    },
                    1,
                );
                c.SDL_DrawGPUIndexedPrimitives(
                    render_pass,
                    @intCast(seq.?.num_indices),
                    1,
                    index_offsert,
                    vertex_offset,
                    0,
                );
            }

            c.SDL_EndGPURenderPass(render_pass);
        }
    }

    fn drawBatchedText(
        self: *Context,
        matrices: []Mat4x4,
        num_matrices: i32,
        geometry_data: *GeometryData,
        atlas_texture: *c.SDL_GPUTexture,
    ) !void {
        var swapchain_texture: ?*c.SDL_GPUTexture = null;

        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(self.cmd_buf, self.window, &swapchain_texture, null, null)) {
            return error.SwapchainTextureAcquireFailed;
        }

        if (swapchain_texture != null) {
            const color_target_info = c.SDL_GPUColorTargetInfo{
                .texture = swapchain_texture,
                .clear_color = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1.0 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            };
            const render_pass = c.SDL_BeginGPURenderPass(
                self.cmd_buf,
                &color_target_info,
                1,
                null,
            ) orelse {
                return error.RenderPassStartFailed;
            };

            c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);
            c.SDL_BindGPUVertexBuffers(
                render_pass,
                0,
                &.{ .buffer = self.vertex_buffer, .offset = 0 },
                1,
            );
            c.SDL_BindGPUIndexBuffer(
                render_pass,
                &.{ .buffer = self.index_buffer, .offset = 0 },
                c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
            );
            c.SDL_PushGPUVertexUniformData(self.cmd_buf, 0, matrices.ptr, @sizeOf(Mat4x4) * @as(u32, @intCast(num_matrices)));

            c.SDL_BindGPUFragmentSamplers(
                render_pass,
                0,
                &.{
                    .texture = atlas_texture,
                    .sampler = self.sampler,
                },
                1,
            );
            c.SDL_DrawGPUIndexedPrimitives(
                render_pass,
                @intCast(geometry_data.index_count),
                1,
                0,
                0,
                0,
            );

            c.SDL_EndGPURenderPass(render_pass);
        }
    }

    fn deinit(self: *Context) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.transfer_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.sampler);
        c.SDL_ReleaseGPUBuffer(self.device, self.vertex_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.index_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pipeline);
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
    }
};

const GeometryData = struct {
    vertices: []Vertex,
    vertex_count: i32,
    indices: []i32,
    index_count: i32,

    fn queueTextSequence(
        self: *GeometryData,
        sequence: *const c.TTF_GPUAtlasDrawSequence,
        color: *const Color,
    ) !void {
        var i: i32 = 0;
        while (i < sequence.num_vertices) : (i += 1) {
            const idx: usize = @intCast(i);
            const pos = sequence.xy[idx];
            const vert = Vertex{
                .pos = .{ .x = pos.x, .y = pos.y, .z = 0.0 },
                .color = color.*,
                .uv = sequence.uv[idx],
            };
            self.vertices[@intCast(self.vertex_count + i)] = vert;
        }

        const new_indices = self.indices[@intCast(self.index_count)..];
        const sequence_indices = sequence.indices[0..@intCast(sequence.num_indices)];
        @memcpy(new_indices[0..sequence_indices.len], sequence_indices);

        self.vertex_count += sequence.num_vertices;
        self.index_count += sequence.num_indices;
    }

    fn queueText(self: *GeometryData, sequence: *c.TTF_GPUAtlasDrawSequence, color: *const Color) !void {
        var current: ?*c.TTF_GPUAtlasDrawSequence = sequence;
        while (current != null) : (current = current.?.next) {
            try self.queueTextSequence(current.?, color);
        }
    }
};

pub fn loadShader(
    device: *c.SDL_GPUDevice,
    shader_name: []const u8,
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
    const shader_path = try std.fmt.bufPrintZ(
        &shader_path_buf,
        "assets/shaders/compiled/{s}{s}",
        .{ shader_name, extension },
    );

    var code_size: usize = 0;
    const code = c.SDL_LoadFile(shader_path.ptr, &code_size) orelse {
        c.SDL_Log("Failed to load shader file: %s", shader_path.ptr);
        return error.ShaderFileLoadFailed;
    };
    c.SDL_Log("Loaded shader file: %s, size: %zu bytes", shader_path.ptr, code_size);
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

fn renderTextToGeometry(
    engine: *c.TTF_TextEngine,
    font: *c.TTF_Font,
    text_str: []const u8,
    x: f32,
    y: f32,
    color: Color,
    geometry_data: *GeometryData,
) !void {
    var text_buf: [256]u8 = undefined;
    @memcpy(text_buf[0..text_str.len], text_str);
    text_buf[text_str.len] = 0;

    const text = c.TTF_CreateText(engine, font, &text_buf, 0);
    defer c.TTF_DestroyText(text);

    if (text == null) {
        c.SDL_Log("Failed to create text: %s", c.SDL_GetError());
        return error.TextCreationFailed;
    }

    const sequence = c.TTF_GetGPUTextDrawData(text);

    var i: i32 = 0;
    while (i < sequence.*.num_vertices) : (i += 1) {
        const idx: usize = @intCast(i);
        const pos = sequence.*.xy[idx];
        const vert = Vertex{
            .pos = .{ .x = pos.x + x, .y = pos.y + y, .z = 0.0 },
            .color = color,
            .uv = sequence.*.uv[idx],
        };
        geometry_data.vertices[@intCast(geometry_data.vertex_count + i)] = vert;
    }

    const vertex_offset = geometry_data.vertex_count;
    const new_indices = geometry_data.indices[@intCast(geometry_data.index_count)..];
    const sequence_indices = sequence.*.indices[0..@intCast(sequence.*.num_indices)];
    for (sequence_indices, 0..) |index, j| {
        new_indices[j] = index + vertex_offset;
    }

    geometry_data.vertex_count += sequence.*.num_vertices;
    geometry_data.index_count += sequence.*.num_indices;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var font_filename: ?[]const u8 = null;
    var use_sdf = false;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(args[i], "--sdf")) {
            use_sdf = true;
        } else if (args[i][0] == '-') {
            break;
        } else {
            font_filename = args[i];
            break;
        }
    }

    if (font_filename == null) {
        c.SDL_LogError(
            c.SDL_LOG_CATEGORY_APPLICATION,
            "Usage: testgputext [--sdf] FONT_FILENAME",
        );
        return error.InvalidArguments;
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
        c.SDL_Log("Failed to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_VERBOSE);

    if (!c.TTF_Init()) {
        c.SDL_Log("Failed to initialize SDL_ttf: %s", c.SDL_GetError());
        return error.TTFInitializationFailed;
    }
    defer c.TTF_Quit();

    var running = true;

    var context = try Context.init(use_sdf);
    defer context.deinit();

    const vertices = try allocator.alloc(Vertex, MAX_VERTEX_COUNT);
    defer allocator.free(vertices);

    const indices = try allocator.alloc(i32, MAX_INDEX_COUNT);
    defer allocator.free(indices);

    var geometry_data = GeometryData{
        .vertices = vertices,
        .indices = indices,
        .vertex_count = 0,
        .index_count = 0,
    };

    const font = c.TTF_OpenFont(font_filename.?.ptr, 50) orelse {
        c.SDL_Log("Failed to open font: %s", c.SDL_GetError());
        return error.FontLoadingFailed;
    };
    defer c.TTF_CloseFont(font);

    if (!c.TTF_SetFontSDF(font, use_sdf)) {
        c.SDL_Log("Failed to set font SDF mode: %s", c.SDL_GetError());
        return error.FontSDFSettingFailed;
    }
    c.TTF_SetFontWrapAlignment(font, c.TTF_HORIZONTAL_ALIGN_CENTER);

    const engine = c.TTF_CreateGPUTextEngine(context.device) orelse {
        c.SDL_Log("Failed to create GPU text engine: %s", c.SDL_GetError());
        return error.GPUTextEngineCreationFailed;
    };

    defer {
        _ = c.SDL_WaitForGPUIdle(context.device);
        c.TTF_DestroyGPUTextEngine(engine);
    }

    var str = "Hello, SDL GPU Text!".*;
    const text = c.TTF_CreateText(engine, font, &str, 0);
    defer c.TTF_DestroyText(text);

    const color = Color{ .r = 1.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    const white_color = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    const red_color = Color{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };

    var matrices = [_]Mat4x4{
        Mat4x4.ortho(0.0, 800.0, 0.0, 600.0, -1.0, 1.0),
        Mat4x4.identity(),
    };

    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_KEY_DOWN => {
                    const key = event.key.key;
                    switch (key) {
                        c.SDLK_ESCAPE => {
                            running = false;
                        },
                        else => {},
                    }
                },
                c.SDL_EVENT_QUIT => {
                    running = false;
                },
                else => {},
            }
        }

        geometry_data.vertex_count = 0;
        geometry_data.index_count = 0;

        try renderTextToGeometry(engine, font, "Hello, World!", 100.0, 50.0, color, &geometry_data);
        try renderTextToGeometry(engine, font, "SDL GPU Text", 200.0, 150.0, white_color, &geometry_data);
        try renderTextToGeometry(engine, font, "UI Rendering", 150.0, 250.0, red_color, &geometry_data);

        _ = try renderTextToGeometry(engine, font, "Frame-based UI", 50.0, 350.0, white_color, &geometry_data);

        if (geometry_data.vertex_count > 0) {
            try context.setGeometryData(&geometry_data);

            context.cmd_buf = c.SDL_AcquireGPUCommandBuffer(context.device) orelse {
                c.SDL_Log("Failed to acquire command buffer: %s", c.SDL_GetError());
                return error.CommandBufferAcquisitionFailed;
            };

            try context.transferData(&geometry_data);

            var temp_str = "A".*;
            const temp_text = c.TTF_CreateText(engine, font, &temp_str, 0);
            const temp_sequence = c.TTF_GetGPUTextDrawData(temp_text);
            const atlas_texture = temp_sequence.*.atlas_texture orelse {
                c.SDL_Log("Failed to get atlas texture from text: %s", c.SDL_GetError());
                return error.AtlasTextureRetrievalFailed;
            };
            c.TTF_DestroyText(temp_text);

            try context.drawBatchedText(&matrices, 2, &geometry_data, atlas_texture);

            if (!c.SDL_SubmitGPUCommandBuffer(context.cmd_buf)) {
                c.SDL_Log("Failed to submit command buffer: %s", c.SDL_GetError());
                return error.CommandBufferSubmissionFailed;
            }
        }
    }
}
