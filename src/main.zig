const std = @import("std");
const lib = @import("lib.zig");
const pam = @import("pam.zig");

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  qoi enc <input.pam> <output.qoi> [colorspace] [color_depth] [dither]
        \\  qoi dec <input.qoi> <output.pam>
        \\
        \\Colorspace:
        \\  0 = sRGB with linear alpha
        \\  1 = all channels linear
        \\
        \\Color depth:
        \\  0 = no preprocessing
        \\  1-256 = palette quantization levels
        \\
        \\Dither:
        \\  0 = none
        \\  1 = Sierra Lite
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "enc")) {
        if (args.len < 4 or args.len > 7) {
            printUsage();
            return;
        }

        const colorspace: u8 = if (args.len >= 5) try std.fmt.parseInt(u8, args[4], 10) else 0;
        const color_depth: u16 = if (args.len >= 6) try std.fmt.parseInt(u16, args[5], 10) else 0;
        const dither: lib.DitherMode = if (args.len >= 7)
            std.meta.intToEnum(lib.DitherMode, try std.fmt.parseInt(u8, args[6], 10)) catch return error.InvalidInput
        else
            .none;
        var image = try pam.loadPAM(allocator, args[2]);
        defer image.deinit(allocator);

        const encoded = try lib.encQoi(allocator, image.data, image.width, image.height, image.channels, .{
            .colorspace = colorspace,
            .color_depth = color_depth,
            .dither = dither,
        });
        defer allocator.free(encoded);

        const output = try std.fs.cwd().createFile(args[3], .{ .truncate = true });
        defer output.close();
        try output.writeAll(encoded);
        std.debug.print("Encoded {s} -> {s}\n", .{ args[2], args[3] });
        return;
    }

    if (std.mem.eql(u8, args[1], "dec")) {
        if (args.len != 4) {
            printUsage();
            return;
        }

        try lib.qoiToPam(allocator, args[2], args[3]);
        std.debug.print("Decoded {s} -> {s}\n", .{ args[2], args[3] });
        return;
    }

    printUsage();
}
