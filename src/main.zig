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

fn enumFromInt(comptime E: type, value: anytype) !E {
    return std.enums.fromInt(E, value) orelse error.InvalidInput;
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();

    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(allocator);
    while (arg_iter.next()) |arg| try args.append(allocator, arg);

    if (args.items.len < 2 or std.mem.eql(u8, args.items[1], "-h") or std.mem.eql(u8, args.items[1], "--help")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, args.items[1], "enc")) {
        if (args.items.len < 4 or args.items.len > 7) {
            printUsage();
            return;
        }

        const colorspace: u8 = if (args.items.len >= 5) try std.fmt.parseInt(u8, args.items[4], 10) else 0;
        const color_depth: u16 = if (args.items.len >= 6) try std.fmt.parseInt(u16, args.items[5], 10) else 0;
        const dither: lib.DitherMode = if (args.items.len >= 7)
            try enumFromInt(lib.DitherMode, try std.fmt.parseInt(u8, args.items[6], 10))
        else
            .none;
        var image = try pam.loadPAM(init.io, allocator, args.items[2]);
        defer image.deinit(allocator);

        const encoded = try lib.encQoi(allocator, image.data, image.width, image.height, image.channels, .{
            .colorspace = colorspace,
            .color_depth = color_depth,
            .dither = dither,
        });
        defer allocator.free(encoded);

        const output = try std.Io.Dir.cwd().createFile(init.io, args.items[3], .{ .truncate = true });
        defer output.close(init.io);
        try output.writeStreamingAll(init.io, encoded);
        std.debug.print("Encoded {s} -> {s}\n", .{ args.items[2], args.items[3] });
        return;
    }

    if (std.mem.eql(u8, args.items[1], "dec")) {
        if (args.items.len != 4) {
            printUsage();
            return;
        }

        try lib.qoiToPam(init.io, allocator, args.items[2], args.items[3]);
        std.debug.print("Decoded {s} -> {s}\n", .{ args.items[2], args.items[3] });
        return;
    }

    printUsage();
}
