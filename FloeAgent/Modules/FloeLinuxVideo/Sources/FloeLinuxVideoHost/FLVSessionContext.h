/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FLVSessionContext — one bounded asynchronous codec session.
 *
 * Threading: a single pthread mutex guards all mutable state. VideoToolbox
 * completion callbacks take the same lock briefly; they never call back
 * into the public API and never run user code. The host notify hook is
 * invoked only with no locks held.
 *
 * Ownership: every input is copied into host-owned memory before the VT
 * call; per-work context records carry a generation number so that cancel /
 * discard / close fence late callbacks deterministically. Outputs are owned
 * host buffers handed out through FLVOutput.release_token.
 */
#ifndef FLV_SESSION_CONTEXT_H
#define FLV_SESSION_CONTEXT_H

#import "FLVInternal.h"
#import "FLVQueue.h"
#include "FLVBitstream.h"

@class FLVHostContext;

@interface FLVSessionContext : NSObject {
    @package
    /* Weak: the host owns its sessions strongly; a strong session->host
     * reference would create a retain cycle and flv_host_destroy could never
     * run its "closes all remaining sessions" contract while a session was
     * still live. The host always outlives its sessions (destroy closes them
     * explicitly while the host is still alive). */
    __weak FLVHostContext *_host;
    FLVSessionConfig _config;      /* pixel geometry/bitrate copy; pointers below owned */
    uint8_t *_codec_config;        /* owned copy of config record */
    size_t _codec_config_bytes;
    uint32_t _codec, _direction, _pixel_format;
    uint32_t _width, _height;
    uint32_t _bitstream_format;
    uint64_t _bitrate;

    pthread_mutex_t _lock;
    uint64_t _generation;
    int _cancelled;
    int _closed;
    int _drain_pending;
    int _hw_reported;              /* -1 unknown, 0 software, 1 hardware */
    int _format_sent;              /* encoder emitted FLV_OUTPUT_FORMAT */
    int _error_reported;           /* one fatal error output already queued */

    VTCompressionSessionRef _enc;
    VTDecompressionSessionRef _dec;
    CMFormatDescriptionRef _fmt;   /* decode */
    VTPixelTransferSessionRef _transfer; /* decode fallback for exotic output formats */
    int _imageio_native;           /* MJPEG explicit ImageIO fallback, no VT session */

    uint32_t _inflight;
    uint64_t _inflight_bytes;
    FLVOutputQueue _queue;

    uint64_t _submitted, _completed, _cancelled_count;
    FLVParamSets _param_sets;      /* encoder param sets parsed from its own avcC/hvcC */
    /* Annex-B decode: parameter sets accumulate across packets (SPS-only and
     * PPS-only packets are legal metadata-only inputs); the deferred format
     * description / decompression session is built once every required set
     * is known. */
    FLVParamSets _pending_ps;
    int _has_pending_ps;
}

- (instancetype)initWithHost:(FLVHostContext *)host config:(const FLVSessionConfig *)config status:(int *)status;

- (int)submitPacket:(const FLVPacket *)packet;
- (int)submitFrame:(const FLVFrame *)frame;
- (int)dequeueOutput:(FLVOutput *)output;
- (void)releaseOutputToken:(void *)token;
- (int)flushWithDrain:(int)drain;
- (void)cancel;
- (void)close;

/* snapshot counters for host stats (called under host lock) */
- (uint32_t)inflightCount;
- (uint32_t)queuedOutputCount;
- (uint64_t)sessionOwnedBytes; /* inflight + queued */

@end

#endif /* FLV_SESSION_CONTEXT_H */
