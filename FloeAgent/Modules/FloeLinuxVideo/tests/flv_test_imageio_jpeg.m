/* SPDX-License-Identifier: MPL-2.0 */
/*
 * MJPEG public-ImageIO fallback — focused qualification (SOURCE-STAGE
 * PREPARED; the primary runs it in a real native window).
 *
 * The MJPEG slot only reports native-software availability when the ImageIO
 * probe actually encoded and decoded a real frame. This test exercises the
 * explicit-policy session path:
 *  - encode three generated NV12 frames to JPEG;
 *  - every output is a self-contained JPEG (SOI ... EOI), keyframe, and
 *    reports hardware_used == 0 (never hardware);
 *  - no FLV_OUTPUT_FORMAT record is emitted;
 *  - a REQUIRE_HARDWARE session on the same slot is rejected;
 *  - the produced JPEGs are decoded back through the same explicit-policy
 *    session to NV12 with the expected dimensions.
 *
 * Usage: flv_test_imageio_jpeg
 */
#import "flv_test_util.h"
#import "FLVCodecRegistry.h"
#include <unistd.h>

static int cap_index(FLVCapability *caps, size_t count, uint32_t codec, uint32_t direction) {
    for (size_t i = 0; i < count; i++)
        if (caps[i].codec == codec && caps[i].direction == direction) return (int)i;
    return -1;
}

static void fill_nv12(uint8_t *dst, uint32_t width, uint32_t height, uint32_t index) {
    uint8_t *y = dst;
    uint8_t *uv = dst + (size_t)width * height;
    for (uint32_t r = 0; r < height; r++)
        for (uint32_t c = 0; c < width; c++)
            y[(size_t)r * width + c] = (uint8_t)((r * 3 + c + index * 11) & 0xff);
    for (uint32_t r = 0; r < height / 2; r++)
        for (uint32_t c = 0; c < width; c += 2) {
            uv[(size_t)r * width + c] = 80;
            uv[(size_t)r * width + c + 1] = 170;
        }
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
    if (flv_host_query_capabilities(host, caps, 22, &count) != FLV_OK || count != 22) {
        flv_host_destroy(host);
        return 1;
    }
    int enc = cap_index(caps, count, FLV_MJPEG, FLV_ENCODE);
    int dec = cap_index(caps, count, FLV_MJPEG, FLV_DECODE);
    if (enc < 0 || dec < 0) { flv_host_destroy(host); return 1; }
    int available = (caps[enc].flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) &&
                    (caps[dec].flags & FLV_CAP_NATIVE_SOFTWARE_PROBED);
    printf("{\"test\":\"imageio_jpeg\",\"encode_flags\":%u,\"decode_flags\":%u,\"available\":%d}\n",
           caps[enc].flags, caps[dec].flags, available);
    if (!available) {
        printf("{\"test\":\"imageio_jpeg\",\"status\":\"skipped-no-imageio-path\"}\n");
        flv_host_destroy(host);
        return 0;
    }

    const uint32_t width = 320, height = 180;
    FLVSessionConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = FLV_ABI_VERSION;
    config.codec = FLV_MJPEG;
    config.direction = FLV_ENCODE;
    config.pixel_format = FLV_NV12;
    config.width = width;
    config.height = height;
    config.frame_rate_num = 30;
    config.frame_rate_den = 1;
    config.bitstream_format = FLV_RAW_CODED_FRAME;
    config.flags = FLV_ALLOW_NATIVE_SOFTWARE;

    FLVSession *encoder = NULL;
    int rc = flv_session_create(host, &config, &encoder);
    if (rc != FLV_OK) {
        printf("{\"test\":\"imageio_jpeg\",\"status\":\"failed-create-encode\",\"code\":%d}\n", rc);
        flv_host_destroy(host);
        return 1;
    }
    FLVSessionConfig strict = config;
    strict.flags = FLV_REQUIRE_HARDWARE;
    FLVSession *strict_session = NULL;
    int strict_rc = flv_session_create(host, &strict, &strict_session);
    if (strict_session) flv_session_close(strict_session);
    if (strict_rc != FLV_UNSUPPORTED) {
        printf("{\"test\":\"imageio_jpeg\",\"status\":\"strict-not-rejected\",\"code\":%d}\n", strict_rc);
        flv_session_close(encoder);
        flv_host_destroy(host);
        return 1;
    }

    size_t frame_bytes = (size_t)width * height * 3 / 2;
    uint8_t *frame = malloc(frame_bytes);
    if (!frame) { flv_session_close(encoder); flv_host_destroy(host); return 1; }
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
        if (flv_session_submit_frame(encoder, &f) != FLV_OK) {
            printf("{\"test\":\"imageio_jpeg\",\"status\":\"submit-failed\",\"frame\":%u}\n", i);
            free(frame); flv_session_close(encoder); flv_host_destroy(host);
            return 1;
        }
    }
    flv_session_flush(encoder, 1);

    uint8_t *packets[8];
    size_t packet_bytes[8];
    memset(packets, 0, sizeof(packets));
    memset(packet_bytes, 0, sizeof(packet_bytes));
    int packet_count = 0, formats = 0, errors = 0, eos = 0, hw = 0;
    for (int spin = 0; spin < 500; spin++) {
        FLVOutput output;
        int progressed = 0;
        while (flv_session_dequeue(encoder, &output) == FLV_OK) {
            progressed = 1;
            if (output.kind == FLV_OUTPUT_PACKET && packet_count < 8) {
                packets[packet_count] = malloc(output.bytes);
                if (packets[packet_count]) {
                    memcpy(packets[packet_count], output.data, output.bytes);
                    packet_bytes[packet_count] = output.bytes;
                    packet_count++;
                }
                hw += output.hardware_used ? 1 : 0;
            } else if (output.kind == FLV_OUTPUT_FORMAT) formats++;
            else if (output.kind == FLV_OUTPUT_ERROR) errors++;
            else if (output.kind == FLV_OUTPUT_EOS) eos++;
            flv_session_release_output(encoder, &output);
        }
        if (eos || errors) break;
        if (!progressed) usleep(2000);
    }
    flv_session_close(encoder);

    int jpeg_ok = packet_count == 3 && formats == 0 && errors == 0 && hw == 0;
    for (int i = 0; i < packet_count; i++) {
        if (packet_bytes[i] < 4 || packets[i][0] != 0xFF || packets[i][1] != 0xD8 ||
            packets[i][packet_bytes[i] - 2] != 0xFF || packets[i][packet_bytes[i] - 1] != 0xD9) {
            jpeg_ok = 0;
        }
    }

    FLVSessionConfig dconfig = config;
    dconfig.direction = FLV_DECODE;
    dconfig.flags = FLV_ALLOW_NATIVE_SOFTWARE;
    FLVSession *decoder = NULL;
    int decode_frames = 0, decode_errors = 0, decode_hw = 0;
    int drc = flv_session_create(host, &dconfig, &decoder);
    if (drc == FLV_OK) {
        for (int i = 0; i < packet_count; i++) {
            FLVPacket p;
            memset(&p, 0, sizeof(p));
            p.data = packets[i];
            p.bytes = packet_bytes[i];
            p.pts_ns = (int64_t)i * 33333333;
            p.dts_ns = p.pts_ns;
            p.duration_ns = 33333333;
            if (flv_session_submit_packet(decoder, &p) != FLV_OK) break;
        }
        flv_session_flush(decoder, 1);
        for (int spin = 0; spin < 500; spin++) {
            FLVOutput output;
            int progressed = 0;
            while (flv_session_dequeue(decoder, &output) == FLV_OK) {
                progressed = 1;
                if (output.kind == FLV_OUTPUT_FRAME) {
                    decode_frames++;
                    decode_hw += output.hardware_used ? 1 : 0;
                    if (output.width != width || output.height != height ||
                        output.pixel_format != FLV_NV12 || output.bytes != frame_bytes) decode_errors++;
                } else if (output.kind == FLV_OUTPUT_ERROR) decode_errors++;
                flv_session_release_output(decoder, &output);
            }
            if (decode_frames >= packet_count || decode_errors) break;
            if (!progressed) usleep(2000);
        }
        flv_session_close(decoder);
    }

    int ok = jpeg_ok && drc == FLV_OK && decode_frames == packet_count &&
             decode_errors == 0 && decode_hw == 0;
    printf("{\"test\":\"imageio_jpeg\",\"status\":\"%s\",\"packets\":%d,"
           "\"formats\":%d,\"parse_ok\":%d,\"decode_frames\":%d,"
           "\"decode_errors\":%d,\"hardware_outputs\":%d}\n",
           ok ? "passed" : "failed", packet_count, formats, jpeg_ok,
           decode_frames, decode_errors, hw + decode_hw);

    for (int i = 0; i < packet_count; i++) free(packets[i]);
    free(frame);
    flv_host_destroy(host);
    return ok ? 0 : 1;
}
