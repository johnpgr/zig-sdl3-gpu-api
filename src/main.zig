const std = @import("std");
const math3d = @import("math3d.zig");

const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const IMAGES_BASE_PATH = "assets/images/";
const SPRITE_COUNT: u32 = 1000; // Reduced for demo
const MAX_VERTEX_COUNT = 4000;
const MAX_INDEX_COUNT = 6000;
const SUPPORTED_SHADER_FORMATS =
    c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL;

const Color = c.SDL_FColor;
const Vec2 = c.SDL_FPoint;
const Vec3 = math3d.Vec3;
const Vec4 = math3d.Vec4;
const Mat4x4 = math3d.Mat4x4;
const Matrix4x4 = [4][4]f32;

// FPS tracking structure
const FPSCounter = struct {
    frame_count: u32,
    last_time: u64,
    fps: f32,
    update_interval: u64, // in milliseconds
    fps_buffer: [64]u8, // Buffer to store FPS string

    fn init() FPSCounter {
        return FPSCounter{
            .frame_count = 0,
            .last_time = c.SDL_GetTicks(),
            .fps = 0.0,
            .update_interval = 500, // Update every 500ms
            .fps_buffer = undefined,
        };
    }

    fn update(self: *FPSCounter) void {
        self.frame_count += 1;
        const current_time = c.SDL_GetTicks();
        const elapsed = current_time - self.last_time;

        if (elapsed >= self.update_interval) {
            self.fps = @as(f32, @floatFromInt(self.frame_count)) / (@as(f32, @floatFromInt(elapsed)) / 1000.0);
            self.frame_count = 0;
            self.last_time = current_time;
        }
    }

    fn toString(self: *FPSCounter) []const u8 {
        return std.fmt.bufPrintZ(&self.fps_buffer, "FPS: {d:.1}", .{self.fps}) catch "FPS: --";
    }
};

// Sprite rendering structures
const SpriteVertex = struct {
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

// Text rendering structures
const TextVertex = struct {
    pos: Vec3,
    color: Color,
    uv: Vec2,
};

const GeometryData = struct {
    vertices: []TextVertex,
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
            const vert = TextVertex{
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

    fn reset(self: *GeometryData) void {
        self.vertex_count = 0;
        self.index_count = 0;
    }
};

const CombinedRenderer = struct {
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    
    // Sprite rendering resources
    sprite_pipeline: *c.SDL_GPUGraphicsPipeline,
    sprite_texture: *c.SDL_GPUTexture,
    sprite_sampler: *c.SDL_GPUSampler,
    sprite_data_transfer_buffer: *c.SDL_GPUTransferBuffer,
    sprite_data_buffer: *c.SDL_GPUBuffer,
    
    // Text rendering resources
    text_pipeline: *c.SDL_GPUGraphicsPipeline,
    text_vertex_buffer: *c.SDL_GPUBuffer,
    text_index_buffer: *c.SDL_GPUBuffer,
    text_transfer_buffer: *c.SDL_GPUTransferBuffer,
    text_sampler: *c.SDL_GPUSampler,
    text_engine: *c.TTF_TextEngine,
    font: *c.TTF_Font,

    const u_coords: [4]f32 = .{ 0.0, 0.5, 0.0, 0.5 };
    const v_coords: [4]f32 = .{ 0.0, 0.0, 0.5, 0.5 };

    fn init(use_sdf: bool, font_filename: []const u8) !CombinedRenderer {
        const window = c.SDL_CreateWindow(
            "Combined Sprite and Text Renderer",
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

        // Setup sprite pipeline
        const sprite_pipeline = try setupSpritePipeline(device, window);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, sprite_pipeline);

        // Setup text pipeline
        const text_pipeline = try setupTextPipeline(device, window, use_sdf);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, text_pipeline);

        // Setup sprite resources
        const sprite_data = try setupSpriteResources(device);
        errdefer {
            c.SDL_ReleaseGPUSampler(device, sprite_data.sampler);
            c.SDL_ReleaseGPUTexture(device, sprite_data.texture);
            c.SDL_ReleaseGPUBuffer(device, sprite_data.storage_buffer);
            c.SDL_ReleaseGPUTransferBuffer(device, sprite_data.transfer_buffer);
        }

        // Setup text resources
        const text_data = try setupTextResources(device, font_filename, use_sdf);
        errdefer {
            c.TTF_DestroyGPUTextEngine(text_data.engine);
            c.TTF_CloseFont(text_data.font);
            c.SDL_ReleaseGPUSampler(device, text_data.sampler);
            c.SDL_ReleaseGPUBuffer(device, text_data.vertex_buffer);
            c.SDL_ReleaseGPUBuffer(device, text_data.index_buffer);
            c.SDL_ReleaseGPUTransferBuffer(device, text_data.transfer_buffer);
        }

        return CombinedRenderer{
            .device = device,
            .window = window,
            .sprite_pipeline = sprite_pipeline,
            .sprite_texture = sprite_data.texture,
            .sprite_sampler = sprite_data.sampler,
            .sprite_data_transfer_buffer = sprite_data.transfer_buffer,
            .sprite_data_buffer = sprite_data.storage_buffer,
            .text_pipeline = text_pipeline,
            .text_vertex_buffer = text_data.vertex_buffer,
            .text_index_buffer = text_data.index_buffer,
            .text_transfer_buffer = text_data.transfer_buffer,
            .text_sampler = text_data.sampler,
            .text_engine = text_data.engine,
            .font = text_data.font,
        };
    }

    fn setupSpritePipeline(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !*c.SDL_GPUGraphicsPipeline {
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
                .color_write_mask = 0xF,
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
        ) orelse return error.SpritePipelineCreationFailed;
    }

    fn setupTextPipeline(device: *c.SDL_GPUDevice, window: *c.SDL_Window, use_sdf: bool) !*c.SDL_GPUGraphicsPipeline {
        const vertex_shader = try loadShader(device, "font-shader.vert", 0, 1, 0, 0);
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
                    .pitch = @sizeOf(TextVertex),
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
            return error.TextPipelineCreationFailed;
        };

        c.SDL_ReleaseGPUShader(device, vertex_shader);
        c.SDL_ReleaseGPUShader(device, fragment_shader);

        return pipeline;
    }

    fn setupSpriteResources(device: *c.SDL_GPUDevice) !struct {
        texture: *c.SDL_GPUTexture,
        sampler: *c.SDL_GPUSampler,
        transfer_buffer: *c.SDL_GPUTransferBuffer,
        storage_buffer: *c.SDL_GPUBuffer,
    } {
        // Load sprite texture
        const texture_data = try setupTextureData(device);
        errdefer {
            c.SDL_ReleaseGPUSampler(device, texture_data.sampler);
            c.SDL_ReleaseGPUTexture(device, texture_data.texture);
        }

        // Create sprite buffers
        const sprite_buffers = try setupSpriteBuffers(device);
        errdefer {
            c.SDL_ReleaseGPUBuffer(device, sprite_buffers.storage_buffer);
            c.SDL_ReleaseGPUTransferBuffer(device, sprite_buffers.transfer_buffer);
        }

        return .{
            .texture = texture_data.texture,
            .sampler = texture_data.sampler,
            .transfer_buffer = sprite_buffers.transfer_buffer,
            .storage_buffer = sprite_buffers.storage_buffer,
        };
    }

    fn setupTextResources(device: *c.SDL_GPUDevice, font_filename: []const u8, use_sdf: bool) !struct {
        engine: *c.TTF_TextEngine,
        font: *c.TTF_Font,
        vertex_buffer: *c.SDL_GPUBuffer,
        index_buffer: *c.SDL_GPUBuffer,
        transfer_buffer: *c.SDL_GPUTransferBuffer,
        sampler: *c.SDL_GPUSampler,
    } {
        const vertex_buffer = c.SDL_CreateGPUBuffer(device, &.{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = @sizeOf(TextVertex) * MAX_VERTEX_COUNT,
        }) orelse {
            return error.TextVertexBufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

        const index_buffer = c.SDL_CreateGPUBuffer(device, &.{
            .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
            .size = @sizeOf(i32) * MAX_INDEX_COUNT,
        }) orelse {
            return error.TextIndexBufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUBuffer(device, index_buffer);

        const transfer_buffer = c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = (@sizeOf(TextVertex) * MAX_VERTEX_COUNT) + (@sizeOf(i32) * MAX_INDEX_COUNT),
        }) orelse {
            return error.TextTransferBufferCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

        const sampler = c.SDL_CreateGPUSampler(device, &.{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse {
            return error.TextSamplerCreationFailed;
        };
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);

        const font = c.TTF_OpenFont(font_filename.ptr, 50) orelse {
            c.SDL_Log("Failed to open font: %s", c.SDL_GetError());
            return error.FontLoadingFailed;
        };
        errdefer c.TTF_CloseFont(font);

        if (!c.TTF_SetFontSDF(font, use_sdf)) {
            c.SDL_Log("Failed to set font SDF mode: %s", c.SDL_GetError());
            return error.FontSDFSettingFailed;
        }

        const engine = c.TTF_CreateGPUTextEngine(device) orelse {
            c.SDL_Log("Failed to create GPU text engine: %s", c.SDL_GetError());
            return error.GPUTextEngineCreationFailed;
        };
        errdefer c.TTF_DestroyGPUTextEngine(engine);

        return .{
            .engine = engine,
            .font = font,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .transfer_buffer = transfer_buffer,
            .sampler = sampler,
        };
    }

    fn render(self: *CombinedRenderer, geometry_data: *GeometryData) !void {
        const sprite_matrix = createOrtographicOffCenter(0, 800, 600, 0, 0, -1);
        const text_matrices = [_]Mat4x4{
            Mat4x4.ortho(0.0, 800.0, 0.0, 600.0, -1.0, 1.0),
            Mat4x4.identity(),
        };

        const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
            return error.CommandBufferAcquisitionFailed;
        };

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmd_buffer,
            self.window,
            &swapchain_texture,
            null,
            null,
        )) {
            return error.SwapchainTextureAcquireFailed;
        }

        if (swapchain_texture) |texture| {
            // Upload sprite data
            try self.uploadSpriteData(cmd_buffer);

            // Upload text data if we have any
            if (geometry_data.vertex_count > 0) {
                try self.uploadTextData(geometry_data, cmd_buffer);
            }

            const color_target_info = c.SDL_GPUColorTargetInfo{
                .texture = texture,
                .clear_color = .{ .r = 0.2, .g = 0.3, .b = 0.4, .a = 1.0 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            };

            const render_pass = c.SDL_BeginGPURenderPass(
                cmd_buffer,
                &color_target_info,
                1,
                null,
            ) orelse {
                return error.RenderPassStartFailed;
            };

            // Render sprites first (background)
            c.SDL_BindGPUGraphicsPipeline(render_pass, self.sprite_pipeline);
            c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &self.sprite_data_buffer, 1);
            c.SDL_BindGPUFragmentSamplers(
                render_pass,
                0,
                &.{
                    .texture = self.sprite_texture,
                    .sampler = self.sprite_sampler,
                },
                1,
            );
            c.SDL_PushGPUVertexUniformData(cmd_buffer, 0, &sprite_matrix, @sizeOf(Matrix4x4));
            c.SDL_DrawGPUPrimitives(render_pass, SPRITE_COUNT * 6, 1, 0, 0);

            // Render text on top if we have any
            if (geometry_data.vertex_count > 0) {
                try self.renderText(render_pass, cmd_buffer, geometry_data, &text_matrices);
            }

            c.SDL_EndGPURenderPass(render_pass);
        }

        if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer)) {
            return error.CommandBufferSubmissionFailed;
        }
    }

    fn renderText(
        self: *CombinedRenderer,
        render_pass: *c.SDL_GPURenderPass,
        cmd_buffer: *c.SDL_GPUCommandBuffer,
        geometry_data: *GeometryData,
        matrices: []const Mat4x4,
    ) !void {
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.text_pipeline);
        c.SDL_BindGPUVertexBuffers(
            render_pass,
            0,
            &.{ .buffer = self.text_vertex_buffer, .offset = 0 },
            1,
        );
        c.SDL_BindGPUIndexBuffer(
            render_pass,
            &.{ .buffer = self.text_index_buffer, .offset = 0 },
            c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
        );
        c.SDL_PushGPUVertexUniformData(
            cmd_buffer,
            0,
            matrices.ptr,
            @sizeOf(Mat4x4) * @as(u32, @intCast(matrices.len)),
        );

        // Get atlas texture from a temporary text object
        var temp_str = "A".*;
        const temp_text = c.TTF_CreateText(self.text_engine, self.font, &temp_str, 0);
        defer c.TTF_DestroyText(temp_text);
        const temp_sequence = c.TTF_GetGPUTextDrawData(temp_text);
        const atlas_texture = temp_sequence.*.atlas_texture orelse {
            return error.AtlasTextureRetrievalFailed;
        };

        c.SDL_BindGPUFragmentSamplers(
            render_pass,
            0,
            &.{
                .texture = atlas_texture,
                .sampler = self.text_sampler,
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
    }

    fn uploadSpriteData(self: *CombinedRenderer, cmd_buffer: *c.SDL_GPUCommandBuffer) !void {
        const raw_ptr = c.SDL_MapGPUTransferBuffer(
            self.device,
            self.sprite_data_transfer_buffer,
            true,
        ) orelse return error.SpriteDataBufferMappingFailed;

        const sprite_data_ptr: [*]SpriteInstance = @ptrCast(@alignCast(raw_ptr));
        updateSprites(sprite_data_ptr);
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
            false,
        );
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    fn uploadTextData(self: *CombinedRenderer, geometry_data: *GeometryData, cmd_buffer: *c.SDL_GPUCommandBuffer) !void {
        const transfer_data = c.SDL_MapGPUTransferBuffer(
            self.device,
            self.text_transfer_buffer,
            false,
        ) orelse {
            return error.TextTransferBufferMappingFailed;
        };

        const vertex_slice = geometry_data.vertices[0..@intCast(geometry_data.vertex_count)];
        const index_slice = geometry_data.indices[0..@intCast(geometry_data.index_count)];

        const vertex_bytes_to_copy = @sizeOf(TextVertex) * vertex_slice.len;
        const index_bytes_to_copy = @sizeOf(i32) * index_slice.len;

        const index_buffer_offset_in_transfer_buffer = @sizeOf(TextVertex) * MAX_VERTEX_COUNT;
        const dest_vertices_slice = @as([*]u8, @ptrCast(transfer_data))[0..vertex_bytes_to_copy];
        const dest_indices_ptr = @as([*]u8, @ptrCast(transfer_data)) + index_buffer_offset_in_transfer_buffer;
        const dest_indices_slice = dest_indices_ptr[0..index_bytes_to_copy];

        @memcpy(dest_vertices_slice, std.mem.sliceAsBytes(vertex_slice));
        @memcpy(dest_indices_slice, std.mem.sliceAsBytes(index_slice));

        c.SDL_UnmapGPUTransferBuffer(self.device, self.text_transfer_buffer);

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buffer) orelse {
            return error.CopyPassStartFailed;
        };

        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &.{
                .transfer_buffer = self.text_transfer_buffer,
                .offset = 0,
            },
            &.{
                .buffer = self.text_vertex_buffer,
                .offset = 0,
                .size = @as(u32, @intCast(geometry_data.vertex_count)) * @sizeOf(TextVertex),
            },
            false,
        );

        c.SDL_UploadToGPUBuffer(
            copy_pass,
            &.{
                .transfer_buffer = self.text_transfer_buffer,
                .offset = @sizeOf(TextVertex) * MAX_VERTEX_COUNT,
            },
            &.{
                .buffer = self.text_index_buffer,
                .offset = 0,
                .size = @as(u32, @intCast(geometry_data.index_count)) * @sizeOf(i32),
            },
            false,
        );

        c.SDL_EndGPUCopyPass(copy_pass);
    }

    fn deinit(self: *CombinedRenderer) void {
        _ = c.SDL_WaitForGPUIdle(self.device);
        
        // Cleanup text resources
        c.TTF_DestroyGPUTextEngine(self.text_engine);
        c.TTF_CloseFont(self.font);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.text_transfer_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.text_sampler);
        c.SDL_ReleaseGPUBuffer(self.device, self.text_vertex_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.text_index_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.text_pipeline);
        
        // Cleanup sprite resources
        c.SDL_ReleaseGPUBuffer(self.device, self.sprite_data_buffer);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.sprite_data_transfer_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.sprite_sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.sprite_texture);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.sprite_pipeline);
        
        // Cleanup common resources
        c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
    }
};

// Helper functions from the original files
fn createOrtographicOffCenter(
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

fn loadImage(image_filename: []const u8, desired_channels: u32) !*c.SDL_Surface {
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

fn loadShader(
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
            .x = @floatFromInt(c.SDL_rand(800)),
            .y = @floatFromInt(c.SDL_rand(600)),
            .z = 0,
            .rotation = c.SDL_randf() * c.SDL_PI_F * 2,
            .w = 64,
            .h = 64,
            .tex_u = CombinedRenderer.u_coords[@intCast(ravioli)],
            .tex_v = CombinedRenderer.v_coords[@intCast(ravioli)],
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
        const vert = TextVertex{
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

    const font_filename: []const u8 = "assets/fonts/retro-gaming.ttf";
    var use_sdf = false;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(args[i], "--sdf")) {
            use_sdf = true;
        }
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

    var renderer = try CombinedRenderer.init(use_sdf, font_filename);
    defer renderer.deinit();

    _ = c.SDL_ShowWindow(renderer.window);

    // Setup text geometry data
    const vertices = try allocator.alloc(TextVertex, MAX_VERTEX_COUNT);
    defer allocator.free(vertices);

    const indices = try allocator.alloc(i32, MAX_INDEX_COUNT);
    defer allocator.free(indices);

    var geometry_data = GeometryData{
        .vertices = vertices,
        .indices = indices,
        .vertex_count = 0,
        .index_count = 0,
    };

    const white_color = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    const red_color = Color{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    var fps_counter = FPSCounter.init();

    var running = true;
    while (running) {
        fps_counter.update();
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_KEY_DOWN => {
                    const key = event.key.key;
                    switch (key) {
                        c.SDLK_ESCAPE, c.SDLK_Q => {
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

        // Reset text geometry for this frame
        geometry_data.reset();

        // Add text to render
        try renderTextToGeometry(renderer.text_engine, renderer.font, "Sprites + Text!", 0.0, 600.0, white_color, &geometry_data);
        try renderTextToGeometry(renderer.text_engine, renderer.font, "Combined Rendering", 0.0, 550.0, white_color, &geometry_data);
        try renderTextToGeometry(renderer.text_engine, renderer.font, fps_counter.toString(), 0.0, 500.0, red_color, &geometry_data);

        // Render both sprites and text
        try renderer.render(&geometry_data);
    }
}
