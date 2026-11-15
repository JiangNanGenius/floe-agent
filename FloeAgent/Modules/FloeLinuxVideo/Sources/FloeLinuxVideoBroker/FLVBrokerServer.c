/* SPDX-License-Identifier: MPL-2.0
 *
 * FLVBrokerServer.c — bounded single-client typed native-codec broker.
 *
 * The server owns one FLVHost and one listener thread. It speaks the wire
 * contract in floe_linux_video_broker_wire.h. It never dereferences a guest
 * pointer, never opens a path supplied by a client, and never exposes an
 * Apple object or function pointer. Session IDs are a monotonic server token
 * table; destroying the broker, the client disconnecting, or a session
 * DESTROY releases every native object through the frozen API.
 */
#include "floe_linux_video_broker.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define FLVB_MAX_SESSIONS 8u
#define FLVB_MAX_CONFIG_BYTES 4096u
#define FLVB_MAX_CAPABILITIES 22u
#define FLVB_CLIENT_TIMEOUT_SECONDS 120
#define FLVB_MAX_DEQUEUE_MS 5000u
#define FLVB_DEFAULT_DEQUEUE_MS 1000u

typedef struct {
    uint64_t id;
    FLVSession *session;
    uint32_t codec;
    uint32_t direction;
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;
    uint64_t expected_frame_bytes;
} FLVBrokerSession;

struct FLVBroker {
    FLVBrokerConfig config;
    uint64_t token;
    uint16_t port;
    int listen_fd;
    int client_fd;
    int wake_pipe[2];
    pthread_t thread;
    bool thread_started;
    _Atomic int stopping;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    FLVHost *host;
    FLVBrokerSession sessions[FLVB_MAX_SESSIONS];
    uint32_t session_count;
    uint64_t next_session_id;
    uint32_t allow_native_software;
    uint64_t submitted;
    uint64_t hardware_outputs;
    uint64_t native_software_outputs;
    uint64_t errors;
    uint64_t cancelled;
    uint64_t accepted_clients;
};

static uint64_t flvb_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int flvb_read_full(int fd, void *dst, size_t bytes) {
    uint8_t *p = (uint8_t *)dst;
    size_t done = 0;
    while (done < bytes) {
        ssize_t n = recv(fd, p + done, bytes - done, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int flvb_write_full(int fd, const void *src, size_t bytes) {
    const uint8_t *p = (const uint8_t *)src;
    size_t done = 0;
    while (done < bytes) {
        ssize_t n;
#ifdef MSG_NOSIGNAL
        n = send(fd, p + done, bytes - done, MSG_NOSIGNAL);
#else
        n = send(fd, p + done, bytes - done, 0);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static void flvb_notify(void *opaque, uint64_t session_tag, uint32_t events) {
    (void)session_tag;
    (void)events;
    FLVBroker *b = (FLVBroker *)opaque;
    if (!b) return;
    pthread_mutex_lock(&b->lock);
    pthread_cond_broadcast(&b->cond);
    pthread_mutex_unlock(&b->lock);
}

static FLVBrokerSession *flvb_find(FLVBroker *b, uint64_t id) {
    if (!id) return NULL;
    for (uint32_t i = 0; i < FLVB_MAX_SESSIONS; i++) {
        if (b->sessions[i].id == id) return &b->sessions[i];
    }
    return NULL;
}

static void flvb_session_release(FLVBroker *b, FLVBrokerSession *s) {
    if (!s || !s->session) return;
    flv_session_cancel(s->session);
    flv_session_close(s->session);
    s->session = NULL;
    s->id = 0;
    if (b->session_count > 0) b->session_count--;
}

static void flvb_close_all_sessions(FLVBroker *b) {
    pthread_mutex_lock(&b->lock);
    for (uint32_t i = 0; i < FLVB_MAX_SESSIONS; i++) {
        if (b->sessions[i].session) flvb_session_release(b, &b->sessions[i]);
    }
    pthread_mutex_unlock(&b->lock);
}

static int flvb_reply_error(int fd, uint32_t op, int32_t status) {
    flvb_reply r;
    memset(&r, 0, sizeof(r));
    r.magic = FLVB_WIRE_MAGIC;
    r.op = op;
    r.status = status;
    return flvb_write_full(fd, &r, sizeof(r));
}

static int flvb_send_reply(int fd, const flvb_reply *r, const void *payload, uint32_t length) {
    if (flvb_write_full(fd, r, sizeof(*r))) return -1;
    if (length && payload && flvb_write_full(fd, payload, length)) return -1;
    return 0;
}

static int flvb_list(FLVBroker *b, int fd, const flvb_request *req) {
    if (req->length != 0) return flvb_reply_error(fd, req->op, FLV_INVALID);
    FLVCapability caps[FLVB_MAX_CAPABILITIES];
    memset(caps, 0, sizeof(caps));
    size_t count = 0;
    int status = flv_host_query_capabilities(b->host, caps, FLVB_MAX_CAPABILITIES, &count);
    if (status != FLV_OK) return flvb_reply_error(fd, req->op, status);
    if (count > FLVB_MAX_CAPABILITIES) count = FLVB_MAX_CAPABILITIES;
    uint32_t payload_bytes = (uint32_t)(8 + count * sizeof(flvb_capability));
    uint8_t *payload = (uint8_t *)calloc(1, payload_bytes ? payload_bytes : 1);
    if (!payload) return flvb_reply_error(fd, req->op, FLV_LIMIT);
    uint32_t enabled;
    pthread_mutex_lock(&b->lock);
    enabled = b->allow_native_software;
    pthread_mutex_unlock(&b->lock);
    memcpy(payload, &enabled, 4);
    memcpy(payload + 4, &count, 4);
    for (size_t i = 0; i < count; i++) {
        flvb_capability record;
        memset(&record, 0, sizeof(record));
        record.codec = caps[i].codec;
        record.direction = caps[i].direction;
        record.flags = caps[i].flags;
        record.pixel_format_mask = caps[i].pixel_format_mask;
        record.max_width = caps[i].max_width;
        record.max_height = caps[i].max_height;
        record.probe_status = caps[i].probe_status;
        memcpy(payload + 8 + i * sizeof(record), &record, sizeof(record));
    }
    flvb_reply r;
    memset(&r, 0, sizeof(r));
    r.magic = FLVB_WIRE_MAGIC;
    r.op = req->op;
    r.status = FLV_OK;
    r.length = payload_bytes;
    int rc = flvb_send_reply(fd, &r, payload, payload_bytes);
    free(payload);
    return rc;
}

static int flvb_create_session(FLVBroker *b, int fd, const flvb_request *req, const uint8_t *payload) {
    if (req->length < sizeof(flvb_create_request)) return flvb_reply_error(fd, req->op, FLV_INVALID);
    flvb_create_request cr;
    memcpy(&cr, payload, sizeof(cr));
    if (cr.reserved != 0 || cr.codec_config_bytes > FLVB_MAX_CONFIG_BYTES ||
        (uint64_t)sizeof(cr) + cr.codec_config_bytes != req->length) {
        return flvb_reply_error(fd, req->op, FLV_INVALID);
    }
    if (cr.width > 8192u || cr.height > 8192u || cr.frame_rate_den == 0) {
        return flvb_reply_error(fd, req->op, FLV_INVALID);
    }
    FLVSessionConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = FLV_ABI_VERSION;
    config.codec = cr.codec;
    config.direction = cr.direction;
    config.pixel_format = cr.pixel_format;
    config.width = cr.width;
    config.height = cr.height;
    config.frame_rate_num = cr.frame_rate_num;
    config.frame_rate_den = cr.frame_rate_den;
    config.bitrate = cr.bitrate;
    config.flags = cr.flags;
    config.bitstream_format = cr.bitstream_format;
    config.profile = cr.profile;
    config.codec_config = cr.codec_config_bytes ? payload + sizeof(cr) : NULL;
    config.codec_config_bytes = cr.codec_config_bytes;
    config.session_tag = 0;

    pthread_mutex_lock(&b->lock);
    if (b->session_count >= FLVB_MAX_SESSIONS) {
        pthread_mutex_unlock(&b->lock);
        return flvb_reply_error(fd, req->op, FLV_LIMIT);
    }
    FLVBrokerSession *slot = NULL;
    for (uint32_t i = 0; i < FLVB_MAX_SESSIONS; i++) {
        if (!b->sessions[i].session) { slot = &b->sessions[i]; break; }
    }
    if (!slot) {
        pthread_mutex_unlock(&b->lock);
        return flvb_reply_error(fd, req->op, FLV_LIMIT);
    }
    if (cr.codec_config_bytes == 0) config.codec_config = NULL;
    /* Native-software policy is explicit: a hardware-required caller keeps
     * the strict rule, and only a policy-enabled non-hardware session gets
     * the additive host flag (currently only MJPEG ImageIO uses it). */
    if (!(cr.flags & FLV_REQUIRE_HARDWARE) && b->allow_native_software) {
        config.flags |= FLV_ALLOW_NATIVE_SOFTWARE;
    }
    int status = flv_session_create(b->host, &config, &slot->session);
    if (status != FLV_OK) {
        slot->session = NULL;
        pthread_mutex_unlock(&b->lock);
        return flvb_reply_error(fd, req->op, status);
    }
    if (b->next_session_id == 0) b->next_session_id = 1;
    slot->id = b->next_session_id++;
    slot->codec = cr.codec;
    slot->direction = cr.direction;
    slot->width = cr.width;
    slot->height = cr.height;
    slot->pixel_format = cr.pixel_format;
    if (cr.pixel_format == FLV_P010) {
        slot->expected_frame_bytes = (uint64_t)cr.width * cr.height * 3u;
    } else if (cr.pixel_format == FLV_NV12) {
        slot->expected_frame_bytes = (uint64_t)cr.width * cr.height * 3u / 2u;
    } else if (cr.pixel_format == FLV_BGRA) {
        slot->expected_frame_bytes = (uint64_t)cr.width * cr.height * 4u;
    } else {
        slot->expected_frame_bytes = 0;
    }
    b->session_count++;
    uint64_t assigned = slot->id;
    pthread_mutex_unlock(&b->lock);

    flvb_reply r;
    memset(&r, 0, sizeof(r));
    r.magic = FLVB_WIRE_MAGIC;
    r.op = req->op;
    r.status = FLV_OK;
    r.session = assigned;
    r.width = cr.width;
    r.height = cr.height;
    r.pixel_format = cr.pixel_format;
    return flvb_send_reply(fd, &r, NULL, 0);
}

static int flvb_submit_packet(FLVBroker *b, int fd, const flvb_request *req, const uint8_t *payload) {
    int rc = FLV_CLOSED;
    pthread_mutex_lock(&b->lock);
    FLVBrokerSession *s = flvb_find(b, req->session);
    FLVSession *session = s ? s->session : NULL;
    pthread_mutex_unlock(&b->lock);
    if (!session) return flvb_reply_error(fd, req->op, FLV_CLOSED);
    FLVPacket packet;
    memset(&packet, 0, sizeof(packet));
    packet.data = payload;
    packet.bytes = req->length;
    packet.pts_ns = (int64_t)req->pts_ns;
    packet.dts_ns = (int64_t)req->dts_ns;
    packet.duration_ns = (int64_t)req->duration_ns;
    packet.flags = req->flags;
    rc = flv_session_submit_packet(session, &packet);
    if (rc == FLV_OK) {
        pthread_mutex_lock(&b->lock);
        b->submitted++;
        pthread_mutex_unlock(&b->lock);
    }
    return flvb_reply_error(fd, req->op, rc);
}

static int flvb_submit_frame(FLVBroker *b, int fd, const flvb_request *req, const uint8_t *payload) {
    FLVBrokerSession snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    pthread_mutex_lock(&b->lock);
    FLVBrokerSession *s = flvb_find(b, req->session);
    if (s) snapshot = *s;
    pthread_mutex_unlock(&b->lock);
    if (!snapshot.session) return flvb_reply_error(fd, req->op, FLV_CLOSED);
    if (req->length != snapshot.expected_frame_bytes) {
        return flvb_reply_error(fd, req->op, FLV_INVALID);
    }
    FLVFrame frame;
    memset(&frame, 0, sizeof(frame));
    frame.data = payload;
    frame.bytes = req->length;
    frame.width = snapshot.width;
    frame.height = snapshot.height;
    frame.pixel_format = snapshot.pixel_format;
    frame.pts_ns = (int64_t)req->pts_ns;
    frame.duration_ns = (int64_t)req->duration_ns;
    frame.flags = req->flags;
    if (snapshot.pixel_format == FLV_NV12 || snapshot.pixel_format == FLV_P010) {
        uint32_t stride = snapshot.width * ((snapshot.pixel_format == FLV_P010) ? 2u : 1u);
        frame.plane_count = 2;
        frame.plane_offsets[0] = 0;
        frame.plane_offsets[1] = stride * snapshot.height;
        frame.plane_bytes[0] = frame.plane_offsets[1];
        frame.plane_bytes[1] = (uint64_t)stride * (snapshot.height / 2u);
        frame.plane_strides[0] = stride;
        frame.plane_strides[1] = stride;
    } else if (snapshot.pixel_format == FLV_BGRA) {
        frame.plane_count = 1;
        frame.plane_offsets[0] = 0;
        frame.plane_bytes[0] = req->length;
        frame.plane_strides[0] = snapshot.width * 4u;
    } else {
        return flvb_reply_error(fd, req->op, FLV_UNSUPPORTED);
    }
    int rc = flv_session_submit_frame(snapshot.session, &frame);
    if (rc == FLV_OK) {
        pthread_mutex_lock(&b->lock);
        b->submitted++;
        pthread_mutex_unlock(&b->lock);
    }
    return flvb_reply_error(fd, req->op, rc);
}

static uint8_t *flvb_flatten_frame(const FLVOutput *o, uint32_t *out_length) {
    if (o->plane_count != 2 || (o->pixel_format != FLV_NV12 && o->pixel_format != FLV_P010) ||
        !o->width || !o->height || !o->data) {
        return NULL;
    }
    uint32_t src_stride = o->plane_strides[0];
    uint32_t dst_stride = o->width * ((o->pixel_format == FLV_P010) ? 2u : 1u);
    uint64_t y_plane = (uint64_t)dst_stride * o->height;
    uint64_t uv_plane = (uint64_t)dst_stride * (o->height / 2u);
    uint64_t total = y_plane + uv_plane;
    if (total > UINT32_MAX || !dst_stride) return NULL;
    uint8_t *flat = (uint8_t *)malloc((size_t)total);
    if (!flat) return NULL;
    for (uint32_t plane = 0; plane < 2; plane++) {
        uint32_t rows = plane ? o->height / 2u : o->height;
        if (o->plane_offsets[plane] > o->bytes) { free(flat); return NULL; }
        const uint8_t *src = o->data + o->plane_offsets[plane];
        uint8_t *dst = flat + (plane ? y_plane : 0);
        uint64_t needed = rows ? (uint64_t)(rows - 1) * src_stride + dst_stride : 0;
        if (needed > o->plane_bytes[plane] || needed > o->bytes - o->plane_offsets[plane]) {
            free(flat);
            return NULL;
        }
        for (uint32_t row = 0; row < rows; row++) {
            memcpy(dst + (uint64_t)row * dst_stride, src + (uint64_t)row * src_stride, dst_stride);
        }
    }
    *out_length = (uint32_t)total;
    return flat;
}

static int flvb_dequeue(FLVBroker *b, int fd, const flvb_request *req) {
    FLVBrokerSession *s;
    uint32_t timeout_ms = req->aux;
    if (timeout_ms > FLVB_MAX_DEQUEUE_MS) timeout_ms = FLVB_MAX_DEQUEUE_MS;
    uint64_t deadline = flvb_now_ms() + timeout_ms;
    pthread_mutex_lock(&b->lock);
    s = flvb_find(b, req->session);
    if (!s || !s->session) {
        pthread_mutex_unlock(&b->lock);
        return flvb_reply_error(fd, req->op, FLV_CLOSED);
    }
    FLVSession *session = s->session;
    pthread_mutex_unlock(&b->lock);

    for (;;) {
        FLVOutput output;
        memset(&output, 0, sizeof(output));
        int status = flv_session_dequeue(session, &output);
        if (status == FLV_OK) {
            uint8_t *payload = NULL;
            uint32_t payload_bytes = 0;
            if (output.kind == FLV_OUTPUT_FRAME) {
                payload = flvb_flatten_frame(&output, &payload_bytes);
                if (!payload) {
                    flv_session_release_output(session, &output);
                    pthread_mutex_lock(&b->lock);
                    b->errors++;
                    pthread_mutex_unlock(&b->lock);
                    return flvb_reply_error(fd, req->op, FLV_INTERNAL);
                }
            } else if (output.kind == FLV_OUTPUT_PACKET || output.kind == FLV_OUTPUT_FORMAT) {
                if (output.bytes > UINT32_MAX || (output.bytes && !output.data)) {
                    flv_session_release_output(session, &output);
                    return flvb_reply_error(fd, req->op, FLV_INTERNAL);
                }
                payload_bytes = (uint32_t)output.bytes;
                if (payload_bytes) {
                    payload = (uint8_t *)malloc(payload_bytes);
                    if (!payload) {
                        flv_session_release_output(session, &output);
                        return flvb_reply_error(fd, req->op, FLV_LIMIT);
                    }
                    memcpy(payload, output.data, payload_bytes);
                }
            } else if (output.kind == FLV_OUTPUT_ERROR) {
                pthread_mutex_lock(&b->lock);
                b->errors++;
                pthread_mutex_unlock(&b->lock);
            }
            flvb_reply r;
            memset(&r, 0, sizeof(r));
            r.magic = FLVB_WIRE_MAGIC;
            r.op = req->op;
            r.status = status;
            r.kind = output.kind;
            r.flags = output.flags;
            r.hardware_used = output.hardware_used;
            r.width = output.width;
            r.height = output.height;
            r.pixel_format = output.pixel_format;
            r.plane_count = output.plane_count;
            r.session = req->session;
            r.pts_ns = output.pts_ns;
            r.dts_ns = output.dts_ns;
            r.duration_ns = output.duration_ns;
            r.tag = output.tag;
            r.length = payload_bytes;
            if (output.kind == FLV_OUTPUT_PACKET || output.kind == FLV_OUTPUT_FRAME) {
                pthread_mutex_lock(&b->lock);
                if (output.hardware_used) b->hardware_outputs++;
                else b->native_software_outputs++;
                pthread_mutex_unlock(&b->lock);
            }
            flv_session_release_output(session, &output);
            int rc = flvb_send_reply(fd, &r, payload, payload_bytes);
            free(payload);
            return rc;
        }
        if (status != FLV_AGAIN) return flvb_reply_error(fd, req->op, status);
        uint64_t now = flvb_now_ms();
        if (now >= deadline) return flvb_reply_error(fd, req->op, FLV_AGAIN);
        struct timespec until;
        uint64_t wait_ms = deadline - now;
        if (wait_ms > 20) wait_ms = 20;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_nsec += (long)(wait_ms * 1000000u);
        if (until.tv_nsec >= 1000000000L) {
            until.tv_sec += until.tv_nsec / 1000000000L;
            until.tv_nsec %= 1000000000L;
        }
        pthread_mutex_lock(&b->lock);
        pthread_cond_timedwait(&b->cond, &b->lock, &until);
        pthread_mutex_unlock(&b->lock);
    }
}

static int flvb_flush(FLVBroker *b, int fd, const flvb_request *req) {
    FLVSession *session = NULL;
    pthread_mutex_lock(&b->lock);
    FLVBrokerSession *s = flvb_find(b, req->session);
    if (s) session = s->session;
    pthread_mutex_unlock(&b->lock);
    if (!session) return flvb_reply_error(fd, req->op, FLV_CLOSED);
    int rc = flv_session_flush(session, req->flags ? 1 : 0);
    return flvb_reply_error(fd, req->op, rc);
}

static int flvb_cancel(FLVBroker *b, int fd, const flvb_request *req) {
    FLVSession *session = NULL;
    pthread_mutex_lock(&b->lock);
    FLVBrokerSession *s = flvb_find(b, req->session);
    if (s) session = s->session;
    pthread_mutex_unlock(&b->lock);
    if (!session) return flvb_reply_error(fd, req->op, FLV_CLOSED);
    flv_session_cancel(session);
    pthread_mutex_lock(&b->lock);
    b->cancelled++;
    pthread_mutex_unlock(&b->lock);
    return flvb_reply_error(fd, req->op, FLV_OK);
}

static int flvb_destroy_session(FLVBroker *b, int fd, const flvb_request *req) {
    pthread_mutex_lock(&b->lock);
    FLVBrokerSession *s = flvb_find(b, req->session);
    if (s) flvb_session_release(b, s);
    pthread_mutex_unlock(&b->lock);
    return flvb_reply_error(fd, req->op, FLV_OK);
}

static int flvb_serve_client(FLVBroker *b, int fd) {
    flvb_hello hello;
    if (flvb_read_full(fd, &hello, sizeof(hello))) return 0;
    int accepted = hello.magic == FLVB_WIRE_MAGIC && hello.version == FLVB_WIRE_VERSION &&
                   hello.flags == 0 && hello.reserved == 0 && hello.token == b->token;
    flvb_hello_reply reply;
    memset(&reply, 0, sizeof(reply));
    reply.magic = FLVB_WIRE_MAGIC;
    reply.version = FLVB_WIRE_VERSION;
    reply.status = accepted ? 0 : -1;
    reply.max_packet_bytes = (uint32_t)(b->config.max_packet_bytes > UINT32_MAX
                                        ? UINT32_MAX : b->config.max_packet_bytes);
    if (flvb_write_full(fd, &reply, sizeof(reply))) return 0;

    if (!accepted) return 0;

    pthread_mutex_lock(&b->lock);
    b->accepted_clients++;
    pthread_mutex_unlock(&b->lock);

    for (;;) {
        flvb_request req;
        if (flvb_read_full(fd, &req, sizeof(req))) break;
        if (req.magic != FLVB_WIRE_MAGIC || req.reserved != 0) break;
        uint64_t limit = 0;
        switch (req.op) {
            case FLVB_OP_LIST:
            case FLVB_OP_DEQUEUE:
            case FLVB_OP_FLUSH:
            case FLVB_OP_CANCEL:
            case FLVB_OP_DESTROY: limit = 0; break;
            case FLVB_OP_CREATE: limit = FLVB_MAX_CONFIG_BYTES + sizeof(flvb_create_request); break;
            case FLVB_OP_SUBMIT_PACKET: limit = b->config.max_packet_bytes; break;
            case FLVB_OP_SUBMIT_FRAME: limit = b->config.max_frame_bytes; break;
            default: break;
        }
        if ((uint64_t)req.length > limit) {
            flvb_reply_error(fd, req.op, FLV_LIMIT);
            break; /* stream is desynchronized: close the client */
        }
        uint8_t *payload = NULL;
        if (req.length) {
            payload = (uint8_t *)malloc(req.length);
            if (!payload) { flvb_reply_error(fd, req.op, FLV_LIMIT); break; }
            if (flvb_read_full(fd, payload, req.length)) { free(payload); break; }
        }
        int rc = 0;
        switch (req.op) {
            case FLVB_OP_LIST: rc = flvb_list(b, fd, &req); break;
            case FLVB_OP_CREATE: rc = flvb_create_session(b, fd, &req, payload); break;
            case FLVB_OP_DESTROY: rc = flvb_destroy_session(b, fd, &req); break;
            case FLVB_OP_SUBMIT_PACKET: rc = flvb_submit_packet(b, fd, &req, payload); break;
            case FLVB_OP_SUBMIT_FRAME: rc = flvb_submit_frame(b, fd, &req, payload); break;
            case FLVB_OP_DEQUEUE: rc = flvb_dequeue(b, fd, &req); break;
            case FLVB_OP_FLUSH: rc = flvb_flush(b, fd, &req); break;
            case FLVB_OP_CANCEL: rc = flvb_cancel(b, fd, &req); break;
            default: rc = flvb_reply_error(fd, req.op, FLV_UNSUPPORTED); break;
        }
        free(payload);
        if (rc) break;
    }
    /* A disconnected client owns no native work. */
    flvb_close_all_sessions(b);
    return 0;
}

static void *flvb_thread_main(void *opaque) {
    FLVBroker *b = (FLVBroker *)opaque;
    struct pollfd fds[2];
    fds[0].fd = b->listen_fd;
    fds[0].events = POLLIN;
    fds[0].revents = 0;
    fds[1].fd = b->wake_pipe[0];
    fds[1].events = POLLIN;
    fds[1].revents = 0;
    for (;;) {
        int pr = poll(fds, 2, -1);
        if (pr < 0 && errno == EINTR) continue;
        if (pr < 0) break;
        if (fds[1].revents & POLLIN) break;
        if (!(fds[0].revents & POLLIN)) continue;
        struct sockaddr_in peer;
        socklen_t peer_len = sizeof(peer);
        int client = accept(b->listen_fd, (struct sockaddr *)&peer, &peer_len);
        if (client < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            break;
        }
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        struct timeval tv;
        tv.tv_sec = FLVB_CLIENT_TIMEOUT_SECONDS;
        tv.tv_usec = 0;
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        pthread_mutex_lock(&b->lock);
        b->client_fd = client;
        pthread_mutex_unlock(&b->lock);
        flvb_serve_client(b, client);
        pthread_mutex_lock(&b->lock);
        if (b->client_fd == client) b->client_fd = -1;
        pthread_mutex_unlock(&b->lock);
        shutdown(client, SHUT_RDWR);
        close(client);
    }
    flvb_close_all_sessions(b);
    return NULL;
}

static int flvb_parse_token(const char *text, uint64_t *out) {
    if (!text || !*text) return -1;
    size_t n = strlen(text);
    if (n != 16) return -1;
    uint64_t value = 0;
    for (size_t i = 0; i < n; i++) {
        char c = text[i];
        int digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return -1;
        value = (value << 4) | (uint64_t)digit;
    }
    *out = value;
    return 0;
}

int flvb_create(const FLVBrokerConfig *config, uint16_t *port_out,
                uint64_t *token_out, FLVBroker **broker_out) {
    if (!broker_out || !config || config->abi_version != FLVB_ABI_VERSION ||
        config->reserved != 0 || config->reserved_port != 0) {
        return FLV_INVALID;
    }
    *broker_out = NULL;
    if (port_out) *port_out = 0;
    if (token_out) *token_out = 0;
    if (config->max_sessions > FLVB_MAX_SESSIONS || config->max_inflight > 16) return FLV_INVALID;
    FLVBroker *b = (FLVBroker *)calloc(1, sizeof(*b));
    if (!b) return FLV_INTERNAL;
    b->listen_fd = -1;
    b->client_fd = -1;
    b->wake_pipe[0] = b->wake_pipe[1] = -1;
    b->config = *config;
    if (b->config.max_sessions == 0) b->config.max_sessions = 4;
    if (b->config.max_inflight == 0) b->config.max_inflight = 8;
    if (b->config.max_packet_bytes == 0) b->config.max_packet_bytes = 16u * 1024u * 1024u;
    if (b->config.max_frame_bytes == 0) b->config.max_frame_bytes = 64u * 1024u * 1024u;
    if (b->config.max_owned_bytes == 0) b->config.max_owned_bytes = 128u * 1024u * 1024u;
    if (b->config.max_packet_bytes > 256u * 1024u * 1024u ||
        b->config.max_frame_bytes > 512u * 1024u * 1024u ||
        b->config.max_owned_bytes > 512u * 1024u * 1024u) {
        free(b);
        return FLV_INVALID;
    }
    if (flvb_parse_token(config->access_token, &b->token)) {
        uint8_t random_bytes[8];
#if defined(__APPLE__)
        arc4random_buf(random_bytes, sizeof(random_bytes));
#else
        for (size_t i = 0; i < sizeof(random_bytes); i++) random_bytes[i] = (uint8_t)(rand() & 0xff);
#endif
        uint64_t generated = 0;
        for (size_t i = 0; i < sizeof(random_bytes); i++) generated = (generated << 8) | random_bytes[i];
        b->token = generated ? generated : UINT64_C(0x9e3779b97f4a7c15);
    }
    if (pthread_mutex_init(&b->lock, NULL)) { free(b); return FLV_INTERNAL; }
    if (pthread_cond_init(&b->cond, NULL)) { pthread_mutex_destroy(&b->lock); free(b); return FLV_INTERNAL; }
    if (pipe(b->wake_pipe)) { pthread_cond_destroy(&b->cond); pthread_mutex_destroy(&b->lock); free(b); return FLV_INTERNAL; }
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(b->wake_pipe[i], F_GETFL);
        if (flags >= 0) fcntl(b->wake_pipe[i], F_SETFL, flags | O_NONBLOCK);
        int fdflags = fcntl(b->wake_pipe[i], F_GETFD);
        if (fdflags >= 0) fcntl(b->wake_pipe[i], F_SETFD, fdflags | FD_CLOEXEC);
    }
    FLVHostConfig host_config;
    memset(&host_config, 0, sizeof(host_config));
    host_config.abi_version = FLV_ABI_VERSION;
    host_config.max_sessions = b->config.max_sessions;
    host_config.max_inflight_per_session = b->config.max_inflight;
    host_config.max_packet_bytes = b->config.max_packet_bytes;
    host_config.max_frame_bytes = b->config.max_frame_bytes;
    host_config.max_owned_bytes = b->config.max_owned_bytes;
    host_config.notify = flvb_notify;
    host_config.notify_opaque = b;
    if (flv_host_create(&host_config, &b->host) != FLV_OK) {
        close(b->wake_pipe[0]); close(b->wake_pipe[1]);
        pthread_cond_destroy(&b->cond); pthread_mutex_destroy(&b->lock);
        free(b);
        return FLV_INTERNAL;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) goto fail;
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &reuse, sizeof(reuse));
#endif
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(b->config.port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr))) { close(fd); goto fail; }
    if (listen(fd, 2)) { close(fd); goto fail; }
    socklen_t addr_len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &addr_len)) { close(fd); goto fail; }
    b->port = ntohs(addr.sin_port);
    b->listen_fd = fd;
    atomic_store(&b->stopping, 0);
    if (pthread_create(&b->thread, NULL, flvb_thread_main, b)) { close(fd); goto fail; }
    b->thread_started = true;
    if (port_out) *port_out = b->port;
    if (token_out) *token_out = b->token;
    *broker_out = b;
    return FLV_OK;
fail:
    flv_host_destroy(b->host);
    close(b->wake_pipe[0]); close(b->wake_pipe[1]);
    pthread_cond_destroy(&b->cond); pthread_mutex_destroy(&b->lock);
    free(b);
    return FLV_INTERNAL;
}

void flvb_destroy(FLVBroker *broker) {
    if (!broker) return;
    atomic_store(&broker->stopping, 1);
    if (broker->wake_pipe[1] >= 0) {
        uint8_t byte = 1;
        ssize_t ignored = write(broker->wake_pipe[1], &byte, 1);
        (void)ignored;
    }
    if (broker->listen_fd >= 0) shutdown(broker->listen_fd, SHUT_RDWR);
    pthread_mutex_lock(&broker->lock);
    if (broker->client_fd >= 0) shutdown(broker->client_fd, SHUT_RDWR);
    pthread_mutex_unlock(&broker->lock);
    if (broker->thread_started) pthread_join(broker->thread, NULL);
    if (broker->listen_fd >= 0) close(broker->listen_fd);
    if (broker->wake_pipe[0] >= 0) close(broker->wake_pipe[0]);
    if (broker->wake_pipe[1] >= 0) close(broker->wake_pipe[1]);
    if (broker->host) flv_host_destroy(broker->host);
    pthread_cond_destroy(&broker->cond);
    pthread_mutex_destroy(&broker->lock);
    free(broker);
}

int flvb_get_stats(FLVBroker *broker, FLVBrokerStats *stats) {
    if (!broker || !stats) return FLV_INVALID;
    memset(stats, 0, sizeof(*stats));
    stats->abi_version = FLVB_ABI_VERSION;
    stats->nodes = 1;
    FLVStats host_stats;
    memset(&host_stats, 0, sizeof(host_stats));
    if (flv_host_get_stats(broker->host, &host_stats) != FLV_OK) return FLV_INTERNAL;
    stats->sessions = host_stats.sessions;
    stats->inflight = host_stats.inflight;
    stats->queued_outputs = host_stats.queued_outputs;
    stats->host_owned_bytes = host_stats.owned_bytes;
    stats->host_peak_bytes = host_stats.peak_owned_bytes;
    pthread_mutex_lock(&broker->lock);
    stats->native_software_enabled = broker->allow_native_software;
    stats->submitted = broker->submitted;
    stats->hardware_outputs = broker->hardware_outputs;
    stats->native_software_outputs = broker->native_software_outputs;
    stats->errors = broker->errors;
    stats->cancelled = broker->cancelled;
    stats->accepted_clients = broker->accepted_clients > UINT32_MAX
        ? UINT32_MAX : (uint32_t)broker->accepted_clients;
    pthread_mutex_unlock(&broker->lock);
    FLVCapability caps[FLVB_MAX_CAPABILITIES];
    size_t count = 0;
    if (flv_host_query_capabilities(broker->host, caps, FLVB_MAX_CAPABILITIES, &count) == FLV_OK) {
        uint32_t formats = 0, mask = 0;
        for (size_t i = 0; i < count && i < FLVB_MAX_CAPABILITIES; i++) {
            if ((caps[i].flags & FLV_CAP_IMPLEMENTED) &&
                (caps[i].flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) &&
                caps[i].codec >= 1 && caps[i].codec <= 11) {
                formats++;
                uint32_t bit = (caps[i].codec - 1u) * 2u +
                               (caps[i].direction == FLV_DECODE ? 1u : 0u);
                mask |= 1u << bit;
            }
        }
        stats->native_software_formats = formats;
        stats->native_software_mask = mask;
    }
    return FLV_OK;
}

int flvb_set_native_software(FLVBroker *broker, uint32_t enabled) {
    if (!broker || enabled > 1) return FLV_INVALID;
    pthread_mutex_lock(&broker->lock);
    /* Idempotence is part of the ABI4 contract: re-applying the current
     * policy is a no-op even while sessions are live. Only a genuine change
     * requires the between-sessions window. */
    if (broker->allow_native_software == enabled) {
        pthread_mutex_unlock(&broker->lock);
        return FLV_OK;
    }
    if (broker->session_count > 0) {
        pthread_mutex_unlock(&broker->lock);
        return FLV_AGAIN;
    }
    broker->allow_native_software = enabled;
    pthread_mutex_unlock(&broker->lock);
    return FLV_OK;
}

int flvb_has_live_session(FLVBroker *broker, uint32_t *has_live) {
    if (!broker || !has_live) return FLV_INVALID;
    pthread_mutex_lock(&broker->lock);
    *has_live = broker->session_count > 0 ? 1u : 0u;
    pthread_mutex_unlock(&broker->lock);
    return FLV_OK;
}

int flvb_format_endpoint(uint16_t port, uint64_t token, char out[32]) {
    if (!out) return FLV_INVALID;
    int n = snprintf(out, 32, "floe:v1:%u:%016llx", (unsigned)port,
                     (unsigned long long)token);
    return (n > 0 && n < 32) ? FLV_OK : FLV_INVALID;
}
