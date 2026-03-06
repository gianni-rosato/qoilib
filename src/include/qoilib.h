#ifndef QOILIB_H
#define QOILIB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum qoilib_status {
    QOILIB_STATUS_OK = 0,
    QOILIB_STATUS_INVALID_ARGUMENT = 1,
    QOILIB_STATUS_INVALID_INPUT = 2,
    QOILIB_STATUS_UNSUPPORTED_CHANNELS = 3,
    QOILIB_STATUS_INVALID_DIMENSIONS = 4,
    QOILIB_STATUS_OUT_OF_MEMORY = 5,
    QOILIB_STATUS_OVERFLOW = 6,
    QOILIB_STATUS_INVALID_COLOR_DEPTH = 7
} qoilib_status;

typedef struct qoilib_encode_options {
    uint8_t colorspace;   // 0 = sRGB with linear alpha, 1 = all channels linear
    uint8_t color_depth;  // bits per channel (0 for default, 1-16 for depth reduction)
    uint8_t dither;       // 0 = none, 1 = sierra lite
} qoilib_encode_options;

// Get a string description of a status code
const char *qoilib_status_string(qoilib_status status);

// Free memory allocated by qoilib_encode or qoilib_decode
void qoilib_free(void *ptr, size_t len);

// Encode RGB or RGBA pixels to QOI format
// Returns: pointer to encoded QOI data (must be freed with qoilib_free) or NULL on error
uint8_t *qoilib_encode(
    const uint8_t *pixels,
    size_t width,
    size_t height,
    uint8_t channels,
    qoilib_encode_options options,
    size_t *out_len,
    qoilib_status *out_status
);

// Decode QOI data to RGB or RGBA pixels
// Returns: pointer to decoded pixel data (must be freed with qoilib_free) or NULL on error
uint8_t *qoilib_decode(
    const uint8_t *qoi_bytes,
    size_t qoi_len,
    size_t *out_width,
    size_t *out_height,
    uint8_t *out_channels,
    size_t *out_len,
    qoilib_status *out_status
);

#ifdef __cplusplus
}
#endif

#endif // QOILIB_H
