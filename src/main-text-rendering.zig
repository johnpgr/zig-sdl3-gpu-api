const std = @import("std");
const math3d = @import("math3d.zig");

const dxil = @import("shader.dxil.zig");
const spv = @import("shader.spv.zig");
const msl = @import("shader.msl.zig");
const dxil_sdf = @import("shader-sdf.dxil.zig");
const spv_sdf = @import("shader-sdf.spv.zig");
const msl_sdf = @import("shader-sdf.msl.zig");

const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const MAX_VERTEX_COUNT = 4000;
const MAX_INDEX_COUNT = 6000;
const SUPPORTED_SHADER_FORMATS =
    c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL;

const ShaderType = enum {
    VertexShader,
    PixelShader,
    PixelShader_SDF,
};

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
            0,
        ) orelse {
            return error.WindowCreationFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        const device = c.SDL_CreateGPUDevice(SUPPORTED_SHADER_FORMATS, true, null) orelse {
            return error.DeviceCreationFailed;
        };
        errdefer c.SDL_DestroyGPUDevice(device);

        if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
            return error.WindowClaimFailed;
        }

        const vertex_shader = try loadShader(
            device,
            .VertexShader,
            0,
            1,
            0,
            0,
        );
        errdefer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const fragment_shader = try loadShader(
            device,
            if (use_sdf) .PixelShader_SDF else .PixelShader,
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

        @memcpy(@as([*]u8, @ptrCast(transfer_data))[0 .. @sizeOf(Vertex) * @as(usize, @intCast(geometry_data.vertex_count))], std.mem.sliceAsBytes(geometry_data.vertices[0..@intCast(geometry_data.vertex_count)]));

        @memcpy(@as([*]u8, @ptrCast(transfer_data))[MAX_VERTEX_COUNT..][0 .. @sizeOf(i32) * @as(usize, @intCast(geometry_data.vertex_count))], std.mem.sliceAsBytes(geometry_data.indices[0..@intCast(geometry_data.index_count)]));

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

    fn deinit(self: *Context) void {
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
        while (0 < sequence.num_vertices) : (i += 1) {
            const idx: usize = @intCast(i);
            const pos = sequence.xy[idx];
            const vert = Vertex{
                .pos = .{ .x = pos.x, .y = pos.y, .z = 0.0 },
                .color = color.*,
                .uv = sequence.uv[idx],
            };
            self.vertices[@intCast(self.vertex_count + i)] = vert;

            const dest_indices = self.indices[@intCast(self.index_count)..];
            const src_indices = sequence.indices[0..@intCast(sequence.num_indices)];
            @memcpy(dest_indices[0..@intCast(sequence.num_indices)], src_indices);

            self.vertex_count += sequence.num_vertices;
            self.index_count += sequence.num_indices;
        }
    }

    fn queueText(self: *GeometryData, sequence: *c.TTF_GPUAtlasDrawSequence, color: *const Color) !void {
        var current: ?*c.TTF_GPUAtlasDrawSequence = sequence;
        while (current != null) : (current = current.?.next) {
            try self.queueTextSequence(current.?, color);
        }
    }
};

fn loadShader(
    device: *c.SDL_GPUDevice,
    shader_type: ShaderType,
    sampler_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    storage_texture_count: u32,
) !*c.SDL_GPUShader {
    var create_info = c.SDL_GPUShaderCreateInfo{
        .num_samplers = sampler_count,
        .num_storage_buffers = storage_buffer_count,
        .num_storage_textures = storage_texture_count,
        .num_uniform_buffers = uniform_buffer_count,
        .props = 0,
    };

    const format = c.SDL_GetGPUShaderFormats(device);

    if ((format & c.SDL_GPU_SHADERFORMAT_DXIL) != 0) {
        create_info.format = c.SDL_GPU_SHADERFORMAT_DXIL;
        switch (shader_type) {
            .VertexShader => {
                create_info.code = @ptrCast(dxil.shader_vert);
                create_info.code_size = dxil.shader_vert.len;
                create_info.entrypoint = "VSMain";
            },
            .PixelShader => {
                create_info.code = @ptrCast(dxil.shader_frag);
                create_info.code_size = dxil.shader_frag.len;
                create_info.entrypoint = "PSMain";
            },
            .PixelShader_SDF => {
                create_info.code = @ptrCast(dxil_sdf.shader_sdf_frag);
                create_info.code_size = dxil_sdf.shader_sdf_frag.len;
                create_info.entrypoint = "PSMain";
            },
        }
    } else if ((format & c.SDL_GPU_SHADERFORMAT_MSL) != 0) {
        create_info.format = c.SDL_GPU_SHADERFORMAT_MSL;
        switch (shader_type) {
            .VertexShader => {
                create_info.code = @ptrCast(msl.shader_vert);
                create_info.code_size = msl.shader_vert.len;
                create_info.entrypoint = "VSMain";
            },
            .PixelShader => {
                create_info.code = @ptrCast(msl.shader_frag);
                create_info.code_size = msl.shader_frag.len;
                create_info.entrypoint = "PSMain";
            },
            .PixelShader_SDF => {
                create_info.code = @ptrCast(msl_sdf.shader_sdf_frag);
                create_info.code_size = msl_sdf.shader_sdf_frag.len;
                create_info.entrypoint = "PSMain";
            },
        }
    } else if ((format & c.SDL_GPU_SHADERFORMAT_SPIRV) != 0) {
        create_info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
        switch (shader_type) {
            .VertexShader => {
                create_info.code = @ptrCast(spv.shader_vert);
                create_info.code_size = spv.shader_vert.len;
                create_info.entrypoint = "VSMain";
            },
            .PixelShader => {
                create_info.code = @ptrCast(spv.shader_frag);
                create_info.code_size = spv.shader_frag.len;
                create_info.entrypoint = "PSMain";
            },
            .PixelShader_SDF => {
                create_info.code = @ptrCast(spv_sdf.shader_sdf_frag);
                create_info.code_size = spv_sdf.shader_sdf_frag.len;
                create_info.entrypoint = "PSMain";
            },
        }
    } else {
        return error.UnsupportedShaderFormat;
    }

    if (shader_type == .VertexShader) {
        create_info.stage = c.SDL_GPU_SHADERSTAGE_VERTEX;
    } else {
        create_info.stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT;
    }

    return c.SDL_CreateGPUShader(device, &create_info) orelse {
        c.SDL_Log(
            "Failed to create shader: %s",
            c.SDL_GetError(),
        );
        return error.ShaderCreationFailed;
    };
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

    const font = c.TTF_OpenFont(@ptrCast(font_filename), 50) orelse {
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

    var str = "Hello, SDL GPU Text!".*;
    const text = c.TTF_CreateText(engine, font, &str, 0);
    var matrices = [_]Mat4x4{
        Mat4x4.perspective(c.SDL_PI_F / 2.0, 800.0 / 600.0, 0.1, 100.0),
        Mat4x4.identity(),
    };

    var rot_angle: f32 = 0.0;
    const color = Color{ .r = 1.0, .g = 1.0, .b = 0.0, .a = 1.0 };

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

        for (0..5) |j| {
            str[j] = @as(u8, @intCast(65 + (c.SDL_rand(26))));
        }

        if (!c.TTF_SetTextString(text, &str, 0)) {
            c.SDL_Log("Failed to set text string: %s", c.SDL_GetError());
            return error.TextSettingFailed;
        }

        var tw: i32 = 0;
        var th: i32 = 0;
        if (!c.TTF_GetTextSize(text, &tw, &th)) {
            c.SDL_Log("Failed to get text size: %s", c.SDL_GetError());
            return error.TextSizeRetrievalFailed;
        }
        rot_angle = c.SDL_fmodf(rot_angle + 0.01, 2 * c.SDL_PI_F);

        var model = Mat4x4.identity();
        model = model.multiply(Mat4x4.translation(.{ .x = 0.0, .y = 0.0, .z = -80.0 }));
        model = model.multiply(Mat4x4.scaling(.{ .x = 0.3, .y = 0.3, .z = 0.3 }));
        model = model.multiply(Mat4x4.rotationY(rot_angle));
        model = model.multiply(Mat4x4.translation(.{ .x = -@as(f32, @floatFromInt(tw)) / 2.0, .y = @as(f32, @floatFromInt(th)) / 2.0, .z = 0.0 }));
        matrices[1] = model;

        const sequence = c.TTF_GetGPUTextDrawData(text);
        try geometry_data.queueText(sequence, &color);
        try context.setGeometryData(&geometry_data);

        context.cmd_buf = c.SDL_AcquireGPUCommandBuffer(context.device) orelse {
            c.SDL_Log("Failed to acquire command buffer: %s", c.SDL_GetError());
            return error.CommandBufferAcquisitionFailed;
        };

        try context.transferData(&geometry_data);
        try context.draw(&matrices, 2, sequence);

        if (!c.SDL_SubmitGPUCommandBuffer(context.cmd_buf)) {
            c.SDL_Log("Failed to submit command buffer: %s", c.SDL_GetError());
            return error.CommandBufferSubmissionFailed;
        }
        geometry_data.vertex_count = 0;
        geometry_data.index_count = 0;
    }
}
