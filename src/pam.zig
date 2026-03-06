const std = @import("std");
const lib = @import("lib.zig");

const Image = lib.Image;

const PAMLoadError = error{
    FileOpenFailed,
    ReadFailed,
    InvalidFormat,
    InvalidDimensions,
    UnsupportedMaxValue,
    HeaderNotFound,
    InsufficientData,
    UnknownTupltype,
    OutOfMemory,
};

inline fn requantize16to8(value: u16) u8 {
    return @intCast((@as(u32, value) * 255 + 32767) / 65535);
}

pub fn writePam(file: std.fs.File, image: Image) !void {
    if (image.channels != 3 and image.channels != 4) return error.UnsupportedChannels;

    const allocator = std.heap.page_allocator;
    const header = try std.fmt.allocPrint(
        allocator,
        "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH {d}\nMAXVAL 255\nTUPLTYPE {s}\nENDHDR\n",
        .{
            image.width,
            image.height,
            image.channels,
            if (image.channels == 4) "RGB_ALPHA" else "RGB",
        },
    );
    defer allocator.free(header);

    try file.writeAll(header);
    try file.writeAll(image.data);
}

pub fn loadPAM(allocator: std.mem.Allocator, path: []const u8) PAMLoadError!Image {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileOpenFailed;
    defer file.close();

    const file_size = file.getEndPos() catch return error.ReadFailed;

    const file_buffer = allocator.alloc(u8, file_size) catch return error.OutOfMemory;
    defer allocator.free(file_buffer);

    const bytes_read = file.readAll(file_buffer) catch return error.ReadFailed;
    if (bytes_read != file_size) return error.ReadFailed;

    const end_header_idx = std.mem.indexOf(u8, file_buffer, "ENDHDR\n") orelse return error.HeaderNotFound;
    const header_data = file_buffer[0..end_header_idx];
    const data_start = end_header_idx + 7; // "ENDHDR\n" is 7 bytes

    if (!std.mem.startsWith(u8, header_data, "P7"))
        return error.InvalidFormat;

    var width: usize = 0;
    var height: usize = 0;
    var depth: u8 = 0;
    var maxval: usize = 0;
    var lines = std.mem.tokenizeAny(u8, header_data, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.startsWith(u8, line, "WIDTH")) {
            var value_it = std.mem.tokenizeAny(u8, line[5..], " \t");
            if (value_it.next()) |value|
                width = std.fmt.parseInt(usize, value, 10) catch return error.InvalidDimensions;
        } else if (std.mem.startsWith(u8, line, "HEIGHT")) {
            var value_it = std.mem.tokenizeAny(u8, line[6..], " \t");
            if (value_it.next()) |value|
                height = std.fmt.parseInt(usize, value, 10) catch return error.InvalidDimensions;
        } else if (std.mem.startsWith(u8, line, "DEPTH")) {
            var value_it = std.mem.tokenizeAny(u8, line[5..], " \t");
            if (value_it.next()) |value|
                depth = std.fmt.parseInt(u8, value, 10) catch return error.InvalidDimensions;
        } else if (std.mem.startsWith(u8, line, "MAXVAL")) {
            var value_it = std.mem.tokenizeAny(u8, line[6..], " \t");
            if (value_it.next()) |value|
                maxval = std.fmt.parseInt(usize, value, 10) catch return error.UnsupportedMaxValue;
        }
    }

    if (width == 0 or height == 0 or depth == 0 or maxval == 0)
        return error.InvalidDimensions;

    if (maxval > 65535)
        return error.UnsupportedMaxValue;

    const channels = depth;

    const bytes_per_sample: usize = if (maxval <= 255) 1 else 2;
    const expected_data_size = @as(usize, width) * @as(usize, height) * @as(usize, channels) * bytes_per_sample;

    if (data_start + expected_data_size > file_buffer.len)
        return error.InsufficientData;

    const raw_data = file_buffer[data_start..][0..expected_data_size];

    const output_size = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const output = allocator.alloc(u8, output_size) catch return error.OutOfMemory;
    errdefer allocator.free(output);

    if (maxval == 255) {
        @memcpy(output, raw_data);
    } else if (maxval == 65535) {
        for (0..output_size) |i| {
            const high = @as(u16, raw_data[i * 2]);
            const low = @as(u16, raw_data[i * 2 + 1]);
            const value16 = (high << 8) | low;
            output[i] = requantize16to8(value16);
        }
    } else for (0..output_size) |i| {
        const high = @as(u16, raw_data[i * 2]);
        const low = @as(u16, raw_data[i * 2 + 1]);
        const value16 = (high << 8) | low;
        const normalized = (@as(u32, value16) * 65535 + @as(u32, @intCast(maxval)) / 2) / @as(u32, @intCast(maxval));
        output[i] = requantize16to8(@intCast(normalized));
    }

    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .data = output,
    };
}
