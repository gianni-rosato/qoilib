# qoilib

Simple [QOI](https://qoiformat.org) implementation in Zig.

Succeeds [qoi-enc-zig](https://github.com/gianni-rosato/qoi-enc-zig) and
[qoi-dec-zig](https://github.com/gianni-rosato/qoi-dec-zig).

## Compilation

Requires [Zig](https://ziglang.org) ≥0.16.0

```bash
zig build                 # Debug
zig build --release=fast  # Release
```

This produces:

- `qoi` - CLI tool for encoding/decoding
- `libqoilib` - Dynamic library for C usage

## Zig Usage

Add as a dependency to your Zig project:

```sh
zig fetch --save git+https://github.com/gianni-rosato/qoilib.git
```

In `build.zig`:

```zig
const qoilib = b.dependency("qoilib", .{});
exe.root_module.addImport("qoilib", qoilib.module("qoilib"));
```

Basic usage:

```zig
const qoilib = @import("qoilib");

// Encode
const encoded = try qoilib.encQoi(allocator, pixels, width, height, channels, .{});
defer allocator.free(encoded);

// Decode
const image = try qoilib.decQoi(allocator, qoi_bytes);
defer image.deinit(allocator);
// image.width, image.height, image.channels, image.data
```

## C Usage

Link against `libqoilib` and include `qoilib.h`:

```c
#include "qoilib.h"

// Encode
size_t out_len;
qoilib_status status;
uint8_t *encoded = qoilib_encode(pixels, width, height, channels,
    (qoilib_encode_options){0}, &out_len, &status);

if (status == QOILIB_STATUS_OK) {
    // use encoded[0..out_len]
    qoilib_free(encoded, out_len);
}

// Decode
size_t width, height, len;
uint8_t channels;
uint8_t *pixels = qoilib_decode(qoi_bytes, qoi_len, &width, &height,
    &channels, &len, &status);
```

## CLI Tool

Convert between PAM and QOI formats:

```bash
# PAM -> QOI
./qoi enc input.pam output.qoi [colorspace] [color_depth] [dither]

# QOI -> PAM
./qoi dec input.qoi output.pam
```

- `colorspace`: 0 = sRGB with linear alpha (default), 1 = all channels linear
- `color_depth`: 0 = no preprocessing, 1-256 = palette quantization levels
- `dither`: 0 = none (default), 1 = Sierra Lite
