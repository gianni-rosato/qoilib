const std = @import("std");
const lib = @import("lib.zig");

const Image = lib.Image;
const DitherMode = lib.DitherMode;
const EncodeOptions = lib.EncodeOptions;

const qoi_magic = "qoif";
const qoi_padding = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const QoiError = error{
    InvalidInput,
    UnsupportedChannels,
    InvalidDimensions,
    InvalidColorDepth,
    Overflow,
} || std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.fs.File.StatError;

const QoiOp = enum(u8) {
    rgb = 0xFE,
    rgba = 0xFF,
    index = 0x00,
    diff = 0x40,
    luma = 0x80,
    run = 0xC0,
};

const QoiPixel = extern union {
    vals: extern struct {
        red: u8,
        green: u8,
        blue: u8,
        alpha: u8,
    },
    channels: [4]u8,
    rgba: u32,
};

const QoiDesc = struct {
    width: u32,
    height: u32,
    channels: u8,
    colorspace: u8,

    fn write(self: QoiDesc, dest: *[14]u8) void {
        @memcpy(dest[0..4], qoi_magic);
        std.mem.writeInt(u32, dest[4..8], self.width, .big);
        std.mem.writeInt(u32, dest[8..12], self.height, .big);
        dest[12] = self.channels;
        dest[13] = self.colorspace;
    }

    fn read(src: []const u8) !QoiDesc {
        if (src.len < 14) return error.InvalidInput;
        if (!std.mem.eql(u8, src[0..4], qoi_magic)) return error.InvalidInput;

        return .{
            .width = std.mem.readInt(u32, src[4..8], .big),
            .height = std.mem.readInt(u32, src[8..12], .big),
            .channels = src[12],
            .colorspace = src[13],
        };
    }
};

fn hashPixel(pixel: QoiPixel) u6 {
    return @truncate(pixel.vals.red *% 3 +% pixel.vals.green *% 5 +% pixel.vals.blue *% 7 +% pixel.vals.alpha *% 11);
}

fn pixelsEqual(a: QoiPixel, b: QoiPixel) bool {
    return a.rgba == b.rgba;
}

fn paletteQuantizeInPlace(data: []u8, channels: u8, quantize_factor: u16) void {
    for (0..data.len / channels) |pixel| {
        const offset = pixel * channels;
        for (0..channels) |channel| {
            const value = data[offset + channel];
            data[offset + channel] = @intCast(@as(u16, value) / quantize_factor * quantize_factor);
        }
    }
}

fn sierraLiteInPlace(data: []u8, width: usize, height: usize, channels: u8, quantize_factor: u16) void {
    const quantize_factor_f32: f32 = @floatFromInt(quantize_factor);

    for (0..height) |y| {
        for (0..width) |x| {
            const pixel_index = (y * width + x) * channels;
            var new_pixel: [3]u8 = undefined;

            for (0..3) |channel| {
                const pixel_value: f32 = @floatFromInt(data[pixel_index + channel]);
                const quantized = @as(i16, @intFromFloat(@round(pixel_value / quantize_factor_f32) * quantize_factor_f32));
                new_pixel[channel] = @intCast(std.math.clamp(quantized, 0, 255));

                const quantization_error = pixel_value - @as(f32, @floatFromInt(new_pixel[channel]));

                if (x + 1 < width) {
                    const neighbor = (y * width + (x + 1)) * channels + channel;
                    const adjusted = @as(i16, @intFromFloat(@as(f32, @floatFromInt(data[neighbor])) + quantization_error * 0.5));
                    data[neighbor] = @intCast(std.math.clamp(adjusted, 0, 255));
                }

                if (y + 1 < height) {
                    if (x > 0) {
                        const neighbor = ((y + 1) * width + (x - 1)) * channels + channel;
                        const adjusted = @as(i16, @intFromFloat(@as(f32, @floatFromInt(data[neighbor])) + quantization_error * 0.25));
                        data[neighbor] = @intCast(std.math.clamp(adjusted, 0, 255));
                    }

                    const neighbor = ((y + 1) * width + x) * channels + channel;
                    const adjusted = @as(i16, @intFromFloat(@as(f32, @floatFromInt(data[neighbor])) + quantization_error * 0.25));
                    data[neighbor] = @intCast(std.math.clamp(adjusted, 0, 255));
                }
            }

            @memcpy(data[pixel_index .. pixel_index + 3], &new_pixel);
        }
    }
}

fn preprocessPixels(allocator: std.mem.Allocator, image: Image, options: EncodeOptions) QoiError!?[]u8 {
    if (options.dither != .none and options.color_depth == 0) return error.InvalidColorDepth;
    if (options.color_depth == 0) return null;
    if (options.color_depth > 256) return error.InvalidColorDepth;

    const quantize_factor = @as(u16, 256) / options.color_depth;
    if (quantize_factor == 0) return error.InvalidColorDepth;

    const working = try allocator.dupe(u8, image.data);
    errdefer allocator.free(working);

    switch (options.dither) {
        .none => paletteQuantizeInPlace(working, image.channels, quantize_factor),
        .sierra_lite => sierraLiteInPlace(working, image.width, image.height, image.channels, quantize_factor),
    }

    return working;
}

pub fn encodeAlloc(allocator: std.mem.Allocator, image: Image, options: EncodeOptions) QoiError![]u8 {
    if (image.width == 0 or image.height == 0) return error.InvalidDimensions;
    if (image.channels != 3 and image.channels != 4) return error.UnsupportedChannels;

    const pixels = try std.math.mul(usize, image.width, image.height);
    const expected_len = try std.math.mul(usize, pixels, image.channels);
    if (image.data.len < expected_len) return error.InvalidInput;

    const maybe_preprocessed = try preprocessPixels(allocator, image, options);
    defer if (maybe_preprocessed) |working| allocator.free(working);
    const source = maybe_preprocessed orelse image.data;

    const desc: QoiDesc = .{
        .width = std.math.cast(u32, image.width) orelse return error.InvalidDimensions,
        .height = std.math.cast(u32, image.height) orelse return error.InvalidDimensions,
        .channels = image.channels,
        .colorspace = options.colorspace,
    };

    const max_size_a = try std.math.mul(usize, pixels, image.channels + 1);
    const max_size = try std.math.add(usize, max_size_a, 14 + qoi_padding.len);
    var encoded = try allocator.alloc(u8, max_size);
    errdefer allocator.free(encoded);

    desc.write(encoded[0..14]);

    var index: [64]QoiPixel = undefined;
    for (&index) |*entry|
        entry.channels = .{ 0, 0, 0, 255 };

    var prev: QoiPixel = .{ .channels = .{ 0, 0, 0, 255 } };
    var run: u8 = 0;
    var in_offset: usize = 0;
    var out_offset: usize = 14;

    for (0..pixels) |_| {
        var cur: QoiPixel = .{ .channels = .{ 0, 0, 0, 255 } };
        @memcpy(cur.channels[0..image.channels], source[in_offset .. in_offset + image.channels]);
        in_offset += image.channels;

        if (pixelsEqual(cur, prev)) {
            run += 1;
            if (run == 62) {
                encoded[out_offset] = @intFromEnum(QoiOp.run) | (run - 1);
                out_offset += 1;
                run = 0;
            }
            continue;
        }

        if (run > 0) {
            encoded[out_offset] = @intFromEnum(QoiOp.run) | (run - 1);
            out_offset += 1;
            run = 0;
        }

        const index_pos = hashPixel(cur);
        if (pixelsEqual(index[index_pos], cur)) {
            encoded[out_offset] = @intFromEnum(QoiOp.index) | index_pos;
            out_offset += 1;
            prev = cur;
            continue;
        }

        index[index_pos] = cur;

        if (cur.vals.alpha == prev.vals.alpha) {
            const dr = @as(i32, cur.vals.red) - @as(i32, prev.vals.red);
            const dg = @as(i32, cur.vals.green) - @as(i32, prev.vals.green);
            const db = @as(i32, cur.vals.blue) - @as(i32, prev.vals.blue);

            if (dr >= -2 and dr <= 1 and dg >= -2 and dg <= 1 and db >= -2 and db <= 1) {
                encoded[out_offset] = @intFromEnum(QoiOp.diff) |
                    (@as(u8, @intCast(dr + 2)) << 4) |
                    (@as(u8, @intCast(dg + 2)) << 2) |
                    @as(u8, @intCast(db + 2));
                out_offset += 1;
                prev = cur;
                continue;
            }

            const dr_dg = dr - dg;
            const db_dg = db - dg;
            if (dg >= -32 and dg <= 31 and dr_dg >= -8 and dr_dg <= 7 and db_dg >= -8 and db_dg <= 7) {
                encoded[out_offset] = @intFromEnum(QoiOp.luma) | @as(u8, @intCast(dg + 32));
                encoded[out_offset + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | @as(u8, @intCast(db_dg + 8));
                out_offset += 2;
                prev = cur;
                continue;
            }

            encoded[out_offset] = @intFromEnum(QoiOp.rgb);
            encoded[out_offset + 1] = cur.vals.red;
            encoded[out_offset + 2] = cur.vals.green;
            encoded[out_offset + 3] = cur.vals.blue;
            out_offset += 4;
            prev = cur;
            continue;
        }

        encoded[out_offset] = @intFromEnum(QoiOp.rgba);
        encoded[out_offset + 1] = cur.vals.red;
        encoded[out_offset + 2] = cur.vals.green;
        encoded[out_offset + 3] = cur.vals.blue;
        encoded[out_offset + 4] = cur.vals.alpha;
        out_offset += 5;
        prev = cur;
    }

    if (run > 0) {
        encoded[out_offset] = @intFromEnum(QoiOp.run) | (run - 1);
        out_offset += 1;
    }

    @memcpy(encoded[out_offset .. out_offset + qoi_padding.len], &qoi_padding);
    out_offset += qoi_padding.len;

    return allocator.realloc(encoded, out_offset);
}

pub fn decodeAlloc(allocator: std.mem.Allocator, qoi_bytes: []const u8) QoiError!Image {
    if (qoi_bytes.len < 14 + qoi_padding.len) return error.InvalidInput;

    const desc = try QoiDesc.read(qoi_bytes[0..14]);
    if (desc.width == 0 or desc.height == 0) return error.InvalidDimensions;
    if (desc.channels != 3 and desc.channels != 4) return error.UnsupportedChannels;

    const pixel_count = try std.math.mul(usize, desc.width, desc.height);
    const out_len = try std.math.mul(usize, pixel_count, desc.channels);
    var output = try allocator.alloc(u8, out_len);
    errdefer allocator.free(output);

    var index: [64]QoiPixel = undefined;
    for (&index) |*entry|
        entry.channels = .{ 0, 0, 0, 255 };

    var prev: QoiPixel = .{ .channels = .{ 0, 0, 0, 255 } };
    var run: usize = 0;
    var in_offset: usize = 14;
    var out_offset: usize = 0;

    while (out_offset < out_len) {
        if (run > 0) {
            run -= 1;
        } else {
            if (in_offset >= qoi_bytes.len - qoi_padding.len) return error.InvalidInput;
            const tag = qoi_bytes[in_offset];

            switch (tag) {
                @intFromEnum(QoiOp.rgb) => {
                    if (in_offset + 4 > qoi_bytes.len - qoi_padding.len) return error.InvalidInput;
                    prev.vals.red = qoi_bytes[in_offset + 1];
                    prev.vals.green = qoi_bytes[in_offset + 2];
                    prev.vals.blue = qoi_bytes[in_offset + 3];
                    in_offset += 4;
                },
                @intFromEnum(QoiOp.rgba) => {
                    if (in_offset + 5 > qoi_bytes.len - qoi_padding.len) return error.InvalidInput;
                    prev.vals.red = qoi_bytes[in_offset + 1];
                    prev.vals.green = qoi_bytes[in_offset + 2];
                    prev.vals.blue = qoi_bytes[in_offset + 3];
                    prev.vals.alpha = qoi_bytes[in_offset + 4];
                    in_offset += 5;
                },
                else => {
                    const op = tag & 0xC0;
                    switch (op) {
                        @intFromEnum(QoiOp.index) => {
                            prev = index[tag & 0x3F];
                            in_offset += 1;
                        },
                        @intFromEnum(QoiOp.diff) => {
                            prev.vals.red +%= ((tag >> 4) & 0x03) -% 2;
                            prev.vals.green +%= ((tag >> 2) & 0x03) -% 2;
                            prev.vals.blue +%= (tag & 0x03) -% 2;
                            in_offset += 1;
                        },
                        @intFromEnum(QoiOp.luma) => {
                            if (in_offset + 2 > qoi_bytes.len - qoi_padding.len) return error.InvalidInput;
                            const b2 = qoi_bytes[in_offset + 1];
                            const dg: u8 = (tag & 0x3F) -% 32;
                            prev.vals.red +%= dg +% ((b2 >> 4) & 0x0F) -% 8;
                            prev.vals.green +%= dg;
                            prev.vals.blue +%= dg +% (b2 & 0x0F) -% 8;
                            in_offset += 2;
                        },
                        @intFromEnum(QoiOp.run) => {
                            run = (tag & 0x3F);
                            in_offset += 1;
                        },
                        else => return error.InvalidInput,
                    }
                },
            }

            index[hashPixel(prev)] = prev;
        }

        @memcpy(output[out_offset .. out_offset + desc.channels], prev.channels[0..desc.channels]);
        out_offset += desc.channels;
    }

    if (!std.mem.eql(u8, qoi_bytes[qoi_bytes.len - qoi_padding.len ..], &qoi_padding))
        return error.InvalidInput;

    return .{
        .width = desc.width,
        .height = desc.height,
        .channels = desc.channels,
        .data = output,
    };
}
