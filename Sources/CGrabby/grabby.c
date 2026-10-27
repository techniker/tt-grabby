// TerraTec Grabby user-space driver. See grabby.h.
//
// Register values and sequences follow the Linux em28xx and saa7115 drivers,
// which are the only public documentation for this hardware.

#include "grabby.h"

#include <libusb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// --- EM28xx registers -------------------------------------------------------

#define EM28XX_R05_I2C_STATUS 0x05
#define EM28XX_R06_I2C_CLK 0x06
#define EM28XX_R08_GPIO 0x08
#define EM28XX_R0A_CHIPID 0x0a
#define EM28XX_R0C_USBSUSP 0x0c
#define EM28XX_R0E_AUDIOSRC 0x0e
#define EM28XX_R0F_XCLK 0x0f
#define EM28XX_R10_VINMODE 0x10
#define EM28XX_R11_VINCTRL 0x11
#define EM28XX_R12_VINENABLE 0x12
#define EM28XX_R14_GAMMA 0x14  // 0x14..0x1a: gamma, RGB gains and offsets
#define EM28XX_R20_YGAIN 0x20  // 0x20..0x25: Y gain/offset, UV gain, U/V offset, sharpness
#define EM28XX_R1B_OFLOW 0x1b
#define EM28XX_R1C_HSTART 0x1c
#define EM28XX_R1D_VSTART 0x1d
#define EM28XX_R1E_CWIDTH 0x1e
#define EM28XX_R1F_CHEIGHT 0x1f
#define EM28XX_R26_COMPR 0x26
#define EM28XX_R27_OUTFMT 0x27
#define EM28XX_R28_XMIN 0x28
#define EM28XX_R29_XMAX 0x29
#define EM28XX_R2A_YMIN 0x2a
#define EM28XX_R2B_YMAX 0x2b
#define EM28XX_R30_HSCALELOW 0x30
#define EM28XX_R32_VSCALELOW 0x32
#define EM28XX_R40_AC97LSB 0x40
#define EM28XX_R42_AC97ADDR 0x42
#define EM28XX_R43_AC97BUSY 0x43
#define EM28XX_R48 0x48

#define CHIP_ID_EM2860 0x22

#define EM28XX_I2C_CLK_WAIT_ENABLE 0x40
#define EM28XX_XCLK_12MHZ 0x07
#define EM28XX_XCLK_AUDIO_UNMUTE 0x80
#define EM28XX_AUDIO_SRC_LINE 0x80
#define EM28XX_USBSUSP_CAPTURE 0x10
#define EM28XX_USBSUSP_SNAPSHOT 0x20
#define EM28XX_OUTFMT_YUV422_Y0UY1V 0x14
#define EM28XX_VINMODE_YUV422_CbYCrY 0x10
#define EM28XX_VINCTRL_CCIR656_ENABLE 0x10
#define EM28XX_VINCTRL_INTERLACED 0x01

// Capture LED on the Grabby is GPIO 3, active low.
#define GRABBY_LED_GPIO 0x08

// --- SAA7113 ----------------------------------------------------------------

#define SAA7113_I2C_ADDR 0x4a  // 8-bit form, as em28xx expects in wIndex

#define SAA_R02_INPUT_CNTL_1 0x02
#define SAA_R09_LUMA_CNTL 0x09
#define SAA_R0A_BRIGHT 0x0a
#define SAA_R0B_CONTRAST 0x0b
#define SAA_R0C_SATURATION 0x0c
#define SAA_R0D_HUE 0x0d
#define SAA_R1F_STATUS 0x1f

#define SAA_STATUS_INTL 0x80
#define SAA_STATUS_HLVLN 0x40
#define SAA_STATUS_FIDT 0x20

#define SAA_MODE_COMPOSITE0 0
#define SAA_MODE_SVIDEO3 9

static const uint8_t saa7113_init[] = {
    0x01, 0x08, 0x02, 0xc2, 0x03, 0x30, 0x04, 0x00, 0x05, 0x00, 0x06, 0x89,
    0x07, 0x0d, 0x08, 0x88, 0x09, 0x01, 0x0a, 0x80, 0x0b, 0x47, 0x0c, 0x40,
    0x0d, 0x00, 0x0e, 0x01, 0x0f, 0x2a, 0x10, 0x08, 0x11, 0x0c, 0x12, 0x07,
    0x13, 0x00, 0x14, 0x00, 0x15, 0x00, 0x16, 0x00, 0x17, 0x00,
};

// --- AC97 (EMP202 codec behind the bridge) ----------------------------------

#define AC97_MASTER 0x02
#define AC97_HEADPHONE 0x04
#define AC97_MASTER_MONO 0x06
#define AC97_PHONE 0x0c
#define AC97_MIC 0x0e
#define AC97_LINE 0x10
#define AC97_CD 0x12
#define AC97_VIDEO 0x14
#define AC97_AUX 0x16
#define AC97_PCM 0x18
#define AC97_REC_SEL 0x1a
#define AC97_REC_GAIN 0x1c
#define AC97_POWERDOWN 0x26
#define AC97_EXTENDED_STATUS 0x2a
#define AC97_PCM_LR_ADC_RATE 0x32
#define AC97_VENDOR_ID1 0x7c

#define AC97_REC_SEL_VIDEO 0x02

// --- Streaming --------------------------------------------------------------

#define VIDEO_INTERFACE 0
#define VIDEO_ALT 7  // 3 x 1024 bytes per microframe
#define VIDEO_EP 0x82
#define NUM_TRANSFERS 10
#define PACKETS_PER_TRANSFER 64
#define FRAME_WIDTH 720
#define CTRL_TIMEOUT_MS 1000

struct grabby {
    libusb_context *usb;
    libusb_device_handle *dev;
    pthread_mutex_t lock;  // serializes multi-step control sequences

    grabby_norm_t norm;
    grabby_input_t input;
    bool has_ac97;
    int packet_size;

    // Streaming state, owned by the event thread while streaming.
    pthread_t thread;
    atomic_bool running;
    atomic_int active_transfers;
    struct libusb_transfer *xfers[NUM_TRANSFERS];
    grabby_frame_cb cb;
    void *cb_ctx;

    uint8_t *frame;
    int width, height, field_bytes;
    bool in_field, top_field, have_top, emitted;
    int field_pos;

    atomic_uint_fast64_t frames, dropped_packets, short_fields;
};

static bool debug_enabled(void) {
    static int cached = -1;
    if (cached < 0) cached = getenv("GRABBY_DEBUG") != NULL;
    return cached;
}

#define DBG(...)                                    \
    do {                                            \
        if (debug_enabled()) {                      \
            fprintf(stderr, "grabby: " __VA_ARGS__); \
            fputc('\n', stderr);                    \
        }                                           \
    } while (0)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int map_usb_error(int r) {
    switch (r) {
        case LIBUSB_ERROR_ACCESS: return GRABBY_ERR_ACCESS;
        case LIBUSB_ERROR_BUSY: return GRABBY_ERR_BUSY;
        case LIBUSB_ERROR_NO_DEVICE:
        case LIBUSB_ERROR_NOT_FOUND: return GRABBY_ERR_NOT_FOUND;
        case LIBUSB_ERROR_NO_MEM: return GRABBY_ERR_NO_MEM;
        default: return GRABBY_ERR_IO;
    }
}

// --- Bridge register access -------------------------------------------------

static int read_reg(grabby_t *g, uint8_t reg) {
    uint8_t v;
    int r = libusb_control_transfer(g->dev, 0xc0, 0, 0, reg, &v, 1, CTRL_TIMEOUT_MS);
    if (r != 1) return r < 0 ? map_usb_error(r) : GRABBY_ERR_IO;
    return v;
}

static int read_regs(grabby_t *g, uint8_t reg, uint8_t *buf, int len) {
    int r = libusb_control_transfer(g->dev, 0xc0, 0, 0, reg, buf, len, CTRL_TIMEOUT_MS);
    if (r != len) return r < 0 ? map_usb_error(r) : GRABBY_ERR_IO;
    return GRABBY_OK;
}

static int write_regs(grabby_t *g, uint8_t reg, const uint8_t *buf, int len) {
    int r = libusb_control_transfer(g->dev, 0x40, 0, 0, reg, (uint8_t *)buf, len,
                                    CTRL_TIMEOUT_MS);
    if (r != len) return r < 0 ? map_usb_error(r) : GRABBY_ERR_IO;
    return GRABBY_OK;
}

static int write_reg(grabby_t *g, uint8_t reg, uint8_t val) {
    return write_regs(g, reg, &val, 1);
}

static int write_reg_bits(grabby_t *g, uint8_t reg, uint8_t val, uint8_t mask) {
    int old = read_reg(g, reg);
    if (old < 0) return old;
    return write_reg(g, reg, (uint8_t)((old & ~mask) | (val & mask)));
}

// --- I2C through the bridge -------------------------------------------------

static int i2c_wait(grabby_t *g) {
    for (int i = 0; i < 40; i++) {
        int s = read_reg(g, EM28XX_R05_I2C_STATUS);
        if (s < 0) return s;
        if (s == 0x00) return GRABBY_OK;
        if (s == 0x10) return GRABBY_ERR_I2C;  // no ACK
        usleep(5000);
    }
    return GRABBY_ERR_I2C;
}

static int i2c_write(grabby_t *g, uint8_t addr, const uint8_t *buf, int len, bool stop) {
    int r = libusb_control_transfer(g->dev, 0x40, stop ? 2 : 3, 0, addr, (uint8_t *)buf,
                                    len, CTRL_TIMEOUT_MS);
    if (r != len) return r < 0 ? map_usb_error(r) : GRABBY_ERR_IO;
    return i2c_wait(g);
}

static int i2c_read(grabby_t *g, uint8_t addr, uint8_t *buf, int len) {
    int r = libusb_control_transfer(g->dev, 0xc0, 2, 0, addr, buf, len, CTRL_TIMEOUT_MS);
    if (r != len) return r < 0 ? map_usb_error(r) : GRABBY_ERR_IO;
    return i2c_wait(g);
}

static int saa_write(grabby_t *g, uint8_t reg, uint8_t val) {
    uint8_t buf[2] = {reg, val};
    return i2c_write(g, SAA7113_I2C_ADDR, buf, 2, true);
}

static int saa_read(grabby_t *g, uint8_t reg) {
    uint8_t v;
    int r = i2c_write(g, SAA7113_I2C_ADDR, &reg, 1, false);
    if (r < 0) return r;
    r = i2c_read(g, SAA7113_I2C_ADDR, &v, 1);
    if (r < 0) return r;
    return v;
}

// --- AC97 through the bridge ------------------------------------------------

static int ac97_wait(grabby_t *g) {
    for (int i = 0; i < 20; i++) {
        int s = read_reg(g, EM28XX_R43_AC97BUSY);
        if (s < 0) return s;
        if (!(s & 0x01)) return GRABBY_OK;
        usleep(5000);
    }
    return GRABBY_ERR_IO;
}

static int ac97_write(grabby_t *g, uint8_t reg, uint16_t val) {
    int r = ac97_wait(g);
    if (r < 0) return r;
    uint8_t buf[2] = {(uint8_t)(val & 0xff), (uint8_t)(val >> 8)};
    if ((r = write_regs(g, EM28XX_R40_AC97LSB, buf, 2)) < 0) return r;
    return write_reg(g, EM28XX_R42_AC97ADDR, reg);
}

static int ac97_read(grabby_t *g, uint8_t reg) {
    int r = ac97_wait(g);
    if (r < 0) return r;
    if ((r = write_reg(g, EM28XX_R42_AC97ADDR, reg | 0x80)) < 0) return r;
    if ((r = ac97_wait(g)) < 0) return r;
    uint8_t buf[2];
    if ((r = read_regs(g, EM28XX_R40_AC97LSB, buf, 2)) < 0) return r;
    return buf[0] | (buf[1] << 8);
}

// Route the AC97 "video" input (where the Grabby's RCA audio jacks are wired)
// into the ADC that feeds the USB audio interface.
static int setup_audio(grabby_t *g) {
    int r;
    if ((r = write_reg(g, EM28XX_R0F_XCLK, EM28XX_XCLK_12MHZ | EM28XX_XCLK_AUDIO_UNMUTE)) < 0)
        return r;
    usleep(10000);
    if ((r = write_reg_bits(g, EM28XX_R0E_AUDIOSRC, EM28XX_AUDIO_SRC_LINE, 0xc0)) < 0) return r;

    int vendor = ac97_read(g, AC97_VENDOR_ID1);
    g->has_ac97 = vendor > 0 && vendor != 0xffff;
    DBG("ac97 vendor id1 0x%04x", vendor);
    if (!g->has_ac97) return GRABBY_OK;

    static const uint8_t outputs[] = {AC97_MASTER, AC97_HEADPHONE, AC97_MASTER_MONO};
    for (size_t i = 0; i < sizeof outputs; i++) ac97_write(g, outputs[i], 0x8000);

    static const uint8_t inputs[] = {AC97_PHONE, AC97_MIC, AC97_LINE, AC97_CD,
                                     AC97_AUX, AC97_PCM};
    for (size_t i = 0; i < sizeof inputs; i++) ac97_write(g, inputs[i], 0x8000);
    ac97_write(g, AC97_VIDEO, 0x0808);

    ac97_write(g, AC97_POWERDOWN, 0x4200);
    ac97_write(g, AC97_EXTENDED_STATUS, 0x0031);
    ac97_write(g, AC97_PCM_LR_ADC_RATE, 0xbb80);  // 48 kHz
    ac97_write(g, AC97_REC_SEL, AC97_REC_SEL_VIDEO | (AC97_REC_SEL_VIDEO << 8));
    ac97_write(g, AC97_REC_GAIN, 0x0000);  // 0 dB, unmuted
    return GRABBY_OK;
}

// --- Video configuration ----------------------------------------------------

static int norm_height(grabby_norm_t n) { return n == GRABBY_NORM_NTSC ? 480 : 576; }

static int configure_video(grabby_t *g) {
    int r;
    int width = FRAME_WIDTH;
    int height = norm_height(g->norm);
    // The bridge captures one field at a time, so its window is half height.
    int field_h = height / 2;

    // The bridge has its own colour processing, and its power-on state is
    // garbage (UV gain 0, U offset -128), which turns every picture green or
    // red. Set it to neutral and leave picture adjustments to the decoder.
    static const uint8_t levels[] = {0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00};
    static const uint8_t yuv[] = {0x10, 0x00, 0x10, 0x00, 0x00, 0x00};
    if ((r = write_regs(g, EM28XX_R14_GAMMA, levels, sizeof levels)) < 0) return r;
    if ((r = write_regs(g, EM28XX_R20_YGAIN, yuv, sizeof yuv)) < 0) return r;

    if ((r = write_reg(g, EM28XX_R27_OUTFMT, EM28XX_OUTFMT_YUV422_Y0UY1V | 0x20)) < 0) return r;
    if ((r = write_reg(g, EM28XX_R10_VINMODE, EM28XX_VINMODE_YUV422_CbYCrY)) < 0) return r;
    if ((r = write_reg(g, EM28XX_R11_VINCTRL,
                       EM28XX_VINCTRL_CCIR656_ENABLE | EM28XX_VINCTRL_INTERLACED)) < 0)
        return r;

    uint8_t acc[4] = {1, (uint8_t)((width - 4) >> 2), 1, (uint8_t)((field_h - 4) >> 2)};
    if ((r = write_regs(g, EM28XX_R28_XMIN, acc, 4)) < 0) return r;

    uint8_t area[4] = {0, 0, (uint8_t)(width >> 2), (uint8_t)(field_h >> 2)};
    uint8_t oflow = (uint8_t)(((field_h >> 9) & 0x02) | ((width >> 10) & 0x01));
    if ((r = write_regs(g, EM28XX_R1C_HSTART, area, 4)) < 0) return r;
    if ((r = write_reg(g, EM28XX_R1B_OFLOW, oflow)) < 0) return r;

    uint8_t zero[2] = {0, 0};
    if ((r = write_regs(g, EM28XX_R30_HSCALELOW, zero, 2)) < 0) return r;
    if ((r = write_regs(g, EM28XX_R32_VSCALELOW, zero, 2)) < 0) return r;
    return write_reg(g, EM28XX_R26_COMPR, 0x00);
}

static int apply_input(grabby_t *g) {
    int mode = g->input == GRABBY_INPUT_SVIDEO ? SAA_MODE_SVIDEO3 : SAA_MODE_COMPOSITE0;
    int r02 = saa_read(g, SAA_R02_INPUT_CNTL_1);
    if (r02 < 0) return r02;
    int r = saa_write(g, SAA_R02_INPUT_CNTL_1, (uint8_t)((r02 & 0xf0) | mode));
    if (r < 0) return r;
    // Bypass the chroma trap for S-Video, where luma and chroma arrive separately.
    int r09 = saa_read(g, SAA_R09_LUMA_CNTL);
    if (r09 < 0) return r09;
    return saa_write(g, SAA_R09_LUMA_CNTL,
                     (uint8_t)((r09 & 0x7f) | (g->input == GRABBY_INPUT_SVIDEO ? 0x80 : 0)));
}

static int set_led(grabby_t *g, bool on) {
    return write_reg_bits(g, EM28XX_R08_GPIO, on ? 0 : GRABBY_LED_GPIO, GRABBY_LED_GPIO);
}

// --- Public API: lifecycle --------------------------------------------------

int grabby_open(grabby_t **out) {
    *out = NULL;
    grabby_t *g = calloc(1, sizeof *g);
    if (!g) return GRABBY_ERR_NO_MEM;
    pthread_mutex_init(&g->lock, NULL);
    g->norm = GRABBY_NORM_PAL;
    g->input = GRABBY_INPUT_COMPOSITE;

    int r = libusb_init_context(&g->usb, NULL, 0);
    if (r < 0) {
        free(g);
        return map_usb_error(r);
    }
    g->dev = libusb_open_device_with_vid_pid(g->usb, GRABBY_VID, GRABBY_PID);
    if (!g->dev) {
        grabby_close(g);
        return GRABBY_ERR_NOT_FOUND;
    }
    if ((r = libusb_claim_interface(g->dev, VIDEO_INTERFACE)) < 0) {
        grabby_close(g);
        return map_usb_error(r);
    }
    libusb_set_interface_alt_setting(g->dev, VIDEO_INTERFACE, 0);

    struct libusb_config_descriptor *cfg;
    if (libusb_get_active_config_descriptor(libusb_get_device(g->dev), &cfg) == 0) {
        const struct libusb_interface *itf = &cfg->interface[VIDEO_INTERFACE];
        if (itf->num_altsetting > VIDEO_ALT) {
            const struct libusb_interface_descriptor *alt = &itf->altsetting[VIDEO_ALT];
            for (int e = 0; e < alt->bNumEndpoints; e++)
                if (alt->endpoint[e].bEndpointAddress == VIDEO_EP) {
                    int mps = alt->endpoint[e].wMaxPacketSize;
                    g->packet_size = (mps & 0x7ff) * (((mps >> 11) & 3) + 1);
                }
        }
        libusb_free_config_descriptor(cfg);
    }
    if (g->packet_size == 0) g->packet_size = 3 * 1024;

    int chip = read_reg(g, EM28XX_R0A_CHIPID);
    DBG("chip id 0x%02x", chip);
    if (chip < 0) {
        grabby_close(g);
        return chip;
    }

    if ((r = write_reg(g, EM28XX_R06_I2C_CLK, EM28XX_I2C_CLK_WAIT_ENABLE)) < 0 ||
        (r = write_reg(g, EM28XX_R0F_XCLK, EM28XX_XCLK_12MHZ | EM28XX_XCLK_AUDIO_UNMUTE)) < 0) {
        grabby_close(g);
        return r;
    }
    usleep(10000);

    for (size_t i = 0; i < sizeof saa7113_init; i += 2) {
        if ((r = saa_write(g, saa7113_init[i], saa7113_init[i + 1])) < 0) {
            DBG("saa7113 init failed at reg 0x%02x: %d", saa7113_init[i], r);
            grabby_close(g);
            return r;
        }
    }
    if ((r = apply_input(g)) < 0 || (r = setup_audio(g)) < 0 ||
        (r = configure_video(g)) < 0) {
        grabby_close(g);
        return r;
    }
    set_led(g, false);

    // Start in whatever norm the decoder has locked onto.
    grabby_status_t st;
    usleep(200000);
    if (grabby_get_status(g, &st) == GRABBY_OK && st.signal_locked)
        grabby_set_norm(g, st.is_60hz ? GRABBY_NORM_NTSC : GRABBY_NORM_PAL);

    *out = g;
    return GRABBY_OK;
}

void grabby_close(grabby_t *g) {
    if (!g) return;
    grabby_stop(g);
    if (g->dev) {
        set_led(g, false);
        libusb_release_interface(g->dev, VIDEO_INTERFACE);
        libusb_close(g->dev);
    }
    if (g->usb) libusb_exit(g->usb);
    pthread_mutex_destroy(&g->lock);
    free(g->frame);
    free(g);
}

// --- Public API: controls ---------------------------------------------------

int grabby_set_input(grabby_t *g, grabby_input_t input) {
    pthread_mutex_lock(&g->lock);
    g->input = input;
    int r = apply_input(g);
    pthread_mutex_unlock(&g->lock);
    return r;
}

int grabby_set_norm(grabby_t *g, grabby_norm_t norm) {
    if (atomic_load(&g->running)) return GRABBY_ERR_STATE;
    pthread_mutex_lock(&g->lock);
    g->norm = norm;
    int r = configure_video(g);
    pthread_mutex_unlock(&g->lock);
    return r;
}

grabby_norm_t grabby_get_norm(grabby_t *g) { return g->norm; }

static int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

int grabby_set_control(grabby_t *g, grabby_control_t ctrl, int value) {
    int r;
    pthread_mutex_lock(&g->lock);
    switch (ctrl) {
        case GRABBY_CTRL_BRIGHTNESS:
            r = saa_write(g, SAA_R0A_BRIGHT, (uint8_t)clamp(value, 0, 255));
            break;
        case GRABBY_CTRL_CONTRAST:
            r = saa_write(g, SAA_R0B_CONTRAST, (uint8_t)clamp(value, 0, 127));
            break;
        case GRABBY_CTRL_SATURATION:
            r = saa_write(g, SAA_R0C_SATURATION, (uint8_t)clamp(value, 0, 127));
            break;
        case GRABBY_CTRL_HUE:
            r = saa_write(g, SAA_R0D_HUE, (uint8_t)(int8_t)clamp(value, -128, 127));
            break;
        case GRABBY_CTRL_SHARPNESS:
            r = saa_read(g, SAA_R09_LUMA_CNTL);
            if (r >= 0)
                r = saa_write(g, SAA_R09_LUMA_CNTL,
                              (uint8_t)((r & 0xf0) | clamp(value, 0, 15)));
            break;
        default:
            r = GRABBY_ERR_STATE;
    }
    pthread_mutex_unlock(&g->lock);
    return r < 0 ? r : GRABBY_OK;
}

int grabby_get_status(grabby_t *g, grabby_status_t *status) {
    pthread_mutex_lock(&g->lock);
    int s = saa_read(g, SAA_R1F_STATUS);
    pthread_mutex_unlock(&g->lock);
    if (s < 0) return s;
    status->signal_locked = !(s & SAA_STATUS_HLVLN);
    status->is_60hz = (s & SAA_STATUS_FIDT) != 0;
    status->interlaced = (s & SAA_STATUS_INTL) != 0;
    return GRABBY_OK;
}

int grabby_poll_button(grabby_t *g) {
    pthread_mutex_lock(&g->lock);
    int v = read_reg(g, EM28XX_R0C_USBSUSP);
    int pressed = 0;
    if (v >= 0 && (v & EM28XX_USBSUSP_SNAPSHOT)) {
        pressed = 1;
        write_reg(g, EM28XX_R0C_USBSUSP, (uint8_t)(v & ~EM28XX_USBSUSP_SNAPSHOT));
    }
    pthread_mutex_unlock(&g->lock);
    return v < 0 ? v : pressed;
}

void grabby_get_stats(grabby_t *g, grabby_stats_t *stats) {
    stats->frames = atomic_load(&g->frames);
    stats->dropped_packets = atomic_load(&g->dropped_packets);
    stats->short_fields = atomic_load(&g->short_fields);
}

// --- Streaming --------------------------------------------------------------

static void emit_frame(grabby_t *g) {
    atomic_fetch_add(&g->frames, 1);
    if (g->cb) g->cb(g->cb_ctx, g->frame, g->width, g->height, g->width * 2, now_ns());
}

static void end_field(grabby_t *g) {
    if (!g->in_field) return;
    if (g->field_pos < g->field_bytes) atomic_fetch_add(&g->short_fields, 1);
    if (!g->top_field && g->have_top && !g->emitted) emit_frame(g);
    g->in_field = false;
}

static void copy_field_data(grabby_t *g, const uint8_t *p, int len) {
    int line_bytes = g->width * 2;
    while (len > 0 && g->field_pos < g->field_bytes) {
        int line = g->field_pos / line_bytes;
        int col = g->field_pos % line_bytes;
        int n = line_bytes - col;
        if (n > len) n = len;
        int row = line * 2 + (g->top_field ? 0 : 1);
        memcpy(g->frame + row * line_bytes + col, p, n);
        g->field_pos += n;
        p += n;
        len -= n;
    }
    if (g->field_pos >= g->field_bytes && !g->top_field && g->have_top && !g->emitted) {
        emit_frame(g);
        g->emitted = true;
    }
}

static void process_packet(grabby_t *g, const uint8_t *p, int len) {
    if (len >= 4) {
        if (p[0] == 0x22 && p[1] == 0x5a) {
            // Start of a field; bit 0 of the third byte is the field parity.
            static int logged;
            if (logged < 12 && debug_enabled()) {
                logged++;
                DBG("field header %02x %02x %02x %02x, previous field %d/%d bytes", p[0], p[1],
                    p[2], p[3], g->field_pos, g->field_bytes);
            }
            end_field(g);
            g->top_field = !(p[2] & 1);
            g->in_field = true;
            g->field_pos = 0;
            if (g->top_field) {
                g->have_top = true;
                g->emitted = false;
            }
            p += 4;
            len -= 4;
        } else if (p[0] == 0x88 && p[1] == 0x88 && p[2] == 0x88 && p[3] == 0x88) {
            p += 4;
            len -= 4;
        }
    }
    if (g->in_field && len > 0) copy_field_data(g, p, len);
}

static void LIBUSB_CALL iso_callback(struct libusb_transfer *xfer) {
    grabby_t *g = xfer->user_data;
    if (xfer->status == LIBUSB_TRANSFER_COMPLETED) {
        for (int i = 0; i < xfer->num_iso_packets; i++) {
            struct libusb_iso_packet_descriptor *d = &xfer->iso_packet_desc[i];
            if (d->status != LIBUSB_TRANSFER_COMPLETED) {
                atomic_fetch_add(&g->dropped_packets, 1);
                continue;
            }
            if (d->actual_length > 0)
                process_packet(g, libusb_get_iso_packet_buffer(xfer, i), (int)d->actual_length);
        }
    }
    if (atomic_load(&g->running) && xfer->status != LIBUSB_TRANSFER_NO_DEVICE &&
        libusb_submit_transfer(xfer) == 0)
        return;
    atomic_fetch_sub(&g->active_transfers, 1);
}

static void *event_thread(void *arg) {
    grabby_t *g = arg;
    pthread_setname_np("grabby.usb");
    while (atomic_load(&g->active_transfers) > 0) {
        struct timeval tv = {0, 100000};
        libusb_handle_events_timeout_completed(g->usb, &tv, NULL);
    }
    return NULL;
}

static void free_transfers(grabby_t *g) {
    for (int i = 0; i < NUM_TRANSFERS; i++) {
        if (!g->xfers[i]) continue;
        free(g->xfers[i]->buffer);
        libusb_free_transfer(g->xfers[i]);
        g->xfers[i] = NULL;
    }
}

int grabby_start(grabby_t *g, grabby_frame_cb cb, void *ctx) {
    if (atomic_load(&g->running)) return GRABBY_ERR_STATE;
    int r;

    g->cb = cb;
    g->cb_ctx = ctx;
    g->width = FRAME_WIDTH;
    g->height = norm_height(g->norm);
    g->field_bytes = g->width * 2 * (g->height / 2);
    free(g->frame);
    g->frame = calloc(1, (size_t)g->width * 2 * g->height);
    if (!g->frame) return GRABBY_ERR_NO_MEM;
    g->in_field = g->have_top = g->emitted = false;
    atomic_store(&g->frames, 0);
    atomic_store(&g->dropped_packets, 0);
    atomic_store(&g->short_fields, 0);

    pthread_mutex_lock(&g->lock);
    r = libusb_set_interface_alt_setting(g->dev, VIDEO_INTERFACE, VIDEO_ALT);
    if (r < 0) r = map_usb_error(r);
    if (r == 0) r = write_reg_bits(g, EM28XX_R0C_USBSUSP, EM28XX_USBSUSP_CAPTURE,
                                   EM28XX_USBSUSP_CAPTURE);
    if (r == 0) r = write_reg(g, EM28XX_R48, 0x00);
    if (r == 0) r = write_reg(g, EM28XX_R12_VINENABLE, 0x67);
    pthread_mutex_unlock(&g->lock);
    if (r < 0) return r;
    usleep(10000);

    int len = g->packet_size * PACKETS_PER_TRANSFER;
    for (int i = 0; i < NUM_TRANSFERS; i++) {
        struct libusb_transfer *x = libusb_alloc_transfer(PACKETS_PER_TRANSFER);
        uint8_t *buf = malloc(len);
        if (!x || !buf) {
            free(buf);
            if (x) libusb_free_transfer(x);
            free_transfers(g);
            return GRABBY_ERR_NO_MEM;
        }
        libusb_fill_iso_transfer(x, g->dev, VIDEO_EP, buf, len, PACKETS_PER_TRANSFER,
                                 iso_callback, g, CTRL_TIMEOUT_MS);
        libusb_set_iso_packet_lengths(x, g->packet_size);
        g->xfers[i] = x;
    }

    atomic_store(&g->running, true);
    atomic_store(&g->active_transfers, 0);
    for (int i = 0; i < NUM_TRANSFERS; i++) {
        if ((r = libusb_submit_transfer(g->xfers[i])) < 0) {
            DBG("submit %d failed: %s", i, libusb_error_name(r));
            break;
        }
        atomic_fetch_add(&g->active_transfers, 1);
    }
    if (atomic_load(&g->active_transfers) == 0) {
        atomic_store(&g->running, false);
        free_transfers(g);
        return map_usb_error(r);
    }
    pthread_create(&g->thread, NULL, event_thread, g);
    set_led(g, true);
    return GRABBY_OK;
}

int grabby_stop(grabby_t *g) {
    if (!atomic_exchange(&g->running, false)) return GRABBY_OK;
    for (int i = 0; i < NUM_TRANSFERS; i++)
        if (g->xfers[i]) libusb_cancel_transfer(g->xfers[i]);
    pthread_join(g->thread, NULL);
    free_transfers(g);

    pthread_mutex_lock(&g->lock);
    write_reg(g, EM28XX_R12_VINENABLE, 0x27);
    write_reg_bits(g, EM28XX_R0C_USBSUSP, 0, EM28XX_USBSUSP_CAPTURE);
    libusb_set_interface_alt_setting(g->dev, VIDEO_INTERFACE, 0);
    set_led(g, false);
    pthread_mutex_unlock(&g->lock);
    return GRABBY_OK;
}

bool grabby_is_streaming(grabby_t *g) { return atomic_load(&g->running); }

const char *grabby_strerror(int err) {
    switch (err) {
        case GRABBY_OK: return "OK";
        case GRABBY_ERR_NOT_FOUND: return "TerraTec Grabby not found";
        case GRABBY_ERR_ACCESS: return "Access to the USB device was denied";
        case GRABBY_ERR_BUSY: return "The device is in use by another application";
        case GRABBY_ERR_IO: return "USB communication error";
        case GRABBY_ERR_NO_MEM: return "Out of memory";
        case GRABBY_ERR_STATE: return "Operation not allowed in the current state";
        case GRABBY_ERR_I2C: return "Video decoder did not respond";
        default: return "Unknown error";
    }
}
