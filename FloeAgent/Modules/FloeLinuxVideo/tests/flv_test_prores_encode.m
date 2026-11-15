/* SPDX-License-Identifier: MPL-2.0 */
/*
 * ProRes 422 / 4444 encode — focused qualification (SOURCE-STAGE PREPARED,
 * not executed by this candidate; the primary runs it in a native window).
 *
 * Public-VideoToolbox only. The test proves what the machine actually did:
 *  - capability flags for both ProRes encode slots are reported truthfully;
 *  - a real compression session encodes three NV12 frames when the slot is
 *    advertised as hardware or proven native software;
 *  - every coded packet is a raw ProRes frame (big-endian frame size then
 *    the 'icpf' frame header), and no avcC/hvcC-style FLV_OUTPUT_FORMAT is
 *    emitted for ProRes (its coded format is self-contained);
 *  - FLV_REQUIRE_HARDWARE is strict: a software-only slot must reject it;
 *  - the coded packets are fed back through a ProRes decode session when the
 *    decode slot is advertised, and the decoded frame count is reported.
 *
 * This does NOT claim alpha or 12-bit preservation for 4444: NV12/P010
 * input is upsampled by VideoToolbox and the output is opaque. A source
 * frame with alpha would need a BGRA/4444 data path that is not implemented
 * here.
 *
 * Usage: flv_test_prores_encode
 * Exit 0: every advertised path behaved as advertised (unsupported slots are
 *         reported as skipped-unavailable, never as a pass of encode).
 */
#import "flv_test_util.h"
#import "FLVCodecRegistry.h"
#include <unistd.h>

static int find_cap(FLVCapability *caps, size_t count, uint32_t codec, uint32_t direction) {
    for (size_t i = 0; i < count; i++)
        if (caps[i].codec == codec && caps[i].direction == direction) return (int)i;
    return -1;
}

static void fill_nv12(uint8_t *dst, uint32_t width, uint32_t height, uint32_t frame_index) {
    uint8_t *y = dst;
    uint8_t *uv = dst + (size_t)width * height;
    for (uint32_t row = 0; row < height; row++)
        for (uint32_t col = 0; col < width; col++)
            y[(size_t)row * width + col] = (uint8_t)((row + col + frame_index * 7) & 0xff);
    for (uint32_t row = 0; row < height / 2; row++)
        for (uint32_t col = 0; col < width; col += 2) {
            uv[(size_t)row * width + col] = 96;
            uv[(size_t)row * width + col + 1] = 160;
        }
}

typedef struct {
    uint8_t *data;
    size_t bytes;
    uint32_t hardware_used;
    int keyframe;
} CodedPacket;

static int collect_packets(FLVSession *session, CodedPacket *packets, int capacity,
                           int *format_events, int *hardware_seen, int *software_seen,
                           int *errors_seen, int *eos_seen) {
    int count = 0;
    for (int spin = 0; spin < 1000; spin++) {
        FLVOutput output;
        int progressed = 0;
        while (flv_session_dequeue(session, &output) == FLV_OK) {
            progressed = 1;
            if (output.kind == FLV_OUTPUT_FORMAT) {
                (*format_events)++;
            } else if (output.kind == FLV_OUTPUT_PACKET) {
                if (count < capacity && output.data && output.bytes) {
                    packets[count].data = malloc(output.bytes);
                    if (!packets[count].data) {
                        flv_session_release_output(session, &output);
                        return -1;
                    }
                    memcpy(packets[count].data, output.data, output.bytes);
                    packets[count].bytes = output.bytes;
                    packets[count].hardware_used = output.hardware_used;
                    packets[count].keyframe = (output.flags & FLV_KEYFRAME) != 0;
                    count++;
                }
                if (output.hardware_used) (*hardware_seen)++;
                else (*software_seen)++;
            } else if (output.kind == FLV_OUTPUT_EOS) {
                (*eos_seen)++;
            } else if (output.kind == FLV_OUTPUT_ERROR) {
                (*errors_seen)++;
            }
            flv_session_release_output(session, &output);
        }
        if ((*eos_seen) || (*errors_seen)) break;
        if (!progressed) usleep(2000);
    }
    return count;
}

static int run_one(uint32_t codec, const char *name, FLVCapability *caps, size_t cap_count) {
    int cap_index = find_cap(caps, cap_count, codec, FLV_ENCODE);
    if (cap_index < 0) {
        printf("{\"codec\":\"%s\",\"encode\":\"skipped-missing-capability\"}\n", name);
        return 0;
    }
    FLVCapability cap = caps[cap_index];
    int advertised_hw = (cap.flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)) != 0;
    int advertised_sw = (cap.flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) != 0;
    if (cap.flags == 0) {
        printf("{\"codec\":\"%s\",\"encode\":\"skipped-unavailable\",\"flags\":0}\n", name);
        return 0;
    }
    if (!advertised_hw && !advertised_sw) {
        printf("{\"codec\":\"%s\",\"encode\":\"skipped-unproven\",\"flags\":%u,\"probe_status\":%d}\n",
               name, cap.flags, cap.probe_status);
        return 0;
    }

    FLVTestNotifyState notify;
    memset(&notify, 0, sizeof(notify));
    FLVHost *host = NULL;
    if (flv_test_make_host(&host, 4, 8, &notify) != FLV_OK) return 1;

    const uint32_t width = 640, height = 360;
    FLVSessionConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = FLV_ABI_VERSION;
    config.codec = codec;
    config.direction = FLV_ENCODE;
    config.pixel_format = FLV_NV12;
    config.width = width;
    config.height = height;
    config.frame_rate_num = 30;
    config.frame_rate_den = 1;
    config.bitrate = 10 * 1000 * 1000;
    config.bitstream_format = FLV_RAW_CODED_FRAME;
    config.flags = advertised_hw ? FLV_REQUIRE_HARDWARE : FLV_LOW_LATENCY;

    FLVSession *encoder = NULL;
    int rc = flv_session_create(host, &config, &encoder);
    if (rc != FLV_OK) {
        printf("{\"codec\":\"%s\",\"encode\":\"failed-create\",\"status\":%d,\"flags\":%u}\n",
               name, rc, cap.flags);
        flv_host_destroy(host);
        return 1;
    }

    size_t frame_bytes = (size_t)width * height * 3 / 2;
    uint8_t *frame = malloc(frame_bytes);
    if (!frame) { flv_session_close(encoder); flv_host_destroy(host); return 1; }
    int submitted = 0;
    for (uint32_t i = 0; i < 3; i++) {
        fill_nv12(frame, width, height, i);
        FLVFrame f;
        memset(&f, 0, sizeof(f));
        f.data = frame;
        f.bytes = frame_bytes;
        f.width = width;
        f.height = height;
        f.pixel_format = FLV_NV12;
        f.plane_count = 2;
        f.plane_offsets[1] = (uint64_t)width * height;
        f.plane_bytes[0] = (uint64_t)width * height;
        f.plane_bytes[1] = (uint64_t)width * height / 2;
        f.plane_strides[0] = width;
        f.plane_strides[1] = width;
        f.pts_ns = (int64_t)i * 33333333;
        f.duration_ns = 33333333;
        f.flags = i == 0 ? FLV_KEYFRAME : 0;
        rc = flv_session_submit_frame(encoder, &f);
        if (rc != FLV_OK) break;
        submitted++;
    }
    int flush_rc = flv_session_flush(encoder, 1);
    CodedPacket packets[16];
    memset(packets, 0, sizeof(packets));
    int formats = 0, hw_outputs = 0, sw_outputs = 0, errors = 0, eos = 0;
    int count = collect_packets(encoder, packets, 16, &formats, &hw_outputs, &sw_outputs,
                                &errors, &eos);

    int header_ok = 1;
    for (int i = 0; i < count; i++) {
        if (packets[i].bytes < 8) { header_ok = 0; break; }
        uint32_t declared = ((uint32_t)packets[i].data[0] << 24) |
                            ((uint32_t)packets[i].data[1] << 16) |
                            ((uint32_t)packets[i].data[2] << 8) |
                            (uint32_t)packets[i].data[3];
        if (packets[i].data[4] != 'i' || packets[i].data[5] != 'c' ||
            packets[i].data[6] != 'p' || packets[i].data[7] != 'f' ||
            declared < 8 || (uint64_t)declared > (uint64_t)packets[i].bytes) {
            header_ok = 0;
            break;
        }
    }
    int hardware_truth = advertised_hw ? (hw_outputs > 0 && sw_outputs == 0)
                                       : (sw_outputs > 0 && hw_outputs == 0);
    int packet_count_ok = count >= 3;
    int format_ok = formats == 0; /* ProRes coded frames are self-contained. */
    int ok = submitted == 3 && flush_rc == FLV_OK && packet_count_ok && header_ok &&
             format_ok && hardware_truth && errors == 0 && eos >= 1;

    /* Strictness: a software-only slot must reject REQUIRE_HARDWARE. */
    int strict_rejected = -1;
    if (!advertised_hw) {
        FLVSessionConfig strict = config;
        strict.flags = FLV_REQUIRE_HARDWARE;
        FLVSession *probe = NULL;
        int strict_rc = flv_session_create(host, &strict, &probe);
        strict_rejected = (strict_rc == FLV_UNSUPPORTED);
        if (probe) flv_session_close(probe);
        ok = ok && strict_rejected;
    }

    /* Decode readback of the produced raw frames. */
    int decode_frames = -1, decode_cap_flags = 0;
    int decode_index = find_cap(caps, cap_count, codec, FLV_DECODE);
    if (decode_index >= 0 && count > 0) {
        FLVCapability dc = caps[decode_index];
        decode_cap_flags = (int)dc.flags;
        if (dc.flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED | FLV_CAP_NATIVE_SOFTWARE_PROBED)) {
            FLVSessionConfig dconfig;
            memset(&dconfig, 0, sizeof(dconfig));
            dconfig.abi_version = FLV_ABI_VERSION;
            dconfig.codec = codec;
            dconfig.direction = FLV_DECODE;
            dconfig.pixel_format = FLV_NV12;
            dconfig.width = width;
            dconfig.height = height;
            dconfig.frame_rate_num = 30;
            dconfig.frame_rate_den = 1;
            dconfig.bitstream_format = FLV_RAW_CODED_FRAME;
            dconfig.flags = (dc.flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) && !(dc.flags & FLV_CAP_HW_REPORTED)
                            ? FLV_LOW_LATENCY : FLV_REQUIRE_HARDWARE;
            FLVSession *decoder = NULL;
            int drc = flv_session_create(host, &dconfig, &decoder);
            if (drc == FLV_OK) {
                int decode_errors = 0, decode_eos = 0, dhw = 0, dsw = 0, dformats = 0;
                decode_frames = 0;
                for (int i = 0; i < count; i++) {
                    FLVPacket p;
                    memset(&p, 0, sizeof(p));
                    p.data = packets[i].data;
                    p.bytes = packets[i].bytes;
                    p.pts_ns = (int64_t)i * 33333333;
                    p.dts_ns = p.pts_ns;
                    p.duration_ns = 33333333;
                    p.flags = packets[i].keyframe ? FLV_KEYFRAME : 0;
                    if (flv_session_submit_packet(decoder, &p) != FLV_OK) break;
                }
                flv_session_flush(decoder, 1);
                for (int spin = 0; spin < 1000; spin++) {
                    FLVOutput o;
                    int progressed = 0;
                    while (flv_session_dequeue(decoder, &o) == FLV_OK) {
                        progressed = 1;
                        if (o.kind == FLV_OUTPUT_FRAME) {
                            decode_frames++;
                            if (o.hardware_used) dhw++; else dsw++;
                        } else if (o.kind == FLV_OUTPUT_EOS) decode_eos++;
                        else if (o.kind == FLV_OUTPUT_ERROR) decode_errors++;
                        else if (o.kind == FLV_OUTPUT_FORMAT) dformats++;
                        flv_session_release_output(decoder, &o);
                    }
                    if (decode_eos || decode_errors) break;
                    if (!progressed) usleep(2000);
                }
                if (decode_frames < 3 || decode_errors) ok = 0;
                if ((dc.flags & FLV_CAP_HW_REPORTED) && dsw > 0) ok = 0;
                if ((dc.flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) && !(dc.flags & FLV_CAP_HW_REPORTED) && dhw > 0) ok = 0;
                flv_session_close(decoder);
                printf("{\"codec\":\"%s\",\"decode_frames\":%d,\"decode_hw_frames\":%d,"
                       "\"decode_sw_frames\":%d,\"decode_cap_flags\":%d}\n",
                       name, decode_frames, dhw, dsw, decode_cap_flags);
            }
        }
    }

    printf("{\"codec\":\"%s\",\"encode\":\"%s\",\"submitted\":%d,\"packets\":%d,"
           "\"frame_header_ok\":%d,\"format_events\":%d,\"eos\":%d,"
           "\"hardware_outputs\":%d,\"software_outputs\":%d,\"strict_rejected\":%d,"
           "\"cap_flags\":%u,\"max\":[%u,%u]}\n",
           name, ok ? "passed" : "failed", submitted, count, header_ok, formats, eos,
           hw_outputs, sw_outputs, strict_rejected, cap.flags, cap.max_width, cap.max_height);

    for (int i = 0; i < count; i++) free(packets[i].data);
    free(frame);
    flv_session_close(encoder);
    flv_host_destroy(host);
    return ok ? 0 : 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    FLVTestNotifyState notify;
    memset(&notify, 0, sizeof(notify));
    FLVHost *host = NULL;
    if (flv_test_make_host(&host, 4, 8, &notify) != FLV_OK) return 1;
    FLVCapability caps[22];
    memset(caps, 0, sizeof(caps));
    size_t count = 0;
    int rc = flv_host_query_capabilities(host, caps, 22, &count);
    flv_host_destroy(host);
    if (rc != FLV_OK || count != 22) return 1;

    int failures = 0;
    failures += run_one(FLV_PRORES422, "prores422", caps, count);
    failures += run_one(FLV_PRORES4444, "prores4444", caps, count);
    printf("{\"test\":\"prores_encode\",\"failures\":%d}\n", failures);
    return failures ? 1 : 0;
}
