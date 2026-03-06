const std = @import("std");
const pam = @import("pam.zig");
const qoi = @import("qoi.zig");

const loadPAM = pam.loadPAM;
const writePam = pam.writePam;

pub const Image = struct {
    width: usize,
    height: usize,
    channels: u8,
    data: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const DitherMode = enum(u8) {
    none = 0,
    sierra_lite = 1,
};

pub const EncodeOptions = struct {
    colorspace: u8 = 0,
    color_depth: u16 = 0,
    dither: DitherMode = .none,
};

pub fn encQoi(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: usize,
    height: usize,
    channels: u8,
    options: EncodeOptions,
) ![]u8 {
    return qoi.encodeAlloc(allocator, .{
        .width = width,
        .height = height,
        .channels = channels,
        .data = @constCast(pixels),
    }, options);
}

pub fn decQoi(allocator: std.mem.Allocator, qoi_bytes: []const u8) !Image {
    return qoi.decodeAlloc(allocator, qoi_bytes);
}

pub fn pamToQoi(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, options: EncodeOptions) !void {
    var image: Image = try loadPAM(allocator, input_path);
    defer image.deinit(allocator);

    const encoded: []u8 = try encQoi(allocator, image.data, image.width, image.height, image.channels, options);
    defer allocator.free(encoded);

    const output = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer output.close();
    try output.writeAll(encoded);
}

pub fn qoiToPam(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const file = try std.fs.cwd().openFile(input_path, .{ .mode = .read_only });
    defer file.close();

    const qoi_bytes: []u8 = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(qoi_bytes);

    var image: Image = try decQoi(allocator, qoi_bytes);
    defer image.deinit(allocator);

    const output = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer output.close();
    try writePam(output, image);
}
