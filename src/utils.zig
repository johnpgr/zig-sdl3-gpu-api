const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
});

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

    const shader_path = "assets/shaders/compiled/" ++ shader_name ++ extension;

    var code_size: usize = 0;
    const code = c.SDL_LoadFile(shader_path.ptr, &code_size) orelse {
        c.SDL_Log("Failed to load shader file: %s", &shader_path);
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

fn getNearbyFilename(filename: [*:0]const u8) ?[*:0]u8 {
    const base_path = c.SDL_GetBasePath();
    if (base_path) |path| {
        defer c.SDL_free(path);
        const full_path = c.SDL_strjoin(path, filename);
        if (full_path) |fp| {
            if (c.SDL_FileExists(fp)) {
                return fp;
            }
            c.SDL_free(fp);
        }
    }
    if (c.SDL_FileExists(filename)) {
        return null;
    }
    return null;
}

/// Load a .bmp file from SDL_GetBasePath() if possible or the current working directory if not.
/// If transparent is true, set the transparent color from the top left pixel.
/// Returns a tuple containing the texture and optional width/height if requested.
/// Caller owns the returned texture and must destroy it.
pub fn loadTexture(
    renderer: *c.SDL_Renderer,
    file: [*:0]const u8,
    transparent: bool,
    width_out: ?*i32,
    height_out: ?*i32,
) !*c.SDL_Texture {
    var surface: ?*c.SDL_Surface = null;
    var texture: ?*c.SDL_Texture = null;
    const path: ?[*:0]u8 = getNearbyFilename(file);
    defer if (path) |p| c.SDL_free(p);

    const file_to_load = if (path) |p| p else file;

    surface = c.SDL_LoadBMP(file_to_load) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Couldn't load %s: %s", file_to_load, c.SDL_GetError());
        return error.LoadBMPFailed;
    };
    defer c.SDL_DestroySurface(surface);

    // Set transparent pixel as the pixel at (0,0)
    if (transparent) {
        if (c.SDL_GetSurfacePalette(surface) != null) {
            const bpp = c.SDL_BITSPERPIXEL(surface.?.format);
            const mask: u8 = @as(u8, @truncate((1 << @as(u3, @truncate(bpp))) - 1));
            if (c.SDL_PIXELORDER(surface.?.format) == c.SDL_BITMAPORDER_4321) {
                _ = c.SDL_SetSurfaceColorKey(surface, true, @as(u32, @intCast(@as(*u8, @ptrCast(surface.?.pixels)).* & mask)));
            } else {
                _ = c.SDL_SetSurfaceColorKey(surface, true, @as(u32, @intCast((@as(*u8, @ptrCast(surface.?.pixels)).* >> @as(u3, @truncate(8 - bpp))) & mask)));
            }
        } else {
            switch (c.SDL_BITSPERPIXEL(surface.?.format)) {
                15 => _ = c.SDL_SetSurfaceColorKey(surface, true, @as(*u16, @ptrCast(surface.?.pixels)).* & 0x00007FFF),
                16 => _ = c.SDL_SetSurfaceColorKey(surface, true, @as(*u16, @ptrCast(surface.?.pixels)).*),
                24 => _ = c.SDL_SetSurfaceColorKey(surface, true, @as(*u32, @ptrCast(surface.?.pixels)).* & 0x00FFFFFF),
                32 => _ = c.SDL_SetSurfaceColorKey(surface, true, @as(*u32, @ptrCast(surface.?.pixels)).*),
                else => {},
            }
        }
    }

    if (width_out) |w| {
        w.* = surface.?.w;
    }
    if (height_out) |h| {
        h.* = surface.?.h;
    }

    texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Couldn't create texture: %s", c.SDL_GetError());
        return error.TextureCreationFailed;
    };

    return texture.?;
}

pub fn getGpuDeviceForRenderer(renderer: *c.SDL_Renderer) !*c.SDL_GPUDevice {
    return @as(
        *c.SDL_GPUDevice,
        @ptrCast(c.SDL_GetPointerProperty(
            c.SDL_GetRendererProperties(renderer),
            c.SDL_PROP_RENDERER_GPU_DEVICE_POINTER,
            null,
        ) orelse {
            return error.NoGPUDevice;
        }),
    );
}

pub fn loadGPUTexture(device: *c.SDL_GPUDevice, comptime path: []const u8) !*c.SDL_GPUTexture {
    var surface = c.IMG_Load(@ptrCast(path)) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to load image: %s", c.SDL_GetError());
        return error.TextureLoadFailed;
    };
    defer c.SDL_DestroySurface(surface);

    if (surface.*.format != c.SDL_PIXELFORMAT_RGBA8888) {
        const converted = c.SDL_ConvertSurface(surface.*, c.SDL_PIXELFORMAT_RGBA8888) orelse {
            c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to convert image: %s", c.SDL_GetError());
            return error.SurfaceConversionFailed;
        };
        c.SDL_DestroySurface(surface);
        surface = converted;
    }

    const texture = c.SDL_CreateGPUTexture(
        device,
        &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = @intCast(surface.*.w),
            .height = @intCast(surface.*.h),
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        },
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

    const cmd_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to acquire command buffer: %s", c.SDL_GetError());
        return error.CommandBufferAcquisitionFailed;
    };

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buffer) orelse {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to begin copy pass: %s", c.SDL_GetError());
        return error.CopyPassBeginFailed;
    };

    c.SDL_UploadToGPUTexture(copy_pass, &.{
        .transfer_buffer = transfer_buffer,
        .offset = 0,
        .pixels_per_row = surface.*.w,
        .rows_per_layer = surface.*.h,
    }, &.{
        .texture = texture,
        .mip_level = 0,
        .layer = 0,
        .x = 0,
        .y = 0,
        .z = 0,
        .w = surface.*.w,
        .h = surface.*.h,
        .d = 1,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buffer)) {
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Failed to submit command buffer");
        return error.CommandBufferSubmissionFailed;
    }

    return texture;
}
