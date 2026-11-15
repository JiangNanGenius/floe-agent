// SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0+
// gen_fixtures_c — regenerate virtio-media wire fixtures from the REAL
// driver protocol.h and the pinned 6.12.107 kernel UAPI headers.
//
// Why C (replacing the Python gen_fixtures.py): the previous fixtures were
// built from a hand-maintained Python layout model and disagreed with the
// actual C wire structs on reserved/padding fields (cmd_close was 12 B vs
// real 16, resp_open_ok 12 vs 16, resp_mmap 20 vs 24). This generator fills
// the genuine structs, so every reserved field is guaranteed zero and every
// size matches driver/protocol.h by construction. It must agree with
// scripts/abi_probe_out.jsonl (125 entries, probed from the same headers).
//
// Build (host, after `make headers_install` into $HDRS):
//   cc -I "$HDRS/include" -I ../driver -o gen_fixtures gen_fixtures_c.c
// Run from the package root (writes fixtures/*.bin + fixtures.json + fixtures.h).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <linux/videodev2.h>
#include <linux/media.h>
#include "protocol.h"

/* Compile-time contract with the 125-entry ABI probe (abi_probe_out.jsonl).
 * If any of these fire, the UAPI headers changed vs the probe and BOTH must
 * be regenerated/renormalised together. */
_Static_assert(sizeof(struct virtio_media_cmd_open) == 8, "cmd_open");
_Static_assert(sizeof(struct virtio_media_resp_open) == 16, "resp_open");
_Static_assert(sizeof(struct virtio_media_cmd_close) == 16, "cmd_close");
_Static_assert(sizeof(struct virtio_media_cmd_ioctl) == 16, "cmd_ioctl");
_Static_assert(sizeof(struct virtio_media_resp_ioctl) == 8, "resp_ioctl");
_Static_assert(sizeof(struct virtio_media_cmd_mmap) == 20, "cmd_mmap");
_Static_assert(sizeof(struct virtio_media_resp_mmap) == 24, "resp_mmap");
_Static_assert(sizeof(struct virtio_media_cmd_munmap) == 16, "cmd_munmap");
_Static_assert(sizeof(struct virtio_media_event_error) == 16, "evt_error");
_Static_assert(sizeof(struct virtio_media_event_dqbuf) == 608, "evt_dqbuf");
_Static_assert(sizeof(struct virtio_media_event_event) == 144, "evt_event");
_Static_assert(sizeof(struct v4l2_buffer) == 88, "v4l2_buffer");
_Static_assert(sizeof(struct v4l2_plane) == 64, "v4l2_plane");
_Static_assert(sizeof(struct v4l2_capability) == 104, "v4l2_capability");
_Static_assert(sizeof(struct v4l2_requestbuffers) == 20, "v4l2_requestbuffers");
_Static_assert(offsetof(struct virtio_media_cmd_ioctl, code) == 12, "ioctl.code");
_Static_assert(offsetof(struct virtio_media_event_dqbuf, planes) == 96, "dqbuf.planes");
_Static_assert(VIDEO_MAX_PLANES == 8, "VIDEO_MAX_PLANES");

struct fixture { const char *name; const char *desc; const void *data; size_t len; };

static uint8_t buf[1024];
static size_t pos;

static void reset(void) { memset(buf, 0xAA, sizeof(buf)); pos = 0; }
static void put(const void *p, size_t n) { memcpy(buf + pos, p, n); pos += n; }

#define EMIT(s) put(&(s), sizeof(s))

static size_t build_cmd_open(void) {
    struct virtio_media_cmd_open s; memset(&s, 0, sizeof(s));
    s.hdr.cmd = VIRTIO_MEDIA_CMD_OPEN;
    reset(); EMIT(s); return pos;
}
static size_t build_resp_open_ok(void) {
    struct virtio_media_resp_open s; memset(&s, 0, sizeof(s));
    s.hdr.status = 0; s.session_id = 0x11223344u;
    reset(); EMIT(s); return pos;
}
static size_t build_resp_open_refused(void) {
    struct virtio_media_resp_open s; memset(&s, 0, sizeof(s));
    s.hdr.status = 24; /* Host sends positive EMFILE; the guest negates it. */
    reset(); EMIT(s); return pos;
}
static size_t build_cmd_close(void) {
    struct virtio_media_cmd_close s; memset(&s, 0, sizeof(s));
    s.hdr.cmd = VIRTIO_MEDIA_CMD_CLOSE; s.session_id = 0x11223344u;
    reset(); EMIT(s); return pos;
}
static size_t build_cmd_ioctl(unsigned int nr) {
    struct virtio_media_cmd_ioctl s; memset(&s, 0, sizeof(s));
    s.hdr.cmd = VIRTIO_MEDIA_CMD_IOCTL; s.session_id = 1; s.code = nr;
    reset(); EMIT(s); return pos;
}
static size_t build_payload_querycap(void) {
    struct v4l2_capability s; memset(&s, 0, sizeof(s));
    memcpy(s.driver, "virtio-media", 13);
    memcpy(s.card, "Floe VideoToolbox Decoder", 26);
    memcpy(s.bus_info, "platform:virtio-media", 22);
    s.version = 0x060c6bu;
    s.capabilities = V4L2_CAP_VIDEO_M2M | V4L2_CAP_STREAMING | V4L2_CAP_DEVICE_CAPS;
    s.device_caps = V4L2_CAP_VIDEO_M2M | V4L2_CAP_STREAMING;
    reset(); EMIT(s); return pos;
}
static size_t build_payload_qbuf_out_mplane(void) {
    struct { struct v4l2_buffer b; struct v4l2_plane p; } s; memset(&s, 0, sizeof(s));
    s.b.index = 0;
    s.b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    s.b.bytesused = 0;
    s.b.memory = V4L2_MEMORY_MMAP;
    s.b.length = 1;                 /* plane count for mplane */
    s.b.request_fd = -1;            /* reserved2/request_fd tail; -1 = no request */
    s.p.bytesused = 0x8000;
    s.p.length = 0x10000;
    s.p.m.mem_offset = 0x0000000000A00000ULL;
    reset(); EMIT(s); return pos;
}
static size_t build_payload_reqbufs(void) {
    struct v4l2_requestbuffers s; memset(&s, 0, sizeof(s));
    s.count = 4; s.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; s.memory = V4L2_MEMORY_MMAP;
    reset(); EMIT(s); return pos;
}
static size_t build_cmd_mmap(void) {
    struct virtio_media_cmd_mmap s; memset(&s, 0, sizeof(s));
    s.hdr.cmd = VIRTIO_MEDIA_CMD_MMAP; s.session_id = 1;
    s.flags = VIRTIO_MEDIA_MMAP_FLAG_RW; s.offset = 0xA00000u;
    reset(); EMIT(s); return pos;
}
static size_t build_resp_mmap(void) {
    struct virtio_media_resp_mmap s; memset(&s, 0, sizeof(s));
    s.hdr.status = 0; s.driver_addr = 0x200000ULL; s.len = 0x10000ULL;
    reset(); EMIT(s); return pos;
}
static size_t build_cmd_munmap(void) {
    struct virtio_media_cmd_munmap s; memset(&s, 0, sizeof(s));
    s.hdr.cmd = VIRTIO_MEDIA_CMD_MUNMAP; s.driver_addr = 0x200000ULL;
    reset(); EMIT(s); return pos;
}
static size_t build_evt_error(void) {
    struct virtio_media_event_error s; memset(&s, 0, sizeof(s));
    s.hdr.event = VIRTIO_MEDIA_EVT_ERROR; s.hdr.session_id = 1;
    s.errno = (uint32_t)-5; /* EIO */
    reset(); EMIT(s); return pos;
}
static size_t build_evt_dqbuf(void) {
    struct virtio_media_event_dqbuf s; memset(&s, 0, sizeof(s));
    s.hdr.event = VIRTIO_MEDIA_EVT_DQBUF; s.hdr.session_id = 1;
    s.buffer.index = 2;
    s.buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    s.buffer.bytesused = 0x12000;
    s.buffer.memory = V4L2_MEMORY_MMAP;
    s.buffer.length = 1;
    s.planes[0].bytesused = 0x12000;
    s.planes[0].length = 0x20000;
    reset(); EMIT(s); return pos;
}
static size_t build_evt_event_eos(void) {
    struct virtio_media_event_event s; memset(&s, 0, sizeof(s));
    s.hdr.event = VIRTIO_MEDIA_EVT_EVENT; s.hdr.session_id = 1;
    s.event.type = V4L2_EVENT_EOS;
    reset(); EMIT(s); return pos;
}

/* sha256 of emitted bytes (tiny self-contained implementation keeps the
 * generator dependency-free on hosts). */
static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
static void sha256(const uint8_t *d, size_t n, uint8_t out[32])
{
    static const uint32_t k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
    uint32_t h[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    uint64_t bits = (uint64_t)n * 8;
    size_t total = ((n + 8) / 64 + 1) * 64;
    uint8_t *m = calloc(total, 1);
    memcpy(m, d, n); m[n] = 0x80;
    for (int i = 0; i < 8; i++) m[total - 1 - i] = (uint8_t)(bits >> (8 * i));
    for (size_t off = 0; off < total; off += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = (uint32_t)m[off+4*i] << 24 | (uint32_t)m[off+4*i+1] << 16 |
                   (uint32_t)m[off+4*i+2] << 8 | m[off+4*i+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >> 3);
            uint32_t s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d2=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + k[i] + w[i];
            uint32_t S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
            uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + mj;
            hh=g; g=f; f=e; e=d2+t1; d2=c; c=b; b=a; a=t1+t2;
        }
        h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d2; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
    }
    free(m);
    for (int i = 0; i < 8; i++) {
        out[4*i] = (uint8_t)(h[i] >> 24); out[4*i+1] = (uint8_t)(h[i] >> 16);
        out[4*i+2] = (uint8_t)(h[i] >> 8); out[4*i+3] = (uint8_t)h[i];
    }
}

int main(int argc, char **argv)
{
    const char *outdir = argc > 1 ? argv[1] : "fixtures";
    char path[512];
    struct fixture fx[15];
    int n = 0;

#define ADD(fixture_name, fixture_desc, builder) do { \
        size_t len = builder; \
        fx[n].name = fixture_name; fx[n].desc = fixture_desc; \
        fx[n].data = malloc(len); \
        if (!fx[n].data) { perror("fixture allocation"); return 2; } \
        memcpy((void*)fx[n].data, buf, len); \
        fx[n].len = len; n++; \
    } while (0)

    ADD("cmd_open", "VIRTIO_MEDIA_CMD_OPEN", build_cmd_open());
    ADD("resp_open_ok", "OPEN success session_id=0x11223344", build_resp_open_ok());
    ADD("resp_open_refused", "OPEN positive host EMFILE (guest returns -EMFILE)", build_resp_open_refused());
    ADD("cmd_close", "VIRTIO_MEDIA_CMD_CLOSE session 0x11223344", build_cmd_close());
    ADD("cmd_ioctl_querycap", "VIDIOC_QUERYCAP nr=0 session 1", build_cmd_ioctl(0));
    ADD("cmd_ioctl_qbuf", "VIDIOC_QBUF nr=15 session 1", build_cmd_ioctl(15));
    ADD("payload_querycap_resp", "struct v4l2_capability", build_payload_querycap());
    ADD("payload_qbuf_out_mplane", "QBUF OUTPUT_MPLANE buf+1 plane", build_payload_qbuf_out_mplane());
    ADD("payload_reqbufs", "VIDIOC_REQBUFS OUTPUT_MPLANE", build_payload_reqbufs());
    ADD("cmd_mmap", "CMD_MMAP offset 0xA00000 RW", build_cmd_mmap());
    ADD("resp_mmap", "MMAP resp driver_addr=0x200000 len=0x10000", build_resp_mmap());
    ADD("cmd_munmap", "CMD_MUNMAP driver_addr=0x200000", build_cmd_munmap());
    ADD("evt_error", "EVT_ERROR errno=-EIO", build_evt_error());
    ADD("evt_dqbuf", "EVT_DQBUF capture buf 2", build_evt_dqbuf());
    ADD("evt_event_eos", "EVT_EVENT EOS", build_evt_event_eos());

    FILE *j = fopen((snprintf(path, sizeof(path), "%s/fixtures.json.next", outdir), path), "w");
    FILE *h = fopen((snprintf(path, sizeof(path), "%s/fixtures.h.next", outdir), path), "w");
    if (!j || !h) { perror("open fixtures.json.next/fixtures.h.next"); return 2; }
    fprintf(j, "{\n \"schemaVersion\": 2,\n \"generator\": \"scripts/gen_fixtures_c.c (structs from driver/protocol.h + pinned 6.12.107 UAPI)\",\n \"endianness\": \"little-endian, ARM64 LP64\",\n \"fixtures\": [\n");
    fprintf(h, "/* generated by gen_fixtures_c — do not edit */\n#ifndef FVM_FIXTURES_H\n#define FVM_FIXTURES_H\n#include <stddef.h>\n#include <stdint.h>\n");
    for (int i = 0; i < n; i++) {
        FILE *f;
        snprintf(path, sizeof(path), "%s/%s.bin.next", outdir, fx[i].name);
        if (!(f = fopen(path, "wb"))) { perror(path); return 2; }
        if (fwrite(fx[i].data, 1, fx[i].len, f) != fx[i].len) { perror("write"); return 2; }
        fclose(f);
        uint8_t dig[32]; char hex[65];
        sha256(fx[i].data, fx[i].len, dig);
        for (int b = 0; b < 32; b++) snprintf(hex + 2*b, 3, "%02x", dig[b]);
        fprintf(j, "  {\"name\": \"%s\", \"file\": \"%s.bin\", \"bytes\": %zu, \"sha256\": \"%s\", \"description\": \"%s\"}%s\n",
                fx[i].name, fx[i].name, fx[i].len, hex, fx[i].desc, i + 1 < n ? "," : "");
        fprintf(h, "static const uint8_t fvm_fixture_%s[] = {", fx[i].name);
        for (size_t b = 0; b < fx[i].len; b++) fprintf(h, "%s%u", b ? "," : "", ((const uint8_t*)fx[i].data)[b]);
        fprintf(h, "};\nstatic const size_t fvm_fixture_%s_len = sizeof(fvm_fixture_%s);\n", fx[i].name, fx[i].name);
        printf("%-28s %4zu bytes  sha256 %s\n", fx[i].name, fx[i].len, hex);
    }
    fprintf(j, " ]\n}\n");
    fprintf(h, "#endif\n");
    fclose(j); fclose(h);
    /* atomic-ish replace */
    for (int i = 0; i < n; i++) {
        char a[512], b2[512];
        snprintf(a, sizeof(a), "%s/%s.bin.next", outdir, fx[i].name);
        snprintf(b2, sizeof(b2), "%s/%s.bin", outdir, fx[i].name);
        if (rename(a, b2)) { perror("rename bin"); return 2; }
    }
    { char a[512], b2[512];
      snprintf(a, sizeof(a), "%s/fixtures.json.next", outdir);
      snprintf(b2, sizeof(b2), "%s/fixtures.json", outdir);
      if (rename(a, b2)) { perror("rename json"); return 2; }
      snprintf(a, sizeof(a), "%s/fixtures.h.next", outdir);
      snprintf(b2, sizeof(b2), "%s/fixtures.h", outdir);
      if (rename(a, b2)) { perror("rename h"); return 2; } }
    printf("gen_fixtures_c: wrote %d fixtures to %s (sizes from real protocol.h structs)\n", n, outdir);
    return 0;
}
