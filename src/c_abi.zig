const std = @import("std");
const lib = @import("lib.zig");

pub const qoilib_status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_input = 2,
    unsupported_channels = 3,
    invalid_dimensions = 4,
    out_of_memory = 5,
    overflow = 6,
    invalid_color_depth = 7,
};

pub const qoilib_encode_options = extern struct {
    colorspace: u8 = 0,
    color_depth: u8 = 0,
    dither: u8 = 0, // 0 = none, 1 = sierra_lite
};

fn mapError(err: anyerror) qoilib_status {
    return switch (err) {
        error.InvalidInput => .invalid_input,
        error.UnsupportedChannels => .unsupported_channels,
        error.InvalidDimensions => .invalid_dimensions,
        error.InvalidColorDepth => .invalid_color_depth,
        error.OutOfMemory => .out_of_memory,
        error.Overflow => .overflow,
        else => .invalid_argument,
    };
}

pub export fn qoilib_status_string(status: qoilib_status) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .invalid_argument => "invalid_argument",
        .invalid_input => "invalid_input",
        .unsupported_channels => "unsupported_channels",
        .invalid_dimensions => "invalid_dimensions",
        .out_of_memory => "out_of_memory",
        .overflow => "overflow",
        .invalid_color_depth => "invalid_color_depth",
    };
}

pub export fn qoilib_free(ptr: ?*anyopaque, len: usize) void {
    const raw = ptr orelse return;
    const bytes: [*]u8 = @ptrCast(@alignCast(raw));
    std.heap.c_allocator.free(bytes[0..len]);
}

pub export fn qoilib_encode(
    pixels: [*]const u8,
    width: usize,
    height: usize,
    channels: u8,
    options: qoilib_encode_options,
    out_len: *usize,
    out_status: *qoilib_status,
) ?[*]u8 {
    if (width == 0 or height == 0) {
        out_status.* = .invalid_dimensions;
        return null;
    }
    if (channels != 3 and channels != 4) {
        out_status.* = .unsupported_channels;
        return null;
    }

    const image_len = std.math.mul(usize, std.math.mul(usize, width, height) catch {
        out_status.* = .overflow;
        return null;
    }, channels) catch {
        out_status.* = .overflow;
        return null;
    };

    const dither_mode = std.meta.intToEnum(lib.DitherMode, options.dither) catch {
        out_status.* = .invalid_argument;
        return null;
    };

    const encoded = lib.encQoi(std.heap.c_allocator, pixels[0..image_len], width, height, channels, .{
        .colorspace = options.colorspace,
        .color_depth = options.color_depth,
        .dither = dither_mode,
    }) catch |err| {
        out_status.* = mapError(err);
        return null;
    };

    out_len.* = encoded.len;
    out_status.* = .ok;
    return encoded.ptr;
}

pub export fn qoilib_decode(
    qoi_bytes: [*]const u8,
    qoi_len: usize,
    out_width: *usize,
    out_height: *usize,
    out_channels: *u8,
    out_len: *usize,
    out_status: *qoilib_status,
) ?[*]u8 {
    const image = lib.decQoi(std.heap.c_allocator, qoi_bytes[0..qoi_len]) catch |err| {
        out_status.* = mapError(err);
        return null;
    };

    out_width.* = image.width;
    out_height.* = image.height;
    out_channels.* = image.channels;
    out_len.* = image.data.len;
    out_status.* = .ok;
    return image.data.ptr;
}
