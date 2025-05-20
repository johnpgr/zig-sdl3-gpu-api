const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_OLDNAMES", {});
    @cInclude("SDL3/SDL.h");
});

pub const NUM_SPRITES = 15;
pub const MAX_SPEED = 1;
pub const WINDOW_WIDTH = 408 * 2;
pub const WINDOW_HEIGHT = 167 * 2;

pub var global_running = true;
pub var global_window: *c.SDL_Window = undefined;
pub var global_renderer: *c.SDL_Renderer = undefined;
pub var global_device: *c.SDL_GPUDevice = undefined;
pub var global_target: *c.SDL_Texture = undefined;
pub var global_background: *c.SDL_Texture = undefined;
pub var global_sprite: *c.SDL_Texture = undefined;
pub var global_positions: [NUM_SPRITES]c.SDL_FRect = undefined;
pub var global_velocities: [NUM_SPRITES]c.SDL_FPoint = undefined;
pub var current_effect_idx: i32 = 0;

const FullscreenEffect = enum {
    EFFECT_NONE,
    EFFECT_GRAYSCALE,
    EFFECT_CRT,
    NUM_EFFECTS,
};

const FullscreenEffectData = struct {
    name: [*:0]const u8,
    dxil_shader_source: [*]const u8,
    dxil_shader_source_len: u32,
    msl_shader_source: [*]const u8,
    msl_shader_source_len: u32,
    spirv_shader_source: [*]const u8,
    spirv_shader_source_len: u32,
    num_samplers: i32,
    num_uniform_buffers: i32,
    shader: *c.SDL_GPUShader,
    state: *c.SDL_GPURenderState,
};

const CRTEffectUniforms = struct {
    texture_width: f32,
    texture_height: f32,
};

pub const effects = [_]FullscreenEffectData{
    .{
        .name = "NONE",
        .dxil_shader_source = null,
        .dxil_shader_source_len = 0,
        .msl_shader_source = null,
        .msl_shader_source_len = 0,
        .spirv_shader_source = null,
        .spirv_shader_source_len = 0,
        .num_samplers = 0,
        .num_uniform_buffers = 0,
        .shader = null,
        .state = null,
    },
    .{
        .name = "Grayscale",
        .dxil_shader_source = null,
        .dxil_shader_source_len = 0,
        .msl_shader_source = null,
        .msl_shader_source_len = 0,
        .spirv_shader_source = null,
        .spirv_shader_source_len = 0,
        .num_samplers = 1,
        .num_uniform_buffers = 0,
        .shader = null,
        .state = null,
    },
    .{
        .name = "CRT monitor",
        .dxil_shader_source = null,
        .dxil_shader_source_len = 0,
        .msl_shader_source = null,
        .msl_shader_source_len = 0,
        .spirv_shader_source = null,
        .spirv_shader_source_len = 0,
        .num_samplers = 1,
        .num_uniform_buffers = 1,
        .shader = null,
        .state = null,
    },
};

pub fn initEffects(device: *c.SDL_GPUDevice) !void {
    for (effects) |*effect| {
        if (std.mem.eql(u8, std.mem.span(effect.name), "NONE")) {
            continue;
        }

        const shader_name = if (std.mem.eql(u8, std.mem.span(effect.name), "Grayscale"))
            "assets/shaders/compiled/grayscale.frag.spv"
        else if (std.mem.eql(u8, std.mem.span(effect.name), "CRT monitor"))
            "assets/shaders/compiled/crt.frag.spv"
        else
            continue;

        effect.shader = try loadShader(device, shader_name, @intCast(effect.num_samplers), @intCast(effect.num_uniform_buffers), 0, 0);
    }
}

pub fn drawScene() void {
    var position: *c.SDL_FRect = undefined;
    var velocity: *c.SDL_FPoint = undefined;

    _ = c.SDL_RenderTexture(global_renderer, global_background, null,null);

    var i: i32 = 0;
    while (i < NUM_SPRITES) : (i += 1) {
        position = &global_positions[i];
        velocity = &global_velocities[i];
        position.x += velocity.x;
        if ((position.x < 0) || (position.x >= (WINDOW_WIDTH - global_sprite.w))) {
            velocity.x = -velocity.x;
            position.x += velocity.x;
        }
        position.y += velocity.y;
        if ((position.y < 0) || (position.y >= (WINDOW_HEIGHT - global_sprite.h))) {
            velocity.y = -velocity.y;
            position.y += velocity.y;
        }
        c.SDL_RenderTexture(global_renderer, global_sprite, null, position);
    }
}


pub fn initGPURenderState() !void {
    var formats: c.SDL_GPUShaderFormat = undefined;
    var info: c.SDL_GPUShaderCreateInfo = undefined;
    var desc: c.SDL_GPURenderStateDesc = undefined;

    global_device = try getGpuDeviceForRenderer(global_renderer);

    formats = c.SDL_GetGPUShaderFormats(global_device);
    if (formats == c.SDL_GPU_SHADERFORMAT_INVALID) {
        c.SDL_Log("Couldn't get supported shader formats: %s", c.SDL_GetError());
        return error.ShaderFormatError;
    }

    for (effects, 0..) |*data, i| {
        if (i == @intFromEnum(FullscreenEffect.EFFECT_NONE)) {
            continue;
        }

        // Zero initialize the info struct
        @memset(std.mem.asBytes(&info), 0);

        if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
            info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
            info.code = data.spirv_shader_source;
            info.code_size = data.spirv_shader_source_len;
            info.entrypoint = "main";
        } else if (formats & c.SDL_GPU_SHADERFORMAT_DXIL != 0) {
            info.format = c.SDL_GPU_SHADERFORMAT_DXIL;
            info.code = data.dxil_shader_source;
            info.code_size = data.dxil_shader_source_len;
            info.entrypoint = "main";
        } else if (formats & c.SDL_GPU_SHADERFORMAT_MSL != 0) {
            info.format = c.SDL_GPU_SHADERFORMAT_MSL;
            info.code = data.msl_shader_source;
            info.code_size = data.msl_shader_source_len;
            info.entrypoint = "main0";
        } else {
            c.SDL_Log("No supported shader format found");
            return error.NoSupportedShaderFormat;
        }

        info.num_samplers = @intCast(data.num_samplers);
        info.num_uniform_buffers = @intCast(data.num_uniform_buffers);
        info.stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT;

        data.shader = c.SDL_CreateGPUShader(global_device, &info) orelse {
            c.SDL_Log("Couldn't create shader: %s", c.SDL_GetError());
            return error.ShaderCreationFailed;
        };

        // Zero initialize the desc struct
        @memset(std.mem.asBytes(&desc), 0);
        desc.fragment_shader = data.shader;
        
        data.state = c.SDL_CreateGPURenderState(global_renderer, &desc) orelse {
            c.SDL_Log("Couldn't create render state: %s", c.SDL_GetError());
            return error.RenderStateCreationFailed;
        };

        if (i == @intFromEnum(FullscreenEffect.EFFECT_CRT)) {
            var uniforms: CRTEffectUniforms = undefined;
            @memset(std.mem.asBytes(&uniforms), 0);
            uniforms.texture_width = @floatFromInt(global_target.w);
            uniforms.texture_height = @floatFromInt(global_target.h);
            
            if (c.SDL_SetGPURenderStateFragmentUniformData(data.state, 0, &uniforms, @sizeOf(CRTEffectUniforms)) == 0) {
                c.SDL_Log("Couldn't set uniform data: %s", c.SDL_GetError());
                return error.UniformDataError;
            }
        }
    }
}

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

pub fn getGpuDeviceForRenderer(renderer: *c.SDL_Renderer) !*c.SDL_GPUDevice {
    return @as(*c.SDL_GPUDevice, @ptrCast(c.SDL_GetPointerProperty(
        c.SDL_GetRendererProperties(renderer),
        c.SDL_PROP_RENDERER_GPU_DEVICE_POINTER,
        null,
    ) orelse {
        return error.NoGPUDevice;
    }));
}

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        c.SDL_Log("SDL_Init failed: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_VERBOSE);

    global_window = c.SDL_CreateWindow("SDL3 Renderer + GPU Example", WINDOW_WIDTH, WINDOW_HEIGHT, 0) orelse {
        c.SDL_Log("SDL_CreateWindow failed: %s", c.SDL_GetError());
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(global_window);

    global_renderer = c.SDL_CreateRenderer(global_window, "gpu") orelse {
        c.SDL_Log("SDL_CreateRenderer failed: %s", c.SDL_GetError());
        return error.RendererCreationFailed;
    };
    defer c.SDL_DestroyRenderer(global_renderer);

    if (!c.SDL_SetRenderVSync(global_renderer, 1)) {
        c.SDL_Log("SDL_SetRenderVSync failed: %s", c.SDL_GetError());
        return error.VSyncFailed;
    }

    global_device = getGpuDeviceForRenderer(global_renderer) catch {
        c.SDL_Log("SDL_GetPointerProperty failed: %s", c.SDL_GetError());
        return error.GPUDeviceRetrievalFailed;
    };
    defer c.SDL_DestroyGPUDevice(global_device);

    c.SDL_Log("GPU device: %s", c.SDL_GetGPUDeviceDriver(global_device));

    try initEffects(global_device);
    defer {
        for (effects) |effect| {
            if (effect.shader) |shader| {
                c.SDL_ReleaseGPUShader(global_device, shader);
            }
        }
    }

    while (global_running) {
        var event: *c.SDL_Event = undefined;
        handleAppEvent(&event);

        _ = c.SDL_SetRenderDrawColor(global_renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(global_renderer);
        _ = c.SDL_RenderPresent(global_renderer);
    }

    // target = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, c.WINDOW_WIDTH, c.WINDOW_HEIGHT) orelse {
    //     c.SDL_Log("Couldn't create target texture: %s", SDL_GetError());
    //     return error.TargetTextureCreationFailed;
    // };
    // defer c.SDL_DestroyTexture(target);
    //
    // background = loadTexture(renderer, "sample.bmp", false, null, null) orelse {
    //     c.SDL_Log("Couldn't load background texture: %s", SDL_GetError());
    //     return error.BackgroundTextureLoadFailed;
    // }
    // defer c.SDL_DestroyTexture(background);
    //
    // sprite = loadTexture(renderer, "icon.bmp", true, null, null) orelse {
    //     c.SDL_Log("Couldn't load sprite texture: %s", SDL_GetError());
    //     return error.SpriteTextureLoadFailed;
    // };
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
        c.SDL_Log("Couldn't load %s: %s", file_to_load, c.SDL_GetError());
        return error.LoadBMPFailed;
    };
    defer c.SDL_FreeSurface(surface);

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
        c.SDL_Log("Couldn't create texture: %s", c.SDL_GetError());
        return error.TextureCreationFailed;
    };

    return texture.?;
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
