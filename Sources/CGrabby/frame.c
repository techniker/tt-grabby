// Frame copy and deinterlacing for packed YUYV.
//
// Averaging works byte-wise because luma and chroma sit at the same byte
// offsets on every line, so the loops stay simple enough to auto-vectorize.

#include "grabby.h"

#include <string.h>

static void average_lines(const uint8_t *a, const uint8_t *b, uint8_t *dst, int n) {
    for (int i = 0; i < n; i++) dst[i] = (uint8_t)((a[i] + b[i] + 1) >> 1);
}

void grabby_copy_frame(const uint8_t *src, int src_stride, uint8_t *dst, int dst_stride,
                       int width, int height, grabby_deinterlace_t mode) {
    int n = width * 2;
    switch (mode) {
        case GRABBY_DEINTERLACE_BLEND:
            for (int y = 0; y < height - 1; y++)
                average_lines(src + y * src_stride, src + (y + 1) * src_stride,
                              dst + y * dst_stride, n);
            memcpy(dst + (height - 1) * dst_stride, src + (height - 1) * src_stride, n);
            break;

        case GRABBY_DEINTERLACE_BOB:
            for (int y = 0; y < height; y += 2) {
                const uint8_t *line = src + y * src_stride;
                memcpy(dst + y * dst_stride, line, n);
                if (y + 1 >= height) break;
                if (y + 2 < height)
                    average_lines(line, src + (y + 2) * src_stride, dst + (y + 1) * dst_stride, n);
                else
                    memcpy(dst + (y + 1) * dst_stride, line, n);
            }
            break;

        default:
            if (src_stride == dst_stride) {
                memcpy(dst, src, (size_t)src_stride * height);
            } else {
                for (int y = 0; y < height; y++)
                    memcpy(dst + y * dst_stride, src + y * src_stride, n);
            }
    }
}
