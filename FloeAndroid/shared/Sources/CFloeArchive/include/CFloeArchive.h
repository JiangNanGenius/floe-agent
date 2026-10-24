/*
 * CFloeArchive — narrow streaming shim over the platform's libbz2.
 *
 * Android addendum (lane job-bf610b6f22fe42ab, additive; the bzip2 contract
 * below is unchanged): Android has no system libbz2 or Compression framework,
 * so the identical streaming contract is served by the pinned vendored
 * sources — bzip2 1.0.8 (Vendor/Archive/bzip2-1.0.8, upstream libbzip2
 * objects compiled into the CBZip2 target) and liblzma 5.8.1
 * (Vendor/Archive/xz-5.8.1, 0BSD, XZ_THREADS=no) behind the `floe_xz_*`
 * section appended at the bottom of this header. The Apple `-lbz2` system
 * link is therefore not required anywhere in the FloeAndroid graph: the same
 * vendored bzip2 code path runs on host tests and on device.
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
 * 1 while the decoder still owns libbz2's (multi-MiB) block state, 0 once it
 * has been released. The state is released at the `FLOE_BZ2_STREAM_END`
 * transition, and by `destroy` on every other path; this accessor exists so a
 * caller/test can assert that contract directly. Never dereferences a freed
 * handle.
 */
int floe_bz2_decoder_state_active(const floe_bz2_decoder *decoder);

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

/* Same contract as `floe_bz2_decoder_state_active`, for the encoder. */
int floe_bz2_encoder_state_active(const floe_bz2_encoder *encoder);

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

/* ---- xz (Android addendum; identical contract to the bzip2 section) ------
 */

/* Status codes — the same integer values as the FLOE_BZ2_* set. */
#define FLOE_XZ_OK 0
#define FLOE_XZ_STREAM_END 1
#define FLOE_XZ_ERROR 2
#define FLOE_XZ_MEMORY 3
#define FLOE_XZ_PARAM 4
#define FLOE_XZ_FINISHED 5

/* ---- xz section documentation continues below ----------------------------
 *
 * Android delta, documented for this lane (job-bf610b6f22fe42ab):
 * iOS/macOS get `.xz` through the system Compression framework
 * (`ArchiveCodecs.swift` COMPRESSION_LZMA). Android ships no such codec, so
 * the same streaming `.xz` semantics are provided here over the pinned,
 * vendored liblzma 5.8.1 (XZ 5.8.1 tarball, 0BSD; see
 * `Vendor/Archive/xz-5.8.1/floe/RECIPE.md`). liblzma is the reference
 * implementation of the `.xz` container, so this is the same format contract
 * the Apple path advertises: complete liblzma-compatible `.xz` streams, the
 * stream's own integrity check validated on decode, one decoder instance per
 * member and exact consumed-byte counts so concatenated members are located
 * by decoding, never by scanning. Truncated or unsupported filter chains are
 * permanent failures, not silently skipped.
 *
 * * Status codes share the exact integer values of the FLOE_BZ2_* set:
 *   FLOE_XZ_OK 0, FLOE_XZ_STREAM_END 1, FLOE_XZ_ERROR 2, FLOE_XZ_MEMORY 3,
 *   FLOE_XZ_PARAM 4, FLOE_XZ_FINISHED 5.
 * * `preset` is the liblzma easy preset 0...9; -1 selects
 *   `LZMA_PRESET_DEFAULT` (6), matching the "default level" encode behavior.
 * * Decoder memory follows liblzma's own accounting; allocation or memlimit
 *   failure maps to FLOE_XZ_MEMORY (Swift: `limitExceeded`), never a crash.
 */

/* ---- decoder ------------------------------------------------------------ */

typedef struct floe_xz_decoder floe_xz_decoder;

/* Returns NULL when liblzma cannot initialize (memory). */
floe_xz_decoder *floe_xz_decoder_create(void);
void floe_xz_decoder_destroy(floe_xz_decoder *decoder);

/* Same "state released at STREAM_END" contract as the bzip2 accessor. */
int floe_xz_decoder_state_active(const floe_xz_decoder *decoder);

/*
 * Feeds up to `src_len` input bytes and writes at most `dst_capacity` output
 * bytes; `*consumed` / `*produced` are exact on every path. Status:
 *   FLOE_XZ_OK (0)         call again (possibly with more input)
 *   FLOE_XZ_STREAM_END (1) this stream ended; destroy and restart next member
 *   FLOE_XZ_ERROR (2)      invalid/truncated/unsupported data (permanent)
 *   FLOE_XZ_MEMORY (3)     allocation or memlimit refusal
 *   FLOE_XZ_PARAM (4)      misuse: this decoder already returned STREAM_END
 */
int floe_xz_decoder_process(floe_xz_decoder *decoder,
                            const uint8_t *src, size_t src_len,
                            uint8_t *dst, size_t dst_capacity,
                            size_t *consumed, size_t *produced);

/* ---- encoder ------------------------------------------------------------ */

typedef struct floe_xz_encoder floe_xz_encoder;

/* `preset` 0...9 or -1 for the liblzma default. NULL on invalid or memory. */
floe_xz_encoder *floe_xz_encoder_create(int preset);
void floe_xz_encoder_destroy(floe_xz_encoder *encoder);

/* Same lifecycle accessor contract as the bzip2 encoder. */
int floe_xz_encoder_state_active(const floe_xz_encoder *encoder);

/*
 * Compresses into the caller's buffer; `finish == 0` is streaming
 * (FLOE_XZ_OK), `finish == 1` flushes until the last bytes are produced and
 * then returns FLOE_XZ_FINISHED (5). The compressed output is never buffered
 * here.
 */
int floe_xz_encoder_process(floe_xz_encoder *encoder,
                            const uint8_t *src, size_t src_len,
                            uint8_t *dst, size_t dst_capacity,
                            int finish,
                            size_t *consumed, size_t *produced);

#ifdef __cplusplus
}
#endif

#endif /* CFLOE_ARCHIVE_H */
