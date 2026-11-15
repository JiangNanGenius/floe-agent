/* SPDX-License-Identifier: MPL-2.0 */
/* Public ImageIO fallback for individual JPEG (MJPEG) video frames.
 *
 * This is deliberately not a VideoToolbox codec session. It exists only for
 * the MJPEG slot when the caller selects the explicit native-software policy
 * (FLV_ALLOW_NATIVE_SOFTWARE) and did not require hardware. Outputs are
 * always classified native software (hardware_used == 0).
 *
 * The path is bounded and stateless:
 *  - dimensions are validated by the caller (<= 8192, even for NV12);
 *  - inputs are copied into host-owned CVPixelBuffers before ImageIO sees
 *    them; no caller pointer is retained;
 *  - JPEG decode uses CGImageSource + CoreGraphics + a public
 *    VTPixelTransferSession into NV12 (no private API);
 *  - JPEG encode converts NV12 to BGRA with the same public transfer and
 *    writes one JPEG image (no container).
 *
 * Colour: the ABI carries no primaries/transfer/matrix metadata for a raw
 * frame. This helper therefore does not invent one: the JPEG has no ICC
 * profile beyond CoreGraphics' sRGB RGB model, and the decoded NV12 is the
 * transfer session's default conversion. Clients must treat it as generic
 * NV12, not a colour-managed pipeline.
 */
#ifndef FLV_IMAGEIO_FALLBACK_H
#define FLV_IMAGEIO_FALLBACK_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One real 640x360 encode + decode probe on this machine. Returns 0 on
 * success and reports the measured dimensions; nonzero when ImageIO/JPEG is
 * unavailable. Cached per process. This proves a software path, never
 * hardware. */
int flv_imageio_probe(uint32_t *width_out, uint32_t *height_out);

/* Encode one NV12 frame (tight or strided planes) to a single JPEG image.
 * On success *out is malloc'd and must be freed by the caller. */
int flv_imageio_encode_nv12(const uint8_t *y, uint32_t y_stride,
                            const uint8_t *uv, uint32_t uv_stride,
                            uint32_t width, uint32_t height,
                            uint8_t **out, size_t *out_bytes);

/* Decode one JPEG image to a contiguous NV12 frame (Y then interleaved UV,
 * no row padding). The caller's expected dimensions, when nonzero, must
 * match the decoded image. On success *out is malloc'd. */
int flv_imageio_decode_jpeg(const uint8_t *jpeg, size_t bytes,
                            uint32_t expected_width, uint32_t expected_height,
                            uint8_t **out, size_t *out_bytes,
                            uint32_t *width_out, uint32_t *height_out);

#ifdef __cplusplus
}
#endif
#endif /* FLV_IMAGEIO_FALLBACK_H */
