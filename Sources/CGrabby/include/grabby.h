// User-space driver for the TerraTec Grabby (Empia EM2860 + Philips SAA7113).
//
// The Grabby is not a UVC device, so macOS has no driver for its video
// function. This library claims the vendor-specific video interface through
// libusb, programs the bridge and decoder, and reassembles the isochronous
// field stream into interlaced YUYV frames. Audio is a standard USB Audio
// Class interface and is left to CoreAudio.

#ifndef GRABBY_H
#define GRABBY_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GRABBY_VID 0x0ccd
#define GRABBY_PID 0x0096

typedef struct grabby grabby_t;

typedef enum {
    GRABBY_OK = 0,
    GRABBY_ERR_NOT_FOUND = -1,
    GRABBY_ERR_ACCESS = -2,
    GRABBY_ERR_BUSY = -3,
    GRABBY_ERR_IO = -4,
    GRABBY_ERR_NO_MEM = -5,
    GRABBY_ERR_STATE = -6,
    GRABBY_ERR_I2C = -7,
} grabby_error_t;

typedef enum {
    GRABBY_INPUT_COMPOSITE = 0,
    GRABBY_INPUT_SVIDEO = 1,
} grabby_input_t;

typedef enum {
    GRABBY_NORM_PAL = 0,   // 625 lines, 50 Hz, 720x576
    GRABBY_NORM_NTSC = 1,  // 525 lines, 60 Hz, 720x480
} grabby_norm_t;

typedef enum {
    GRABBY_CTRL_BRIGHTNESS = 0,  // 0..255, default 128
    GRABBY_CTRL_CONTRAST = 1,    // 0..127, default 71
    GRABBY_CTRL_SATURATION = 2,  // 0..127, default 64
    GRABBY_CTRL_HUE = 3,         // -128..127, default 0
    GRABBY_CTRL_SHARPNESS = 4,   // 0..15, default 1
} grabby_control_t;

typedef struct {
    bool signal_locked;   // horizontal/vertical PLL locked to a source
    bool is_60hz;         // detected field rate (NTSC family when true)
    bool interlaced;
} grabby_status_t;

// Called on the driver's USB thread for every complete frame.
// `yuyv` is packed 4:2:2 (Y0 U Y1 V), `stride` bytes per line; the buffer is
// only valid for the duration of the call.
typedef void (*grabby_frame_cb)(void *ctx, const uint8_t *yuyv, int width,
                                int height, int stride, uint64_t timestamp_ns);

int grabby_open(grabby_t **out);
void grabby_close(grabby_t *g);

int grabby_set_input(grabby_t *g, grabby_input_t input);
int grabby_set_norm(grabby_t *g, grabby_norm_t norm);
grabby_norm_t grabby_get_norm(grabby_t *g);
int grabby_set_control(grabby_t *g, grabby_control_t ctrl, int value);
int grabby_get_status(grabby_t *g, grabby_status_t *status);

int grabby_start(grabby_t *g, grabby_frame_cb cb, void *ctx);
int grabby_stop(grabby_t *g);
bool grabby_is_streaming(grabby_t *g);

// Returns 1 if the snapshot button was pressed since the last call, 0 if
// not, negative on error. Poll every ~100 ms.
int grabby_poll_button(grabby_t *g);

// Counters for diagnostics.
typedef struct {
    uint64_t frames;
    uint64_t dropped_packets;
    uint64_t short_fields;
} grabby_stats_t;
void grabby_get_stats(grabby_t *g, grabby_stats_t *stats);

const char *grabby_strerror(int err);

// --- Frame helpers ----------------------------------------------------------

typedef enum {
    GRABBY_DEINTERLACE_NONE = 0,   // woven fields, full detail, combing on motion
    GRABBY_DEINTERLACE_BLEND = 1,  // average adjacent lines, no combing, slight blur
    GRABBY_DEINTERLACE_BOB = 2,    // top field only, missing lines interpolated
} grabby_deinterlace_t;

// Copies a packed YUYV frame, optionally deinterlacing it on the way.
void grabby_copy_frame(const uint8_t *src, int src_stride, uint8_t *dst, int dst_stride,
                       int width, int height, grabby_deinterlace_t mode);

#ifdef __cplusplus
}
#endif

#endif
