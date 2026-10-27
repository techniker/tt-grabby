// Command-line hardware check: opens the Grabby, reports decoder status,
// streams for a few seconds and writes the last frame as raw YUYV.
//
//   grabby-probe [seconds] [output.yuv] [composite|svideo]

#include <grabby.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    FILE *out;
    const char *path;
    int width, height;
} probe_t;

static void on_frame(void *ctx, const uint8_t *yuyv, int width, int height, int stride,
                     uint64_t ts) {
    (void)ts;
    probe_t *p = ctx;
    p->width = width;
    p->height = height;
    FILE *f = fopen(p->path, "wb");
    if (!f) return;
    for (int y = 0; y < height; y++) fwrite(yuyv + y * stride, 1, (size_t)width * 2, f);
    fclose(f);
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 3;
    probe_t p = {.path = argc > 2 ? argv[2] : "frame.yuv"};
    grabby_input_t input =
        argc > 3 && strcmp(argv[3], "svideo") == 0 ? GRABBY_INPUT_SVIDEO : GRABBY_INPUT_COMPOSITE;

    grabby_t *g;
    int r = grabby_open(&g);
    if (r < 0) {
        fprintf(stderr, "open: %s\n", grabby_strerror(r));
        return 1;
    }
    grabby_set_input(g, input);
    usleep(300000);

    grabby_status_t st;
    if (grabby_get_status(g, &st) == 0)
        printf("signal %s, %s, %s\n", st.signal_locked ? "locked" : "none",
               st.is_60hz ? "60 Hz" : "50 Hz", st.interlaced ? "interlaced" : "progressive");
    printf("norm %s\n", grabby_get_norm(g) == GRABBY_NORM_NTSC ? "NTSC" : "PAL");

    if ((r = grabby_start(g, on_frame, &p)) < 0) {
        fprintf(stderr, "start: %s\n", grabby_strerror(r));
        grabby_close(g);
        return 1;
    }
    for (int i = 0; i < seconds * 10; i++) {
        usleep(100000);
        if (grabby_poll_button(g) == 1) printf("snapshot button pressed\n");
    }
    grabby_stop(g);

    grabby_stats_t s;
    grabby_get_stats(g, &s);
    printf("frames %llu (%.1f fps), dropped packets %llu, short fields %llu\n", s.frames,
           (double)s.frames / seconds, s.dropped_packets, s.short_fields);
    if (s.frames) printf("wrote %dx%d yuyv422 to %s\n", p.width, p.height, p.path);
    grabby_close(g);
    return 0;
}
