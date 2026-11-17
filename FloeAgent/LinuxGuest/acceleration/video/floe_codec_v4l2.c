/* SPDX-License-Identifier: MPL-2.0 */
#include "floe_codec_v4l2.h"

#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define FLOE_V4L2_BUFFERS 8
#define FLOE_V4L2_TIMEOUT_MS 5000

typedef struct { uint8_t *addr; size_t len; } mmap_buffer;

static int xioctl(int fd, unsigned long request, void *arg, const char *name) {
    int rc;
    do { rc = ioctl(fd, request, arg); } while (rc < 0 && errno == EINTR);
    if (rc < 0) fprintf(stderr, "floe-codec: %s: %s\n", name, strerror(errno));
    return rc;
}

static int wait_fd(int fd, short events, const char *what) {
    struct pollfd p = { .fd = fd, .events = events };
    int rc;
    do { rc = poll(&p, 1, FLOE_V4L2_TIMEOUT_MS); } while (rc < 0 && errno == EINTR);
    if (rc < 0) { fprintf(stderr, "floe-codec: poll(%s): %s\n", what, strerror(errno)); return -1; }
    if (rc == 0) { fprintf(stderr, "floe-codec: poll(%s): timeout\n", what); return 0; }
    return 1;
}

static int fourcc_codec(uint32_t f) {
    switch (f) {
        case V4L2_PIX_FMT_H264: return 1;
        case V4L2_PIX_FMT_HEVC: return 2;
        case V4L2_PIX_FMT_VP9: return 3;
        case V4L2_PIX_FMT_MJPEG: return 5;
        case V4L2_PIX_FMT_MPEG2: return 6;
        case V4L2_PIX_FMT_MPEG4: return 7;
        case V4L2_PIX_FMT_H263: return 10;
        case V4L2_PIX_FMT_VP8: return 11;
        default: return 0;
    }
}

/* The client transfers single-planar NV12. Compressed OUTPUT is decode
 * input, and compressed CAPTURE is encoder output. Cameras and multi-planar
 * devices may exist without supporting these transfer paths. */
static uint32_t queue_formats(int fd, unsigned type, int *nv12) {
    struct v4l2_fmtdesc fmt = { .type = type };
    uint32_t formats = 0;
    *nv12 = 0;
    while (ioctl(fd, VIDIOC_ENUM_FMT, &fmt) == 0) {
        int codec = fourcc_codec(fmt.pixelformat);
        if (codec) formats |= 1u << codec;
        if (fmt.pixelformat == V4L2_PIX_FMT_NV12) *nv12 = 1;
        fmt.index++;
    }
    return formats;
}

static int inspect_node(const char *path, floe_v4l2_device_info *info) {
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    struct v4l2_capability cap = {0};
    if (ioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) { close(fd); return -1; }
    memset(info, 0, sizeof(*info));
    snprintf(info->path, sizeof(info->path), "%s", path);
    snprintf(info->card, sizeof(info->card), "%.*s", (int)sizeof(cap.card), (const char *)cap.card);
    snprintf(info->bus, sizeof(info->bus), "%.*s", (int)sizeof(cap.bus_info), (const char *)cap.bus_info);
    uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
    info->m2m = !!(caps & (V4L2_CAP_VIDEO_M2M | V4L2_CAP_VIDEO_M2M_MPLANE));
    if ((caps & V4L2_CAP_VIDEO_M2M) && (caps & V4L2_CAP_STREAMING)) {
        int raw_input, raw_output;
        uint32_t input = queue_formats(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &raw_input);
        uint32_t output = queue_formats(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &raw_output);
        if (raw_output) info->decode_formats = input;
        if (raw_input) info->encode_formats = output;
    }
    close(fd);
    return 0;
}

int floe_codec_v4l2_scan(floe_v4l2_device_info *devices, size_t capacity, size_t *count_out) {
    if (!devices || !count_out) return -1;
    *count_out = 0;
    glob_t entries = {0};
    int status = glob("/dev/video[0-9]*", 0, NULL, &entries);
    if (status != 0 && status != GLOB_NOMATCH) { globfree(&entries); return -1; }
    for (size_t i = 0; i < entries.gl_pathc && *count_out < capacity; i++) {
        const char *path = entries.gl_pathv[i];
        const char *digits = path + sizeof("/dev/video") - 1;
        if (digits[strspn(digits, "0123456789")] != '\0') continue;
        if (inspect_node(path, &devices[*count_out]) == 0) (*count_out)++;
    }
    globfree(&entries);
    return 0;
}

int floe_codec_v4l2_find(const char *explicit_path, int decoder, unsigned codec,
                         floe_v4l2_device_info *out) {
    if (!out || codec >= 32) return -1;
    floe_v4l2_device_info devices[64];
    size_t count = 0;
    if (floe_codec_v4l2_scan(devices, 64, &count)) return -1;
    for (size_t i = 0; i < count; i++) {
        if (explicit_path && strcmp(devices[i].path, explicit_path) != 0) continue;
        uint32_t formats = decoder ? devices[i].decode_formats : devices[i].encode_formats;
        if (formats & (1u << codec)) { *out = devices[i]; return 0; }
    }
    return -1;
}

static int reqbufs(int fd, unsigned type, unsigned *count) {
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.type = type;
    req.memory = V4L2_MEMORY_MMAP;
    req.count = *count;
    if (xioctl(fd, VIDIOC_REQBUFS, &req, "REQBUFS") < 0) return -1;
    *count = req.count;
    return 0;
}

static int querybuf(int fd, unsigned type, unsigned index, mmap_buffer *out) {
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = type;
    b.memory = V4L2_MEMORY_MMAP;
    b.index = index;
    if (xioctl(fd, VIDIOC_QUERYBUF, &b, "QUERYBUF") < 0) return -1;
    void *mapped = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
    if (mapped == MAP_FAILED) { perror("mmap"); return -1; }
    out->addr = mapped;
    out->len = b.length;
    return 0;
}

static int qbuf(int fd, unsigned type, unsigned index, unsigned used) {
    struct v4l2_buffer b;
    memset(&b, 0, sizeof(b));
    b.type = type;
    b.memory = V4L2_MEMORY_MMAP;
    b.index = index;
    b.bytesused = used;
    return xioctl(fd, VIDIOC_QBUF, &b, "QBUF");
}

static int dqbuf(int fd, unsigned type, struct v4l2_buffer *b) {
    memset(b, 0, sizeof(*b));
    b->type = type;
    b->memory = V4L2_MEMORY_MMAP;
    int rc;
    do { rc = ioctl(fd, VIDIOC_DQBUF, b); } while (rc < 0 && errno == EINTR);
    if (rc < 0 && errno != EAGAIN && errno != EPIPE) {
        int saved = errno;
        fprintf(stderr, "floe-codec: DQBUF: %s\n", strerror(saved));
        errno = saved;
    }
    return rc;
}

static void unmap_all(mmap_buffer *bufs, unsigned count) {
    for (unsigned i = 0; i < count; i++)
        if (bufs[i].addr && bufs[i].addr != MAP_FAILED) munmap(bufs[i].addr, bufs[i].len);
}

/* Some filesystems cannot write directly from a device MMAP (EFAULT). Copy
 * to ordinary memory first so workspace and local files behave alike. */
static int write_capture(FILE *output, const mmap_buffer *buffers, unsigned count,
                         const struct v4l2_buffer *buffer) {
    if (buffer->index >= count || buffer->bytesused > buffers[buffer->index].len) {
        errno = EOVERFLOW;
        return -1;
    }
    if (!buffer->bytesused) return 0;
    uint8_t *copy = malloc(buffer->bytesused);
    if (!copy) return -1;
    memcpy(copy, buffers[buffer->index].addr, buffer->bytesused);
    size_t written = fwrite(copy, 1, buffer->bytesused, output);
    int saved = errno;
    free(copy);
    if (written != buffer->bytesused) {
        errno = saved ? saved : EIO;
        return -1;
    }
    return 0;
}

int floe_codec_v4l2_decode(const char *device, uint32_t codec_fourcc,
                           const floe_au *aus, size_t au_count,
                           uint32_t width, uint32_t height,
                           FILE *output, uint32_t limit, uint64_t *frames_out,
                           uint64_t *bytes_out) {
    if (!device || !aus || !au_count || !output) return -1;
    int fd = open(device, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { perror(device); return -1; }
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.pixelformat = codec_fourcc;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    fmt.fmt.pix.sizeimage = 2 * 1024 * 1024;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt, "S_FMT OUTPUT") < 0) { close(fd); return -1; }
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt, "S_FMT CAPTURE") < 0) { close(fd); return -1; }

    unsigned src_count = FLOE_V4L2_BUFFERS, dst_count = FLOE_V4L2_BUFFERS;
    if (reqbufs(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &src_count) < 0 ||
        reqbufs(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &dst_count) < 0) { close(fd); return -1; }
    if (src_count > FLOE_V4L2_BUFFERS) src_count = FLOE_V4L2_BUFFERS;
    if (dst_count > FLOE_V4L2_BUFFERS) dst_count = FLOE_V4L2_BUFFERS;
    mmap_buffer src[FLOE_V4L2_BUFFERS], dst[FLOE_V4L2_BUFFERS];
    memset(src, 0, sizeof(src));
    memset(dst, 0, sizeof(dst));
    for (unsigned i = 0; i < src_count; i++) if (querybuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i, &src[i])) goto fail;
    for (unsigned i = 0; i < dst_count; i++) if (querybuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, &dst[i])) goto fail;
    for (unsigned i = 0; i < dst_count; i++) if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, 0)) goto fail;
    unsigned cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    unsigned out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    if (xioctl(fd, VIDIOC_STREAMON, &cap_type, "STREAMON CAPTURE") < 0) goto fail;
    if (xioctl(fd, VIDIOC_STREAMON, &out_type, "STREAMON OUTPUT") < 0) goto fail;

    uint64_t frames = 0, total_bytes = 0;
    size_t au_index = 0;
    unsigned in_driver = 0;
    int src_free[FLOE_V4L2_BUFFERS];
    for (unsigned i = 0; i < src_count; i++) src_free[i] = 1;
    while (au_index < au_count && (!limit || frames < limit)) {
        if (in_driver == src_count) {
            int ready = wait_fd(fd, POLLIN, "OUTPUT recycle");
            if (ready <= 0) break;
            struct v4l2_buffer b;
            if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &b) == 0) { src_free[b.index] = 1; in_driver--; }
            else if (errno != EAGAIN) break;
        }
        unsigned index = src_count;
        for (unsigned i = 0; i < src_count; i++) if (src_free[i]) { index = i; break; }
        if (index == src_count) continue;
        const floe_au *au = &aus[au_index];
        if (au->bytes > src[index].len) {
            fprintf(stderr, "floe-codec: AU %zu (%zu bytes) exceeds buffer\n", au_index, au->bytes);
            goto fail;
        }
        memcpy(src[index].addr, au->data, au->bytes);
        if (wait_fd(fd, POLLOUT, "OUTPUT queue") <= 0) break;
        if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, index, (unsigned)au->bytes)) {
            if (errno == EAGAIN) continue;
            break;
        }
        src_free[index] = 0;
        in_driver++;
        au_index++;
    }
    struct v4l2_decoder_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.cmd = V4L2_DEC_CMD_STOP;
    (void)ioctl(fd, VIDIOC_DECODER_CMD, &cmd);

    int idle = 0;
    while (idle < 2) {
        int ready = wait_fd(fd, POLLIN, "CAPTURE drain");
        if (ready <= 0) break;
        struct v4l2_buffer b;
        if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &b) < 0) {
            if (errno == EAGAIN) { idle++; continue; }
            if (errno == EPIPE) break;
            goto fail;
        }
        idle = 0;
        if (b.bytesused) {
            if (write_capture(output, dst, dst_count, &b) != 0) goto fail;
            total_bytes += b.bytesused;
        }
        frames++;
        if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, b.index, 0)) break;
        if (limit && frames >= limit) break;
    }
    {
        unsigned type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        (void)ioctl(fd, VIDIOC_STREAMOFF, &type);
        type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        (void)ioctl(fd, VIDIOC_STREAMOFF, &type);
    }
    unmap_all(src, src_count);
    unmap_all(dst, dst_count);
    close(fd);
    if (frames_out) *frames_out = frames;
    if (bytes_out) *bytes_out = total_bytes;
    return 0;
fail:
    unmap_all(src, src_count);
    unmap_all(dst, dst_count);
    close(fd);
    return -1;
}

int floe_codec_v4l2_encode(const char *device, uint32_t codec_fourcc,
                           FILE *input, uint32_t width, uint32_t height,
                           uint64_t frame_bytes, uint32_t limit, FILE *output,
                           uint64_t *chunks_out, uint64_t *bytes_out) {
    if (!device || !input || !output || !width || !height || !frame_bytes) return -1;
    uint8_t *frame = NULL;
    int fd = open(device, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { perror(device); return -1; }
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt, "S_FMT OUTPUT") < 0) { close(fd); return -1; }
    uint32_t stride = fmt.fmt.pix.bytesperline ? fmt.fmt.pix.bytesperline : width;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.pixelformat = codec_fourcc;
    fmt.fmt.pix.width = width;
    fmt.fmt.pix.height = height;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt, "S_FMT CAPTURE") < 0) { close(fd); return -1; }

    unsigned src_count = FLOE_V4L2_BUFFERS, dst_count = FLOE_V4L2_BUFFERS;
    if (reqbufs(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &src_count) < 0 ||
        reqbufs(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &dst_count) < 0) { close(fd); return -1; }
    if (src_count > FLOE_V4L2_BUFFERS) src_count = FLOE_V4L2_BUFFERS;
    if (dst_count > FLOE_V4L2_BUFFERS) dst_count = FLOE_V4L2_BUFFERS;
    mmap_buffer src[FLOE_V4L2_BUFFERS], dst[FLOE_V4L2_BUFFERS];
    memset(src, 0, sizeof(src));
    memset(dst, 0, sizeof(dst));
    for (unsigned i = 0; i < src_count; i++) if (querybuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, i, &src[i])) goto fail;
    for (unsigned i = 0; i < dst_count; i++) if (querybuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, &dst[i])) goto fail;
    for (unsigned i = 0; i < dst_count; i++) if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, i, 0)) goto fail;
    unsigned out_type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    unsigned cap_type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &out_type, "STREAMON OUTPUT") < 0) goto fail;
    if (xioctl(fd, VIDIOC_STREAMON, &cap_type, "STREAMON CAPTURE") < 0) goto fail;

    frame = malloc((size_t)frame_bytes);
    if (!frame) goto fail;
    uint64_t fed = 0, chunks = 0, total = 0;
    int draining = 0, idle = 0;
    int src_free[FLOE_V4L2_BUFFERS];
    for (unsigned i = 0; i < src_count; i++) src_free[i] = 1;
    while (1) {
        while (!draining && (!limit || fed < limit)) {
            unsigned index = src_count;
            for (unsigned i = 0; i < src_count; i++) if (src_free[i]) { index = i; break; }
            if (index == src_count) break;
            if (fread(frame, 1, (size_t)frame_bytes, input) != frame_bytes) { draining = 1; break; }
            uint8_t *y = src[index].addr;
            for (uint32_t r = 0; r < height; r++)
                memcpy(y + (size_t)r * stride, frame + (size_t)r * width, width);
            uint8_t *uv = y + (size_t)stride * height;
            for (uint32_t r = 0; r < height / 2; r++)
                memcpy(uv + (size_t)r * stride, frame + (size_t)width * height + (size_t)r * width, width);
            if (wait_fd(fd, POLLOUT, "OUTPUT queue") <= 0) { draining = 1; break; }
            if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, index, (unsigned)frame_bytes)) {
                if (errno == EAGAIN) break;
                goto fail;
            }
            src_free[index] = 0;
            fed++;
        }
        if ((limit && fed >= limit) || (!limit && feof(input))) draining = 1;
        if (draining && idle == 0) {
            struct v4l2_encoder_cmd cmd;
            memset(&cmd, 0, sizeof(cmd));
            cmd.cmd = V4L2_ENC_CMD_STOP;
            (void)ioctl(fd, VIDIOC_ENCODER_CMD, &cmd);
            idle = 1;
        }
        struct v4l2_buffer b;
        if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, &b) == 0) {
            src_free[b.index] = 1;
        } else if (errno != EAGAIN && !(draining && errno == EPIPE)) {
            goto fail;
        }
        int ready = wait_fd(fd, POLLIN, "CAPTURE drain");
        if (ready <= 0) break;
        if (dqbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, &b) == 0) {
            idle = 0;
            if (b.bytesused) {
                if (write_capture(output, dst, dst_count, &b) != 0) goto fail;
                total += b.bytesused;
            }
            chunks++;
            if (qbuf(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, b.index, 0)) goto fail;
        } else if (errno == EAGAIN) {
            if (draining && idle >= 2) break;
            idle++;
        } else if (draining && errno == EPIPE) {
            break;
        } else {
            goto fail;
        }
        if (draining && idle >= 2) break;
    }
    free(frame);
    {
        unsigned type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
        (void)ioctl(fd, VIDIOC_STREAMOFF, &type);
        type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        (void)ioctl(fd, VIDIOC_STREAMOFF, &type);
    }
    unmap_all(src, src_count);
    unmap_all(dst, dst_count);
    close(fd);
    if (chunks_out) *chunks_out = chunks;
    if (bytes_out) *bytes_out = total;
    return 0;
fail:
    free(frame);
    unmap_all(src, src_count);
    unmap_all(dst, dst_count);
    close(fd);
    return -1;
}
