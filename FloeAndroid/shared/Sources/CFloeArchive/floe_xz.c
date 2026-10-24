/*
 * CFloeArchive — narrow streaming shim over the pinned vendored liblzma
 * 5.8.1 (XZ Utils; 0BSD). See include/CFloeArchive.h "xz addendum" for the
 * contract; it is deliberately the same shape as floe_bzip2.c so the Swift
 * codec wrapper treats both formats through one pattern:
 *
 * * One decoder instance owns exactly one liblzma `lzma_stream` decoding one
 *   `.xz` member (LZMA_CONCATENATED is NOT set: like the Apple
 *   Compression/LZMA path and liblzma's own single-stream mode, the decoder
 *   stops at the member boundary and `*consumed` is byte-exact through the
 *   `avail_in` delta, so `VerifiedXZSource` starts a fresh decoder for the
 *   next concatenated member and rejects trailing garbage as corrupt).
 * * The stream's integrity check is validated by liblzma itself; an unknown
 *   or unsupported filter chain / check method is a permanent
 *   FLOE_XZ_ERROR / FLOE_XZ_MEMORY outcome, never a silent skip.
 * * Lifecycle: `initialized` tracks the liblzma state that `lzma_end` is owed
 *   exactly once. A successful stream end releases it immediately (like the
 *   bzip2 shim's BZ_STREAM_END transition); every other path releases in
 *   `*_destroy`; neither path can double-release or leak.
 * * Caller buffers are detached after every call (`next_in/next_out = NULL`,
 *   capacities 0) so no pointer into Swift-owned memory can outlive the call.
 * * No allocation happens per call; liblzma's working state is created once
 *   in `*_create` (bounded by the stream's own dictionary declaration,
 *   subject to liblzma's memory accounting, which maps failures to
 *   LZMA_MEM_ERROR / LZMA_MEMLIMIT_ERROR below).
 */

#include "../include/CFloeArchive.h"

#include <stdlib.h>

#if defined(__has_include)
#if __has_include(<lzma.h>)
#include <lzma.h>
#else
/* SwiftPM CLzma target exposes src/liblzma/api as its public header dir;
 * keep a quoted fallback so the shim also compiles in ad-hoc verification
 * drivers that only add the vendored tree to the include path. */
#include "lzma.h"
#endif
#else
#include "lzma.h"
#endif

/* ---- decoder ------------------------------------------------------------ */

struct floe_xz_decoder {
    lzma_stream stream;
    /* liblzma state is allocated: `lzma_end` is owed exactly once. */
    int initialized;
    /* LZMA_STREAM_END was returned; no further processing is allowed. */
    int finished;
};

static void floe_xz_decoder_release(floe_xz_decoder *decoder) {
    if (decoder->initialized) {
        lzma_end(&decoder->stream);
        decoder->initialized = 0;
    }
}

floe_xz_decoder *floe_xz_decoder_create(void) {
    floe_xz_decoder *decoder = (floe_xz_decoder *)calloc(1, sizeof(floe_xz_decoder));
    if (decoder == NULL) {
        return NULL;
    }
    decoder->stream = (lzma_stream)LZMA_STREAM_INIT;
    /* memlimit UINT64_MAX: liblzma's own accounting decides; its allocation
     * failures surface as LZMA_MEM_ERROR → FLOE_XZ_MEMORY. flags 0 keeps the
     * single-member semantics described above. */
    if (lzma_stream_decoder(&decoder->stream, UINT64_MAX, 0) != LZMA_OK) {
        free(decoder);
        return NULL;
    }
    decoder->initialized = 1;
    return decoder;
}

void floe_xz_decoder_destroy(floe_xz_decoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    floe_xz_decoder_release(decoder);
    free(decoder);
}

/* Test/diagnostic accessor; the handle must still be alive. */
int floe_xz_decoder_state_active(const floe_xz_decoder *decoder) {
    if (decoder == NULL) {
        return 0;
    }
    return decoder->initialized ? 1 : 0;
}

int floe_xz_decoder_process(floe_xz_decoder *decoder,
                            const uint8_t *src, size_t src_len,
                            uint8_t *dst, size_t dst_capacity,
                            size_t *consumed, size_t *produced) {
    if (consumed != NULL) {
        *consumed = 0;
    }
    if (produced != NULL) {
        *produced = 0;
    }
    if (decoder == NULL || !decoder->initialized || decoder->finished) {
        return FLOE_XZ_PARAM;
    }
    if (src_len > 0xFFFFFFFFu || dst_capacity == 0 || dst_capacity > 0xFFFFFFFFu) {
        return FLOE_XZ_PARAM;
    }
    if ((src_len > 0 && src == NULL) || dst == NULL) {
        return FLOE_XZ_PARAM;
    }

    decoder->stream.next_in = (const uint8_t *)src;
    decoder->stream.avail_in = (size_t)src_len;
    decoder->stream.next_out = dst;
    decoder->stream.avail_out = (size_t)dst_capacity;

    lzma_ret rc = lzma_code(&decoder->stream, LZMA_RUN);

    size_t used = src_len - decoder->stream.avail_in;
    size_t made = dst_capacity - decoder->stream.avail_out;
    if (consumed != NULL) {
        *consumed = used;
    }
    if (produced != NULL) {
        *produced = made;
    }

    /* Detach caller memory before returning. */
    decoder->stream.next_in = NULL;
    decoder->stream.avail_in = 0;
    decoder->stream.next_out = NULL;
    decoder->stream.avail_out = 0;

    switch (rc) {
        case LZMA_OK:
            return FLOE_XZ_OK;
        case LZMA_STREAM_END:
            /* Terminal success: release the decoder state now instead of
             * holding it until the caller destroys the handle. */
            decoder->finished = 1;
            floe_xz_decoder_release(decoder);
            return FLOE_XZ_STREAM_END;
        case LZMA_MEM_ERROR:
        case LZMA_MEMLIMIT_ERROR:
            return FLOE_XZ_MEMORY;
        case LZMA_DATA_ERROR:
        case LZMA_FORMAT_ERROR:
        case LZMA_BUF_ERROR:
        case LZMA_OPTIONS_ERROR:
            /* Corrupt/truncated/unsupported-filter/permanent failures: all
             * data-level refusals from the caller's point of view, matching
             * the Apple compression_stream ERROR mapping. */
            return FLOE_XZ_ERROR;
        default:
            /* LZMA_UNSUPPORTED_CHECK / LZMA_NO_CHECK / programming errors
             * stay honest errors, never false success. */
            return FLOE_XZ_ERROR;
    }
}

/* ---- encoder ------------------------------------------------------------ */

struct floe_xz_encoder {
    lzma_stream stream;
    int initialized;
    int finished;
};

static void floe_xz_encoder_release(floe_xz_encoder *encoder) {
    if (encoder->initialized) {
        lzma_end(&encoder->stream);
        encoder->initialized = 0;
    }
}

floe_xz_encoder *floe_xz_encoder_create(int preset) {
    if (preset < -1 || preset > 9) {
        return NULL;
    }
    floe_xz_encoder *encoder = (floe_xz_encoder *)calloc(1, sizeof(floe_xz_encoder));
    if (encoder == NULL) {
        return NULL;
    }
    encoder->stream = (lzma_stream)LZMA_STREAM_INIT;
    lzma_options_lzma options;
    if (lzma_lzma_preset(&options, preset < 0 ? LZMA_PRESET_DEFAULT : (uint32_t)preset) != 0) {
        free(encoder);
        return NULL;
    }
    /* Plain `.xz` container with the standard single LZMA2 filter chain and
     * the CRC64 integrity check (the check `xz`/liblzma/Python `lzma` all
     * verify by default), matching the original "complete liblzma-compatible
     * .xz stream" contract. */
    lzma_filter filters[2];
    filters[0].id = LZMA_FILTER_LZMA2;
    filters[0].options = &options;
    filters[1].id = LZMA_VLI_UNKNOWN;
    filters[1].options = NULL;
    if (lzma_stream_encoder(&encoder->stream, filters, LZMA_CHECK_CRC64) != LZMA_OK) {
        free(encoder);
        return NULL;
    }
    encoder->initialized = 1;
    return encoder;
}

void floe_xz_encoder_destroy(floe_xz_encoder *encoder) {
    if (encoder == NULL) {
        return;
    }
    floe_xz_encoder_release(encoder);
    free(encoder);
}

int floe_xz_encoder_state_active(const floe_xz_encoder *encoder) {
    if (encoder == NULL) {
        return 0;
    }
    return encoder->initialized ? 1 : 0;
}

int floe_xz_encoder_process(floe_xz_encoder *encoder,
                            const uint8_t *src, size_t src_len,
                            uint8_t *dst, size_t dst_capacity,
                            int finish,
                            size_t *consumed, size_t *produced) {
    if (consumed != NULL) {
        *consumed = 0;
    }
    if (produced != NULL) {
        *produced = 0;
    }
    if (encoder == NULL || !encoder->initialized || encoder->finished) {
        return FLOE_XZ_PARAM;
    }
    if (src_len > 0xFFFFFFFFu || dst_capacity == 0 || dst_capacity > 0xFFFFFFFFu) {
        return FLOE_XZ_PARAM;
    }
    if ((src_len > 0 && src == NULL) || dst == NULL) {
        return FLOE_XZ_PARAM;
    }

    encoder->stream.next_in = (const uint8_t *)src;
    encoder->stream.avail_in = (size_t)src_len;
    encoder->stream.next_out = dst;
    encoder->stream.avail_out = (size_t)dst_capacity;

    lzma_ret rc = lzma_code(&encoder->stream, finish ? LZMA_FINISH : LZMA_RUN);

    size_t used = src_len - encoder->stream.avail_in;
    size_t made = dst_capacity - encoder->stream.avail_out;
    if (consumed != NULL) {
        *consumed = used;
    }
    if (produced != NULL) {
        *produced = made;
    }

    /* Detach caller memory before returning. */
    encoder->stream.next_in = NULL;
    encoder->stream.avail_in = 0;
    encoder->stream.next_out = NULL;
    encoder->stream.avail_out = 0;

    switch (rc) {
        case LZMA_OK:
            return FLOE_XZ_OK;
        case LZMA_STREAM_END:
            /* Only reachable in finish mode; terminal success. */
            encoder->finished = 1;
            floe_xz_encoder_release(encoder);
            return FLOE_XZ_FINISHED;
        case LZMA_MEM_ERROR:
        case LZMA_MEMLIMIT_ERROR:
            return FLOE_XZ_MEMORY;
        case LZMA_DATA_ERROR:
        case LZMA_BUF_ERROR:
        case LZMA_OPTIONS_ERROR:
        case LZMA_FORMAT_ERROR:
        case LZMA_PROG_ERROR:
        default:
            return FLOE_XZ_ERROR;
    }
}
