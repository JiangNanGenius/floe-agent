/* SPDX-License-Identifier: MPL-2.0 */
#include "floe_codec_broker.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

static int read_full(int fd, void *dst, size_t bytes) {
    uint8_t *p = dst;
    size_t done = 0;
    while (done < bytes) {
        ssize_t n = recv(fd, p + done, bytes - done, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int write_full(int fd, const void *src, size_t bytes) {
    const uint8_t *p = src;
    size_t done = 0;
    while (done < bytes) {
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, p + done, bytes - done, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, p + done, bytes - done, 0);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}

static int parse_token_hex(const char *text, uint64_t *out) {
    if (!text || strlen(text) != 16) return -1;
    uint64_t v = 0;
    for (int i = 0; i < 16; i++) {
        char c = text[i];
        int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return -1;
        v = (v << 4) | (uint64_t)d;
    }
    *out = v;
    return 0;
}

int floe_codec_parse_endpoint(const char *text, char *host, size_t host_cap,
                              uint16_t *port, uint64_t *token) {
    if (!text || !*text || !host || !port || !token) return -1;
    char copy[160];
    if (strlen(text) >= sizeof(copy)) return -1;
    strcpy(copy, text);
    char *save = NULL;
    char *first = strtok_r(copy, ":", &save);
    char *second = strtok_r(NULL, ":", &save);
    char *third = strtok_r(NULL, ":", &save);
    char *fourth = strtok_r(NULL, ":", &save);
    if (!first) return -1;
    const char *h = "10.0.2.2";
    const char *p = NULL;
    const char *t = NULL;
    if (second && third && !fourth) { h = first; p = second; t = third; }
    else if (second && !third) { p = first; t = second; }
    else if (!second) { p = first; t = third; }
    else return -1;
    if (!p || !t) return -1;
    long port_value = strtol(p, NULL, 10);
    if (port_value < 1 || port_value > 65535) return -1;
    if (strlen(h) >= host_cap) return -1;
    strcpy(host, h);
    *port = (uint16_t)port_value;
    return parse_token_hex(t, token);
}

static int endpoint_from_bus(const char *bus, char *host, size_t host_cap,
                             uint16_t *port, uint64_t *token) {
    if (!bus || strncmp(bus, "floe:v1:", 8) != 0) return -1;
    const char *p = bus + 8;
    char *end = NULL;
    long port_value = strtol(p, &end, 10);
    if (!end || *end != ':' || port_value < 1 || port_value > 65535) return -1;
    if (strlen(end + 1) != 16) return -1;
    if (parse_token_hex(end + 1, token)) return -1;
    memset(host, 0, host_cap);
    snprintf(host, host_cap, "10.0.2.2");
    *port = (uint16_t)port_value;
    return 0;
}

static int try_device(const char *path, char *host, size_t host_cap,
                      uint16_t *port, uint64_t *token) {
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    int rc = ioctl(fd, VIDIOC_QUERYCAP, &cap);
    close(fd);
    if (rc < 0) return -1;
    return endpoint_from_bus((const char *)cap.bus_info, host, host_cap, port, token);
}

int floe_codec_discover_endpoint(const char *device, char *host, size_t host_cap,
                                 uint16_t *port, uint64_t *token) {
    if (device) return try_device(device, host, host_cap, port, token);
    char path[64];
    for (int i = 0; i < 32; i++) {
        snprintf(path, sizeof(path), "/dev/video%d", i);
        if (try_device(path, host, host_cap, port, token) == 0) return 0;
    }
    return -1;
}

int floe_codec_broker_open(floe_codec_broker *client, const char *host, uint16_t port,
                           uint64_t token) {
    if (!client) return -1;
    memset(client, 0, sizeof(*client));
    client->fd = -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr))) {
        close(fd);
        return -1;
    }
    flvb_hello hello;
    memset(&hello, 0, sizeof(hello));
    hello.magic = FLVB_WIRE_MAGIC;
    hello.version = FLVB_WIRE_VERSION;
    hello.token = token;
    if (write_full(fd, &hello, sizeof(hello))) { close(fd); return -1; }
    flvb_hello_reply reply;
    if (read_full(fd, &reply, sizeof(reply)) || reply.magic != FLVB_WIRE_MAGIC ||
        reply.version != FLVB_WIRE_VERSION || reply.status != 0) {
        close(fd);
        return -1;
    }
    client->fd = fd;
    client->token = token;
    client->port = port;
    snprintf(client->host, sizeof(client->host), "%s", host);
    client->max_packet_bytes = reply.max_packet_bytes;
    return 0;
}

void floe_codec_broker_close(floe_codec_broker *client) {
    if (!client) return;
    if (client->fd >= 0) close(client->fd);
    client->fd = -1;
}

static int broker_request(floe_codec_broker *client, const flvb_request *request,
                          flvb_reply *reply, uint8_t **payload_out) {
    if (!client || client->fd < 0) return -1;
    if (write_full(client->fd, request, sizeof(*request))) return -1;
    if (request->length && request->length > client->max_packet_bytes &&
        request->op == FLVB_OP_SUBMIT_PACKET) return -1;
    if (request->length) {
        /* The request payload follows the header; callers that need a body
         * use the dedicated helpers below. */
    }
    if (read_full(client->fd, reply, sizeof(*reply))) return -1;
    if (reply->magic != FLVB_WIRE_MAGIC) return -1;
    uint8_t *payload = NULL;
    if (reply->length) {
        payload = malloc(reply->length);
        if (!payload) return -1;
        if (read_full(client->fd, payload, reply->length)) { free(payload); return -1; }
    }
    if (payload_out) *payload_out = payload;
    else free(payload);
    return 0;
}

static int broker_request_with_body(floe_codec_broker *client, const flvb_request *request,
                                    const void *body, size_t body_bytes,
                                    flvb_reply *reply, uint8_t **payload_out) {
    if (!client || client->fd < 0) return -1;
    if (write_full(client->fd, request, sizeof(*request))) return -1;
    if (body_bytes && write_full(client->fd, body, body_bytes)) return -1;
    if (read_full(client->fd, reply, sizeof(*reply))) return -1;
    if (reply->magic != FLVB_WIRE_MAGIC) return -1;
    uint8_t *payload = NULL;
    if (reply->length) {
        if (reply->length > 128u * 1024u * 1024u) return -1;
        payload = malloc(reply->length);
        if (!payload) return -1;
        if (read_full(client->fd, payload, reply->length)) { free(payload); return -1; }
    }
    if (payload_out) *payload_out = payload;
    else free(payload);
    return 0;
}

int floe_codec_broker_list(floe_codec_broker *client,
                           floe_codec_capability *caps, size_t capacity,
                           size_t *count_out, uint32_t *native_software_enabled) {
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_LIST;
    flvb_reply reply;
    uint8_t *payload = NULL;
    if (broker_request(client, &req, &reply, &payload)) return -1;
    if (reply.status != 0 || reply.length < 8 || !payload) { free(payload); return -1; }
    uint32_t enabled = 0, count = 0;
    memcpy(&enabled, payload, 4);
    memcpy(&count, payload + 4, 4);
    size_t available = (reply.length - 8) / sizeof(flvb_capability);
    if (count > available) count = (uint32_t)available;
    if (count > capacity) count = (uint32_t)capacity;
    for (uint32_t i = 0; i < count; i++) {
        flvb_capability record;
        memcpy(&record, payload + 8 + i * sizeof(record), sizeof(record));
        caps[i].codec = record.codec;
        caps[i].direction = record.direction;
        caps[i].flags = record.flags;
        caps[i].pixel_format_mask = record.pixel_format_mask;
        caps[i].max_width = record.max_width;
        caps[i].max_height = record.max_height;
        caps[i].probe_status = record.probe_status;
    }
    if (count_out) *count_out = count;
    if (native_software_enabled) *native_software_enabled = enabled;
    free(payload);
    return 0;
}

int floe_codec_broker_create(floe_codec_broker *client, uint32_t codec, uint32_t direction,
                             uint32_t pixel_format, uint32_t width, uint32_t height,
                             uint32_t bitstream_format, uint32_t flags, uint64_t bitrate,
                             const uint8_t *config, size_t config_bytes,
                             uint64_t *session_out) {
    if (!client || !session_out || config_bytes > 4096) return -1;
    flvb_create_request create;
    memset(&create, 0, sizeof(create));
    create.codec = codec;
    create.direction = direction;
    create.pixel_format = pixel_format;
    create.width = width;
    create.height = height;
    create.frame_rate_num = 30;
    create.frame_rate_den = 1;
    create.bitstream_format = bitstream_format;
    create.flags = flags;
    create.bitrate = bitrate;
    create.codec_config_bytes = (uint32_t)config_bytes;
    uint8_t body[sizeof(create) + 4096];
    memcpy(body, &create, sizeof(create));
    if (config_bytes) memcpy(body + sizeof(create), config, config_bytes);
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_CREATE;
    req.length = (uint32_t)(sizeof(create) + config_bytes);
    flvb_reply reply;
    uint8_t *payload = NULL;
    int rc = broker_request_with_body(client, &req, body, req.length, &reply, &payload);
    free(payload);
    if (rc || reply.status != 0) return -1;
    *session_out = reply.session;
    return 0;
}

int floe_codec_broker_destroy(floe_codec_broker *client, uint64_t session) {
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_DESTROY;
    req.session = session;
    flvb_reply reply;
    if (broker_request(client, &req, &reply, NULL)) return -1;
    return reply.status == 0 ? 0 : -1;
}

int floe_codec_broker_submit_packet(floe_codec_broker *client, uint64_t session,
                                    const uint8_t *data, size_t bytes,
                                    int64_t pts_ns, int64_t dts_ns, int64_t duration_ns,
                                    uint32_t flags) {
    if (!client || !data || !bytes || bytes > client->max_packet_bytes) return -1;
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_SUBMIT_PACKET;
    req.session = session;
    req.flags = flags;
    req.pts_ns = (uint64_t)pts_ns;
    req.dts_ns = (uint64_t)dts_ns;
    req.duration_ns = (uint64_t)duration_ns;
    req.length = (uint32_t)bytes;
    flvb_reply reply;
    if (broker_request_with_body(client, &req, data, bytes, &reply, NULL)) return -1;
    return reply.status;
}

int floe_codec_broker_submit_frame(floe_codec_broker *client, uint64_t session,
                                   const uint8_t *data, size_t bytes,
                                   int64_t pts_ns, int64_t duration_ns, uint32_t flags) {
    if (!client || !data || !bytes) return -1;
    if (bytes > 128u * 1024u * 1024u) return -1;
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_SUBMIT_FRAME;
    req.session = session;
    req.flags = flags;
    req.pts_ns = (uint64_t)pts_ns;
    req.duration_ns = (uint64_t)duration_ns;
    req.length = (uint32_t)bytes;
    flvb_reply reply;
    if (broker_request_with_body(client, &req, data, bytes, &reply, NULL)) return -1;
    return reply.status;
}

int floe_codec_broker_dequeue(floe_codec_broker *client, uint64_t session,
                              flvb_reply *reply, uint8_t **payload_out,
                              uint32_t timeout_ms) {
    if (!client || !reply || !payload_out) return -1;
    *payload_out = NULL;
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_DEQUEUE;
    req.session = session;
    req.aux = timeout_ms;
    if (broker_request(client, &req, reply, payload_out)) return -1;
    return reply->status;
}

int floe_codec_broker_flush(floe_codec_broker *client, uint64_t session, int drain) {
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_FLUSH;
    req.session = session;
    req.flags = drain ? 1u : 0u;
    flvb_reply reply;
    if (broker_request(client, &req, &reply, NULL)) return -1;
    return reply.status == 0 ? 0 : -1;
}

int floe_codec_broker_cancel(floe_codec_broker *client, uint64_t session) {
    flvb_request req;
    memset(&req, 0, sizeof(req));
    req.magic = FLVB_WIRE_MAGIC;
    req.op = FLVB_OP_CANCEL;
    req.session = session;
    flvb_reply reply;
    if (broker_request(client, &req, &reply, NULL)) return -1;
    return reply.status == 0 ? 0 : -1;
}
