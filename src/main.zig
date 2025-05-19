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

pub fn processEvents(window: *c.SDL_Window) void {
    _ = window;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
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
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "SDL_Init failed: %s", c.SDL_GetError());
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

    while (global_running) {
        processEvents(global_window);

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
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Couldn't load %s: %s", file_to_load, c.SDL_GetError());
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
        c.SDL_LogError(c.SDL_LOG_CATEGORY_APPLICATION, "Couldn't create texture: %s", c.SDL_GetError());
        return error.TextureCreationFailed;
    };

    return texture.?;
}
