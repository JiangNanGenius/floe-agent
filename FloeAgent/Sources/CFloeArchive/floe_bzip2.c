/*
 * CFloeArchive — narrow streaming shim over the platform's libbz2.
 * See include/CFloeArchive.h for the contract. Implementation notes:
 *
 * * One decoder instance owns exactly one libbz2 `bz_stream`; the caller
 *   destroys and re-creates it at member boundaries. `*consumed` is derived
 *   from the `avail_in` delta, which libbz2 updates byte-exactly, so the byte
 *   after a member is the first byte of the next member.
 * * Caller buffers are detached after every call (`next_in/next_out = NULL`,
 *   capacities 0) so no pointer into Swift-owned memory can outlive the call.
 * * No allocation happens per call; libbz2's working state is created once in
 *   `*_create` and is bounded by the stream's declared block size (<= 900k
 *   for bzip2), never by the archive's expanded size.
 */

#include "../include/CFloeArchive.h"
#include "bzlib.h"

#include <stdlib.h>

/* ---- decoder ------------------------------------------------------------ */

struct floe_bz2_decoder {
    bz_stream stream;
    int active;
};

floe_bz2_decoder *floe_bz2_decoder_create(void) {
    floe_bz2_decoder *decoder = (floe_bz2_decoder *)calloc(1, sizeof(floe_bz2_decoder));
    if (decoder == NULL) {
        return NULL;
    }
    /* verbosity 0; small == 0 keeps the faster full-size tables. */
    if (BZ2_bzDecompressInit(&decoder->stream, 0, 0) != BZ_OK) {
        free(decoder);
        return NULL;
    }
    decoder->active = 1;
    return decoder;
}

void floe_bz2_decoder_destroy(floe_bz2_decoder *decoder) {
    if (decoder == NULL) {
        return;
    }
    if (decoder->active) {
        BZ2_bzDecompressEnd(&decoder->stream);
        decoder->active = 0;
    }
    free(decoder);
}

int floe_bz2_decoder_process(floe_bz2_decoder *decoder,
                             const uint8_t *src, size_t src_len,
                             uint8_t *dst, size_t dst_capacity,
                             size_t *consumed, size_t *produced) {
    if (consumed != NULL) {
        *consumed = 0;
    }
    if (produced != NULL) {
        *produced = 0;
    }
    if (decoder == NULL || !decoder->active) {
        return FLOE_BZ2_PARAM;
    }
    if (src_len > 0xFFFFFFFFu || dst_capacity == 0 || dst_capacity > 0xFFFFFFFFu) {
        return FLOE_BZ2_PARAM;
    }
    if ((src_len > 0 && src == NULL) || dst == NULL) {
        return FLOE_BZ2_PARAM;
    }

    decoder->stream.next_in = (char *)(uintptr_t)src;
    decoder->stream.avail_in = (unsigned int)src_len;
    decoder->stream.next_out = (char *)dst;
    decoder->stream.avail_out = (unsigned int)dst_capacity;

    int rc = BZ2_bzDecompress(&decoder->stream);

    size_t used = src_len - (size_t)decoder->stream.avail_in;
    size_t made = dst_capacity - (size_t)decoder->stream.avail_out;
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
        case BZ_OK:
            return FLOE_BZ2_OK;
        case BZ_STREAM_END:
            decoder->active = 0;
            return FLOE_BZ2_STREAM_END;
        case BZ_MEM_ERROR:
            return FLOE_BZ2_MEMORY;
        case BZ_PARAM_ERROR:
            return FLOE_BZ2_PARAM;
        default:
            /* BZ_DATA_ERROR, BZ_DATA_ERROR_MAGIC, BZ_SEQUENCE_ERROR, ... are
             * all permanent data failures from the caller's point of view. */
            return FLOE_BZ2_ERROR;
    }
}

/* ---- encoder ------------------------------------------------------------ */

struct floe_bz2_encoder {
    bz_stream stream;
    int active;
};

floe_bz2_encoder *floe_bz2_encoder_create(int block_size_100k) {
    if (block_size_100k < 1 || block_size_100k > 9) {
        return NULL;
    }
    floe_bz2_encoder *encoder = (floe_bz2_encoder *)calloc(1, sizeof(floe_bz2_encoder));
    if (encoder == NULL) {
        return NULL;
    }
    /* verbosity 0; default work factor. */
    if (BZ2_bzCompressInit(&encoder->stream, block_size_100k, 0, 0) != BZ_OK) {
        free(encoder);
        return NULL;
    }
    encoder->active = 1;
    return encoder;
}

void floe_bz2_encoder_destroy(floe_bz2_encoder *encoder) {
    if (encoder == NULL) {
        return;
    }
    if (encoder->active) {
        BZ2_bzCompressEnd(&encoder->stream);
        encoder->active = 0;
    }
    free(encoder);
}

int floe_bz2_encoder_process(floe_bz2_encoder *encoder,
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
    if (encoder == NULL || !encoder->active) {
        return FLOE_BZ2_PARAM;
    }
    if (src_len > 0xFFFFFFFFu || dst_capacity == 0 || dst_capacity > 0xFFFFFFFFu) {
        return FLOE_BZ2_PARAM;
    }
    if ((src_len > 0 && src == NULL) || dst == NULL) {
        return FLOE_BZ2_PARAM;
    }

    encoder->stream.next_in = (char *)(uintptr_t)src;
    encoder->stream.avail_in = (unsigned int)src_len;
    encoder->stream.next_out = (char *)dst;
    encoder->stream.avail_out = (unsigned int)dst_capacity;

    int action = finish ? BZ_FINISH : BZ_RUN;
    int rc = BZ2_bzCompress(&encoder->stream, action);

    size_t used = src_len - (size_t)encoder->stream.avail_in;
    size_t made = dst_capacity - (size_t)encoder->stream.avail_out;
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

    if (!finish) {
        switch (rc) {
            case BZ_RUN_OK:
                return FLOE_BZ2_OK;
            case BZ_MEM_ERROR:
                return FLOE_BZ2_MEMORY;
            case BZ_PARAM_ERROR:
                return FLOE_BZ2_PARAM;
            default:
                return FLOE_BZ2_ERROR;
        }
    }
    switch (rc) {
        case BZ_FINISH_OK:
            return FLOE_BZ2_OK;
        case BZ_STREAM_END:
            encoder->active = 0;
            return FLOE_BZ2_FINISHED;
        case BZ_MEM_ERROR:
            return FLOE_BZ2_MEMORY;
        case BZ_PARAM_ERROR:
            return FLOE_BZ2_PARAM;
        default:
            return FLOE_BZ2_ERROR;
    }
}
