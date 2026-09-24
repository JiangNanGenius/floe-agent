/*
 * CFloeArchive — narrow streaming shim over the platform's libbz2.
 *
 * Why this exists
 * ---------------
 * The workspace archive engine needs bounded, cancellable bzip2 support on
 * Apple platforms. The SDK ships `libbz2` (`usr/lib/libbz2.tbd`, header
 * `usr/include/bzlib.h`) for both iOS and macOS but does not expose it as a
 * Swift module, so this tiny C target is the module boundary. No vendored
 * dependency is added: the same `libbz2` the system `bzip2` tool uses is
 * linked directly.
 *
 * Contract
 * --------
 * * The decoder holds libbz2's own fixed working state (bounded by the block
 *   size in the stream header, at most a few MiB) and never buffers a whole
 *   archive or a whole member. Data flows caller-buffer → decoder → caller
 *   buffer; the caller decides how much output to accept per call.
 * * Nothing here allocates output on the caller's behalf and no function
 *   blocks: the Swift layer polls cancellation on every call.
 * * A decoder instance processes exactly one bzip2 stream. When a stream ends
 *   (`FLOE_BZ2_STREAM_END`) the caller destroys the instance and creates a new
 *   one for the next member, feeding it the unconsumed input; `*consumed`
 *   always reports the exact number of input bytes the ended stream used, so
 *   concatenated members are located by decoding, never by scanning for a
 *   magic. Trailing bytes that are not a valid stream therefore fail with
 *   `FLOE_BZ2_ERROR` instead of being ignored.
 * * Status codes are plain integer macros so Swift can switch on them without
 *   a bridging enum.
 */

#ifndef CFLOE_ARCHIVE_H
#define CFLOE_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- status codes (also used by the encoder) ---------------------------- */

/* Progress was made or more input is required; call again. */
#define FLOE_BZ2_OK 0
/* The current stream ended cleanly; `*consumed` is exact. */
#define FLOE_BZ2_STREAM_END 1
/* The data is not a valid bzip2 stream, or it is truncated/corrupt. */
#define FLOE_BZ2_ERROR 2
/* libbz2 could not allocate its bounded working state. */
#define FLOE_BZ2_MEMORY 3
/* Invalid argument or misuse (e.g. processing an ended decoder). */
#define FLOE_BZ2_PARAM 4
/* The encoder finished producing its last output byte. */
#define FLOE_BZ2_FINISHED 5

/* ---- decoder ------------------------------------------------------------ */

typedef struct floe_bz2_decoder floe_bz2_decoder;

/* Returns NULL when libbz2 cannot initialize (memory). */
floe_bz2_decoder *floe_bz2_decoder_create(void);
void floe_bz2_decoder_destroy(floe_bz2_decoder *decoder);

/*
 * Feeds up to `src_len` input bytes and writes at most `dst_capacity` output
 * bytes. `*consumed` / `*produced` report the exact byte counts (both are set
 * even on error). Returns one of the FLOE_BZ2_* status codes:
 *
 *   FLOE_BZ2_OK          call again (possibly with more input)
 *   FLOE_BZ2_STREAM_END  this stream ended; destroy and restart for the next
 *   FLOE_BZ2_ERROR       invalid/truncated data (permanent failure)
 *   FLOE_BZ2_MEMORY      allocation failure
 *   FLOE_BZ2_PARAM       misuse: this decoder already returned STREAM_END
 *
 * Calling with `src_len == 0` and `src == NULL` is allowed and exercises the
 * "needs more input" path; the caller detects truncation when the input is
 * exhausted and the status stays OK with no progress.
 */
int floe_bz2_decoder_process(floe_bz2_decoder *decoder,
                             const uint8_t *src, size_t src_len,
                             uint8_t *dst, size_t dst_capacity,
                             size_t *consumed, size_t *produced);

/* ---- encoder ------------------------------------------------------------ */

typedef struct floe_bz2_encoder floe_bz2_encoder;

/* `block_size_100k` must be 1...9. Returns NULL on invalid size or memory. */
floe_bz2_encoder *floe_bz2_encoder_create(int block_size_100k);
void floe_bz2_encoder_destroy(floe_bz2_encoder *encoder);

/*
 * Compresses input into the caller's buffer. With `finish == 0` the encoder is
 * in streaming mode (`FLOE_BZ2_OK` while it accepts more input); with
 * `finish == 1` it flushes and returns `FLOE_BZ2_OK` until the final bytes
 * have been produced, then `FLOE_BZ2_FINISHED`. Any output produced in a call
 * is reported through `*produced`; the caller appends it before the next call,
 * so the compressed output is never buffered here.
 */
int floe_bz2_encoder_process(floe_bz2_encoder *encoder,
                             const uint8_t *src, size_t src_len,
                             uint8_t *dst, size_t dst_capacity,
                             int finish,
                             size_t *consumed, size_t *produced);

#ifdef __cplusplus
}
#endif

#endif /* CFLOE_ARCHIVE_H */
