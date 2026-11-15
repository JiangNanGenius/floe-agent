// SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0+
// fvm_qual — Floe virtio-media V4L2 qualification tool.
//
// REWRITE  after primary review found the original
// client unusable: it hardcoded multi-planar queue types although the Floe
// device exposes SINGLE-planar CAPTURE/OUTPUT, referenced
// pix_mp.plane_fmt[0].pixelformat (does not exist), never STREAMONed the
// coded OUTPUT queue, fed arbitrary huge ES chunks instead of complete
// access units, wrote full allocated buffers instead of bytesused, had no
// reliable EOS/timeout, queued bytesused=0, recycled on stale errno and
// could hang forever.
//
// This version speaks plain single-planar V4L2 (stock UAPI only):
//   enum <dev>
//   m2m-decode <dev> <es> [out-prefix|-] [-c H264|HEVC] [-t ms]
//       decode an Annex-B H264/HEVC elementary stream into NV12 frames.
//       Input must be split into complete ACCESS UNITS, either:
//         (a) FVMP packet manifest: magic "FVMP", u32 version=1, u32 count,
//             then count x (u32 len, payload bytes) — one entry per AU;
//             build with e.g. `ffmpeg -i in.mp4 -c copy -bsf:v <codec>_metadata=aud=1`
//             then a AUD splitter; or
//         (b) raw Annex-B with AUD NALs: the tool splits on AUD boundaries
//             (H264 nal type 9, HEVC nal type 35); any SPS/PPS before the
//             first AUD rides with the first AU (in-band parameter sets).
//       Frames are written as <prefix><sequence>.nv12 with EXACTLY
//       bytesused bytes (never the full allocation).
//   m2m-encode <dev> <CODEC> <w> <h> <frames> <out.es> [-t ms]
//       encode synthetic NV12 frames into an Annex-B elementary stream.
//       Written chunks carry EXACTLY the produced bytesused bytes.
//
// Guarantees: S_FMT on both queues, STREAMON on both queues, inputs are
// recycled only by real DQBUF, writes are checked, every buffer is unmapped,
// both queues get STREAMOFF, poll/timeout bounds every wait, and the final
// summary prints exact produced byte/frame counts. EOS is signalled with
// VIDIOC_{DECODER,ENCODER}_CMD STOP and the drain loop ends on EAGAIN.
//
// This tool is a qualification complement; the primary also runs unmodified
// Linux FFmpeg V4L2M2M tests. A pass here is not an application-level proof.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define REQ_BUF_COUNT 8
#define DEFAULT_TIMEOUT_MS 5000

static int g_timeout_ms = DEFAULT_TIMEOUT_MS;

static void die(const char *what) { perror(what); exit(2); }

static int xioctl(int fd, unsigned long req, void *arg, const char *name)
{
    int r;
    do { r = ioctl(fd, req, arg); } while (r < 0 && errno == EINTR);
    if (r < 0) fprintf(stderr, "%s: %s\n", name, strerror(errno));
    return r;
}

/* bounded wait; returns 1 ready, 0 timeout, -1 error */
static int wait_fd(int fd, short events, const char *what)
{
    struct pollfd p = { .fd = fd, .events = events };
    int r;
    do { r = poll(&p, 1, g_timeout_ms); } while (r < 0 && errno == EINTR);
    if (r < 0) { fprintf(stderr, "poll(%s): %s\n", what, strerror(errno)); return -1; }
    if (r == 0) { fprintf(stderr, "poll(%s): timeout after %d ms\n", what, g_timeout_ms); return 0; }
    return 1;
}

static const char *fcc2s(unsigned int f)
{
    static char b[3][8]; static int i; i = (i + 1) % 3;
    b[i][0] = f & 0xff; b[i][1] = (f >> 8) & 0xff;
    b[i][2] = (f >> 16) & 0xff; b[i][3] = (f >> 24) & 0xff; b[i][4] = 0;
    return b[i];
}

static unsigned int s2fcc(const char *s)
{
    return (unsigned int)s[0] | ((unsigned int)s[1] << 8) |
           ((unsigned int)s[2] << 16) | ((unsigned int)s[3] << 24);
}

/* ---------------- enum ---------------- */

static void do_enum(const char *dev)
{
    int fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) die(dev);
    struct v4l2_capability cap;
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap, "QUERYCAP") == 0)
        printf("cap driver=%s card=%s bus=%s version=%u caps=0x%x device_caps=0x%x\n",
               cap.driver, cap.card, cap.bus_info, cap.version,
               cap.capabilities, cap.device_caps);
    static const struct { const char *label; unsigned int type; } tq[] = {
        {"VIDEO_CAPTURE", V4L2_BUF_TYPE_VIDEO_CAPTURE},
        {"VIDEO_OUTPUT", V4L2_BUF_TYPE_VIDEO_OUTPUT},
        {"VIDEO_CAPTURE_MPLANE", V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE},
        {"VIDEO_OUTPUT_MPLANE", V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE},
        {"META_CAPTURE", V4L2_BUF_TYPE_META_CAPTURE},
    };
    for (unsigned t = 0; t < sizeof(tq) / sizeof(tq[0]); t++) {
        struct v4l2_fmtdesc fm = {.type = tq[t].type};
        while (ioctl(fd, VIDIOC_ENUM_FMT, &fm) == 0) {
            printf("fmt type=%s pixelformat=%s flags=0x%x desc=%s\n",
                   tq[t].label, fcc2s(fm.pixelformat), fm.flags, fm.description);
            struct v4l2_frmsizeenum fs = {.pixel_format = fm.pixelformat};
            if (ioctl(fd, VIDIOC_ENUM_FRAMESIZES, &fs) == 0)
                printf("  framesize type=%d min=%ux%u max=%ux%u step=%u\n", fs.type,
                       fs.stepwise.min_width, fs.stepwise.min_height,
                       fs.stepwise.max_width, fs.stepwise.max_height,
                       fs.stepwise.step_width);
            fm.index++;
        }
    }
    close(fd);
}

/* ---------------- single-planar MMAP buffer helpers ---------------- */

struct mbuf { unsigned char *addr; size_t len; };

static int reqbufs_mmap(int fd, unsigned int type, unsigned int *count)
{
    struct v4l2_requestbuffers r = {.type = type, .memory = V4L2_MEMORY_MMAP,
                                    .count = *count};
    if (xioctl(fd, VIDIOC_REQBUFS, &r, "REQBUFS") < 0) return -1;
    *count = r.count;
    return 0;
}

static int querybuf_mmap(int fd, unsigned int type, unsigned int index, struct mbuf *out)
{
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = type; b.memory = V4L2_MEMORY_MMAP; b.index = index;
    if (xioctl(fd, VIDIOC_QUERYBUF, &b, "QUERYBUF") < 0) return -1;
    void *m = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
    if (m == MAP_FAILED) die("mmap buffer");
    out->addr = m; out->len = b.length;
    return 0;
}

static int qbuf(int fd, unsigned int type, unsigned int index, unsigned int bytesused)
{
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = type; b.memory = V4L2_MEMORY_MMAP; b.index = index;
    b.bytesused = bytesused;
    return xioctl(fd, VIDIOC_QBUF, &b, "QBUF");
}

static int dqbuf(int fd, unsigned int type, struct v4l2_buffer *b)
{
    memset(b, 0, sizeof(*b));
    b->type = type; b->memory = V4L2_MEMORY_MMAP;
    return xioctl(fd, VIDIOC_DQBUF, b, "DQBUF");
}

static void unmap_all(struct mbuf *bufs, unsigned int n)
{
    for (unsigned i = 0; i < n; i++)
        if (bufs[i].addr && bufs[i].addr != MAP_FAILED)
            if (munmap(bufs[i].addr, bufs[i].len) < 0)
                perror("munmap");
}

static int streamoff(int fd, unsigned int type, const char *what)
{
    if (xioctl(fd, VIDIOC_STREAMOFF, &type, what) < 0) return -1;
    return 0;
}

/* ---------------- access unit loading ---------------- */

struct au { unsigned char *data; uint32_t len; };

struct au_list {
    struct au *v;
    uint32_t n, cap;
    unsigned char *blob; /* owns all payloads */
};

static int au_push(struct au_list *l, const unsigned char *p, uint32_t len)
{
    if (l->n == l->cap) {
        uint32_t nc = l->cap ? l->cap * 2 : 64;
        struct au *nv = realloc(l->v, nc * sizeof(*nv));
        if (!nv) return -1;
        l->v = nv; l->cap = nc;
    }
    l->v[l->n].data = (unsigned char *)p; /* into blob */
    l->v[l->n].len = len;
    l->n++;
    return 0;
}

/* FVMP manifest: "FVMP" u32(version=1) u32(count) count x (u32 len + bytes) */
static int load_fvmp(struct au_list *l, const unsigned char *d, size_t n)
{
    uint32_t version, count;
    memcpy(&version, d + 4, 4);
    memcpy(&count, d + 8, 4);
    if (version != 1) { fprintf(stderr, "fvmp: unsupported version %u\n", version); return -1; }
    size_t pos = 12;
    l->blob = malloc(n);
    if (!l->blob) return -1;
    memcpy(l->blob, d, n);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t len;
        if (pos + 4 > n) { fprintf(stderr, "fvmp: truncated header\n"); return -1; }
        memcpy(&len, l->blob + pos, 4); pos += 4;
        if (pos + len > n) { fprintf(stderr, "fvmp: truncated payload\n"); return -1; }
        if (au_push(l, l->blob + pos, len)) return -1;
        pos += len;
    }
    return 0;
}

static size_t scan_start_code(const unsigned char *d, size_t n, size_t from)
{
    /* find 00 00 01 or 00 00 00 01 */
    for (size_t i = from + 2; i < n; i++) {
        if (d[i] == 1 && d[i-1] == 0 && d[i-2] == 0)
            return i - 2 - (i >= 3 && d[i-3] == 0 ? 1 : 0);
    }
    return n;
}

static int nal_is_aud(const unsigned char *d, size_t n, size_t sc, unsigned int codec)
{
    /* first byte after the 3/4-byte start code at sc */
    size_t h = sc + (d[sc+2] == 0 ? 4 : 3);
    if (h >= n) return 0;
    if (codec == V4L2_PIX_FMT_H264) return (d[h] & 0x1f) == 9;
    return ((d[h] >> 1) & 0x3f) == 35; /* HEVC */
}

/* Annex-B split into access units on AUD boundaries.
 * Anything before the first AUD (e.g. SPS/PPS) rides with AU 0. */
static int load_annexb(struct au_list *l, const unsigned char *d, size_t n, unsigned int codec)
{
    l->blob = malloc(n ? n : 1);
    if (!l->blob) return -1;
    memcpy(l->blob, d, n);
    d = l->blob;
    size_t au_start = 0, pos = 0;
    int auds = 0;
    while (pos < n) {
        size_t sc = scan_start_code(d, n, pos);
        if (sc >= n) break;
        if (nal_is_aud(d, n, sc, codec)) {
            if (auds > 0) {
                if (au_push(l, d + au_start, (uint32_t)(sc - au_start))) return -1;
            }
            au_start = sc;
            auds++;
        }
        pos = sc + 3;
    }
    if (auds == 0) {
        fprintf(stderr, "no AUD NALs found: provide an FVMP manifest or add AUD "
                        "with `ffmpeg -i in.mp4 -c copy -bsf:v h264_metadata=aud=1`\n");
        return -1;
    }
    if (n > au_start && au_push(l, d + au_start, (uint32_t)(n - au_start))) return -1;
    return 0;
}

static int load_aus(struct au_list *l, const char *path, unsigned int codec)
{
    FILE *f = fopen(path, "rb");
    if (!f) die(path);
    if (fseek(f, 0, SEEK_END) || ftell(f) < 0) { fclose(f); return -1; }
    long sz = ftell(f);
    rewind(f);
    unsigned char *d = malloc(sz ? sz : 1);
    if (!d) { fclose(f); return -1; }
    if (sz && fread(d, 1, sz, f) != (size_t)sz) { fclose(f); free(d); return -1; }
    fclose(f);
    int r;
    if (sz >= 8 && memcmp(d, "FVMP", 4) == 0) r = load_fvmp(l, d, sz);
    else r = load_annexb(l, d, sz, codec);
    free(d);
    if (r == 0) printf("loaded %u access units from %s\n", l->n, path);
    return r;
}

/* ---------------- m2m decode ---------------- */

static void do_m2m_decode(const char *dev, const char *es_path, const char *out_prefix,
                          unsigned int codec)
{
    struct au_list aus = {0};
    if (load_aus(&aus, es_path, codec)) exit(2);
    if (!aus.n) { fprintf(stderr, "empty access unit list\n"); exit(2); }

    int fd = open(dev, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) die(dev);

    /* S_FMT coded OUTPUT (width/height 0: the device accepts initial 0x0 and
     * fills the real coded size after the header is parsed). */
    struct v4l2_format f;
    memset(&f, 0, sizeof(f));
    f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    f.fmt.pix.pixelformat = codec;
    f.fmt.pix.width = 0; f.fmt.pix.height = 0;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    f.fmt.pix.sizeimage = 1024 * 1024;
    if (xioctl(fd, VIDIOC_S_FMT, &f, "S_FMT OUTPUT (coded)") < 0) exit(3);

    /* S_FMT CAPTURE NV12 */
    memset(&f, 0, sizeof(f));
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
    f.fmt.pix.width = 0; f.fmt.pix.height = 0;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &f, "S_FMT CAPTURE (NV12)") < 0) exit(3);

    struct v4l2_event_subscription sub = {.type = V4L2_EVENT_EOS};
    ioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub); /* best effort */

    unsigned int n_src = REQ_BUF_COUNT, n_dst = REQ_BUF_COUNT;
    if (reqbufs_mmap(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &n_src) < 0) exit(3);
    if (reqbufs_mmap(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &n_dst) < 0) exit(3);
    printf("reqbufs src=%u dst=%u\n", n_src, n_dst);

    struct mbuf srcbuf[REQ_BUF_COUNT], dstbuf[REQ_BUF_COUNT];
    memset(srcbuf, 0, sizeof(srcbuf)); memset(dstbuf, 0, sizeof(dstbuf));
    for (unsigned i = 0; i < n_src; i++)
        if (querybuf_mmap(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i, &srcbuf[i]) < 0) exit(3);
    for (unsigned i = 0; i < n_dst; i++)
        if (querybuf_mmap(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, &dstbuf[i]) < 0) exit(3);

    for (unsigned i = 0; i < n_dst; i++)
        if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, 0) < 0) exit(3);

    unsigned int cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    unsigned int out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    if (xioctl(fd, VIDIOC_STREAMON, &cap_type, "STREAMON CAPTURE") < 0) exit(3);
    if (xioctl(fd, VIDIOC_STREAMON, &out_type, "STREAMON OUTPUT") < 0) exit(3);

    /* Feed complete access units; recycle OUTPUT only via real DQBUF.
     * Track per-buffer free/queued state so non-FIFO DQBUF order is safe. */
    uint32_t au_i = 0, out_in_driver = 0;
    uint64_t frames = 0, bytes_out = 0;
    int src_free[REQ_BUF_COUNT];
    for (unsigned i = 0; i < n_src; i++) src_free[i] = 1;
    while (au_i < aus.n) {
        if (out_in_driver == n_src) {
            int w = wait_fd(fd, POLLIN, "OUTPUT dq");
            if (w <= 0) { fprintf(stderr, "decode: no OUTPUT recycle\n"); exit(4); }
            struct v4l2_buffer b;
            if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &b) < 0) {
                if (errno != EAGAIN) { perror("DQBUF OUTPUT"); exit(3); }
                continue;
            }
            src_free[b.index] = 1;
            out_in_driver--;
        }
        unsigned idx;
        for (idx = 0; idx < n_src; idx++) if (src_free[idx]) break;
        if (idx == n_src) continue; /* raced; re-poll */
        struct au *a = &aus.v[au_i];
        if (a->len > srcbuf[idx].len) {
            fprintf(stderr, "AU %u (%u bytes) exceeds buffer %u (%zu)\n",
                    au_i, a->len, idx, srcbuf[idx].len);
            exit(3);
        }
        memcpy(srcbuf[idx].addr, a->data, a->len);
        int w = wait_fd(fd, POLLOUT, "OUTPUT q");
        if (w <= 0) { fprintf(stderr, "decode: OUTPUT not writable\n"); exit(4); }
        if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, idx, a->len) < 0) {
            if (errno == EAGAIN) continue; /* race: buffer re-queued; retry */
            exit(3);
        }
        src_free[idx] = 0;
        out_in_driver++;
        au_i++;
    }

    /* EOS: drain CAPTURE until two consecutive EAGAINs (bounded by poll). */
    struct v4l2_decoder_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.cmd = V4L2_DEC_CMD_STOP;
    if (ioctl(fd, VIDIOC_DECODER_CMD, &cmd) < 0)
        fprintf(stderr, "DECODER_CMD STOP: %s (continuing to drain)\n", strerror(errno));

    int idle = 0;
    while (idle < 2) {
        int w = wait_fd(fd, POLLIN, "CAPTURE dq (drain)");
        if (w < 0) exit(4);
        if (w == 0) {
            if (idle >= 1) break; /* drained: idle poll after EAGAIN */
            fprintf(stderr, "decode: drain timeout\n");
            exit(4);
        }
        struct v4l2_buffer b;
        int r = dqbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &b);
        if (r < 0) {
            if (errno == EAGAIN) { idle++; continue; }
            perror("DQBUF CAPTURE"); exit(3);
        }
        idle = 0;
        frames++;
        bytes_out += b.bytesused;
        if (strcmp(out_prefix, "-")) {
            char p[256];
            snprintf(p, sizeof(p), "%s%08u.nv12", out_prefix, b.sequence);
            FILE *o = fopen(p, "wb");
            if (!o) die(p);
            if (b.bytesused && fwrite(dstbuf[b.index].addr, 1, b.bytesused, o) != b.bytesused)
                { perror("fwrite frame"); exit(3); }
            if (fclose(o)) { perror("fclose frame"); exit(3); }
        }
        printf("decoded frame seq=%u bytes=%u\n", b.sequence, b.bytesused);
        if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, b.index, 0) < 0) { perror("re-QBUF CAPTURE"); exit(3); }
    }

    streamoff(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, "STREAMOFF OUTPUT");
    streamoff(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, "STREAMOFF CAPTURE");
    unmap_all(srcbuf, n_src);
    unmap_all(dstbuf, n_dst);
    close(fd);
    printf("summary au_in=%u frames_out=%llu bytes_out=%llu\n",
           aus.n, (unsigned long long)frames, (unsigned long long)bytes_out);
    free(aus.v); free(aus.blob);
}

/* ---------------- m2m encode ---------------- */

static void do_m2m_encode(const char *dev, const char *codec_s, int w, int h,
                          int frames_wanted, const char *out_path)
{
    unsigned int codec = s2fcc(codec_s);
    int fd = open(dev, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) die(dev);

    struct v4l2_format f;
    memset(&f, 0, sizeof(f));
    f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    f.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
    f.fmt.pix.width = w; f.fmt.pix.height = h;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &f, "S_FMT OUTPUT (NV12)") < 0) exit(3);
    unsigned int sizeimage = f.fmt.pix.sizeimage;
    unsigned int bytesperline = f.fmt.pix.bytesperline;
    if (sizeimage == 0) sizeimage = (unsigned)(w * h * 3 / 2);
    if (bytesperline == 0) bytesperline = (unsigned)w;

    memset(&f, 0, sizeof(f));
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    f.fmt.pix.pixelformat = codec;
    f.fmt.pix.width = 0; f.fmt.pix.height = 0;
    f.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &f, "S_FMT CAPTURE (coded)") < 0) exit(3);

    unsigned int n_src = REQ_BUF_COUNT, n_dst = REQ_BUF_COUNT;
    if (reqbufs_mmap(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &n_src) < 0) exit(3);
    if (reqbufs_mmap(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &n_dst) < 0) exit(3);
    struct mbuf srcbuf[REQ_BUF_COUNT], dstbuf[REQ_BUF_COUNT];
    memset(srcbuf, 0, sizeof(srcbuf)); memset(dstbuf, 0, sizeof(dstbuf));
    for (unsigned i = 0; i < n_src; i++)
        if (querybuf_mmap(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i, &srcbuf[i]) < 0) exit(3);
    for (unsigned i = 0; i < n_dst; i++)
        if (querybuf_mmap(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, &dstbuf[i]) < 0) exit(3);

    for (unsigned i = 0; i < n_dst; i++)
        if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, 0) < 0) exit(3);

    unsigned int out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    unsigned int cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &out_type, "STREAMON OUTPUT") < 0) exit(3);
    if (xioctl(fd, VIDIOC_STREAMON, &cap_type, "STREAMON CAPTURE") < 0) exit(3);

    FILE *o = fopen(out_path, "wb");
    if (!o) die(out_path);

    int fed = 0, out_in_driver = 0;
    uint64_t chunks = 0, bytes_out = 0;
    int drain = 0, idle = 0;
    int src_free[REQ_BUF_COUNT];
    for (unsigned i = 0; i < n_src; i++) src_free[i] = 1;
    while (1) {
        /* feed frames while OUTPUT buffers are free (actual free-list only) */
        while (fed < frames_wanted && !drain) {
            unsigned idx;
            for (idx = 0; idx < n_src; idx++) if (src_free[idx]) break;
            if (idx == n_src) break; /* all queued; drain/recycle first */
            unsigned char *base = srcbuf[idx].addr;
            for (int r = 0; r < h; r++)
                memset(base + (size_t)r * bytesperline, (unsigned char)((r + fed) & 0xff),
                       (size_t)bytesperline);
            unsigned char *uv = base + (size_t)bytesperline * h;
            for (int r = 0; r < h / 2; r++)
                memset(uv + (size_t)r * bytesperline, 0x80, (size_t)bytesperline);
            int wr = wait_fd(fd, POLLOUT, "OUTPUT q");
            if (wr <= 0) { fprintf(stderr, "encode: OUTPUT not writable\n"); exit(4); }
            if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, idx, sizeimage) < 0) {
                if (errno == EAGAIN) break;
                exit(3);
            }
            src_free[idx] = 0;
            out_in_driver++;
            fed++;
        }
        if (fed == frames_wanted && !drain) {
            struct v4l2_encoder_cmd cmd;
            memset(&cmd, 0, sizeof(cmd));
            cmd.cmd = V4L2_ENC_CMD_STOP;
            if (ioctl(fd, VIDIOC_ENCODER_CMD, &cmd) < 0)
                fprintf(stderr, "ENCODER_CMD STOP: %s (continuing to drain)\n", strerror(errno));
            drain = 1;
        }
        /* recycle one consumed OUTPUT buffer, if any (real DQBUF only) */
        struct v4l2_buffer s;
        if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &s) == 0) {
            src_free[s.index] = 1;
            out_in_driver--;
        } else if (errno != EAGAIN) {
            perror("DQBUF OUTPUT"); exit(3);
        }
        /* collect encoded chunks; two consecutive EAGAINs after STOP = done */
        int wr = wait_fd(fd, POLLIN, "CAPTURE dq");
        if (wr < 0) exit(4);
        if (wr == 0) {
            if (drain && idle >= 1) break;
            fprintf(stderr, "encode: drain timeout\n"); exit(4);
        }
        struct v4l2_buffer b;
        if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &b) == 0) {
            idle = 0;
            if (b.bytesused) {
                if (fwrite(dstbuf[b.index].addr, 1, b.bytesused, o) != b.bytesused)
                    { perror("fwrite es"); exit(3); }
                bytes_out += b.bytesused;
            }
            chunks++;
            printf("encoded chunk seq=%u bytes=%u\n", b.sequence, b.bytesused);
            if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, b.index, 0) < 0) { perror("re-QBUF CAPTURE"); exit(3); }
        } else if (errno == EAGAIN) {
            if (drain) idle++;
        } else {
            perror("DQBUF CAPTURE"); exit(3);
        }
        if (drain && idle >= 2 && out_in_driver == 0) break;
    }
    if (fclose(o)) { perror("fclose es"); exit(3); }
    streamoff(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, "STREAMOFF OUTPUT");
    streamoff(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, "STREAMOFF CAPTURE");
    unmap_all(srcbuf, n_src);
    unmap_all(dstbuf, n_dst);
    close(fd);
    printf("summary frames_in=%d chunks_out=%llu bytes_out=%llu out=%s\n",
           fed, (unsigned long long)chunks, (unsigned long long)bytes_out, out_path);
}

/* Regression for Linux01: an asynchronous device error must wake a real
 * blocking DQBUF without freeing its session underneath that syscall. */
struct fault_waiter { int fd, result, error; atomic_long tid; };

static void *fault_wait(void *opaque)
{
    struct fault_waiter *w = opaque;
    struct v4l2_buffer b = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
                            .memory = V4L2_MEMORY_MMAP};
    atomic_store_explicit(&w->tid, syscall(SYS_gettid), memory_order_release);
    w->result = ioctl(w->fd, VIDIOC_DQBUF, &b);
    w->error = errno;
    return NULL;
}

static int do_fault_dqbuf(const char *dev)
{
    alarm(10);
    int fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) die(dev);
    struct v4l2_format f = {.type = V4L2_BUF_TYPE_VIDEO_OUTPUT};
    f.fmt.pix.pixelformat = V4L2_PIX_FMT_H264;
    if (xioctl(fd, VIDIOC_S_FMT, &f, "fault S_FMT") < 0) return 3;
    unsigned ns = 1, nd = 1;
    struct mbuf src = {0}, dst = {0};
    if (reqbufs_mmap(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &ns) || ns != 1 ||
        reqbufs_mmap(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &nd) || nd != 1 ||
        querybuf_mmap(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, 0, &src) ||
        querybuf_mmap(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 0, &dst) ||
        qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, 0, 0)) return 3;
    unsigned type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type, "fault CAPTURE on")) return 3;
    type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    if (xioctl(fd, VIDIOC_STREAMON, &type, "fault OUTPUT on")) return 3;
    struct fault_waiter waiter = {.fd = fd};
    atomic_init(&waiter.tid, 0);
    pthread_t thread;
    if (pthread_create(&thread, NULL, fault_wait, &waiter)) return 3;
    int blocked = 0, read_error = 0;
    char last_syscall[512] = "no syscall observation";
    for (unsigned i = 0; i < 100 && !blocked; i++) {
        long tid = atomic_load_explicit(&waiter.tid, memory_order_acquire);
        if (tid) {
            char path[128], line[512];
            snprintf(path, sizeof path, "/proc/self/task/%ld/syscall", tid);
            FILE *in = fopen(path, "r");
            if (in) {
                long nr; unsigned long arg_fd, request;
                if (fgets(line, sizeof line, in)) {
                    snprintf(last_syscall, sizeof last_syscall, "%s", line);
                    /* musl ioctl(int,int,...) sign-extends w1 to x1; Linux
                     * decodes its command as unsigned32. /proc shows x1. */
                    if (sscanf(line, "%ld %lx %lx", &nr, &arg_fd, &request) == 3 &&
                        nr == SYS_ioctl && arg_fd == (unsigned)fd &&
                        (uint32_t)request == (uint32_t)VIDIOC_DQBUF)
                        blocked = 1;
                } else read_error = errno;
                fclose(in);
            } else read_error = errno;
        }
        if (!blocked) usleep(1000);
    }
    fprintf(stderr, "fault syscall observation: %s", last_syscall);
    if (!blocked) {
        fprintf(stderr, "fault probe never observed blocking DQBUF (read errno=%d)\n", read_error);
        return 3;
    }
    /* A VCL access unit without any SPS/PPS is deliberately invalid. */
    const unsigned char bad[] = {0, 0, 0, 1, 0x65, 0x80};
    memcpy(src.addr, bad, sizeof bad);
    if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, 0, sizeof bad)) return 3;
    if (pthread_join(thread, NULL)) return 3;
    struct pollfd pollfd = {.fd = fd, .events = POLLIN | POLLOUT | POLLPRI};
    int polled = poll(&pollfd, 1, 0);
    struct v4l2_capability cap;
    errno = 0;
    int query = ioctl(fd, VIDIOC_QUERYCAP, &cap), query_error = errno;
    unmap_all(&src, 1); unmap_all(&dst, 1);
    int closed = close(fd);
    int fresh = open(dev, O_RDWR | O_CLOEXEC), recovered = 0;
    if (fresh >= 0) { recovered = ioctl(fresh, VIDIOC_QUERYCAP, &cap) == 0; close(fresh); }
    alarm(0);
    int ok = waiter.result == -1 && waiter.error == EIO && polled == 1 &&
             (pollfd.revents & POLLERR) && query == -1 && query_error == EIO &&
             closed == 0 && recovered;
    printf("{\"faultDqbuf\":\"%s\",\"blockedObserved\":%d,\"dequeueErrno\":%d,"
           "\"pollError\":%d,\"closed\":%d,\"freshSessionWorks\":%d}\n",
           ok ? "passed" : "failed", blocked, waiter.error,
           !!(pollfd.revents & POLLERR), closed == 0, recovered);
    return ok ? 0 : 3;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 3) {
        fprintf(stderr, "usage:\n"
            "  fvm_qual enum <dev>\n"
            "  fvm_qual m2m-decode <dev> <es> [out-prefix|-] [-c H264|HEVC] [-t ms]\n"
            "  fvm_qual m2m-encode <dev> <CODEC> <w> <h> <frames> <out.es> [-t ms]\n");
        return 2;
    }
    if (!strcmp(argv[1], "enum")) { do_enum(argv[2]); return 0; }
    if (!strcmp(argv[1], "fault-dqbuf")) return do_fault_dqbuf(argv[2]);

    /* trailing options */
    unsigned int codec = V4L2_PIX_FMT_H264;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "-t") && i + 1 < argc) g_timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) {
            const char *c = argv[++i];
            codec = s2fcc(c);
            if (codec != V4L2_PIX_FMT_H264 && codec != V4L2_PIX_FMT_HEVC) {
                fprintf(stderr, "codec must be H264 or HEVC\n"); return 2;
            }
        }
    }
    if (!strcmp(argv[1], "m2m-decode") && argc >= 4) {
        do_m2m_decode(argv[2], argv[3], argc >= 5 ? argv[4] : "-", codec);
        return 0;
    }
    if (!strcmp(argv[1], "m2m-encode") && argc >= 8) {
        do_m2m_encode(argv[2], argv[3], atoi(argv[4]), atoi(argv[5]),
                      atoi(argv[6]), argv[7]);
        return 0;
    }
    return 2;
}
