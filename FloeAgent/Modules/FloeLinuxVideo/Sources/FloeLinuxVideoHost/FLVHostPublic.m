/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Public C ABI entry points (floe_linux_video.h, ABI 1). Thin translation
 * layer over FLVHostContext / FLVSessionContext; argument validation happens
 * here so the ObjC layer can assume internal consistency.
 *
 * Every entry point bounds its autoreleased Foundation temporaries with
 * @autoreleasepool: engine/coordinator threads calling this ABI are plain
 * C/pthreads with no outer autorelease pool, and pools may not drain for
 * hours. The pools never affect ownership of returned opaque handles
 * (host_create returns a +1 host; its registry owns every live session.
 * A session handle is valid until session_close or host_destroy releases
 * that registry ownership. release_output frees its token directly).
 */
#import "FLVInternal.h"
#import "FLVHostContext.h"
#import "FLVSessionContext.h"
#import "FLVCodecRegistry.h"

int flv_host_create(const FLVHostConfig *config, FLVHost **host_out) {
    @autoreleasepool {
        if (!host_out) return FLV_INVALID;
        *host_out = NULL;
        if (!config) return FLV_INVALID;
        int status = FLV_OK;
        FLVHostContext *host = [[FLVHostContext alloc] initWithConfig:config status:&status];
        if (!host || status != FLV_OK) return status;
        *host_out = (__bridge_retained FLVHost *)host;
        return FLV_OK;
    }
}

int flv_host_query_capabilities(FLVHost *host, FLVCapability *entries,
                                size_t capacity, size_t *required_count) {
    @autoreleasepool {
        if (!host) return FLV_INVALID;
        FLVHostContext *h = (__bridge FLVHostContext *)host;
        (void)h;
        return flv_codec_fill_capabilities(entries, capacity, required_count);
    }
}

int flv_host_get_stats(FLVHost *host, FLVStats *stats) {
    @autoreleasepool {
        if (!host || !stats) return FLV_INVALID;
        FLVHostContext *h = (__bridge FLVHostContext *)host;
        [h stats:stats];
        return FLV_OK;
    }
}

void flv_host_destroy(FLVHost *host) {
    @autoreleasepool {
        if (!host) return;
        FLVHostContext *h = (__bridge_transfer FLVHostContext *)host;
        /* Explicit teardown while the host is still alive: close (invalidate +
         * join callbacks) every remaining session before releasing the host.
         * Relying on dealloc for this would deadlock the contract, because a
         * live session previously kept the host alive through the strong
         * host<->session references. */
        [h closeAllSessions];
        h = nil;
    }
}

int flv_session_create(FLVHost *host, const FLVSessionConfig *config, FLVSession **session_out) {
    @autoreleasepool {
        if (!session_out) return FLV_INVALID;
        *session_out = NULL;
        if (!host || !config) return FLV_INVALID;
        FLVHostContext *h = (__bridge FLVHostContext *)host;
        int status = FLV_OK;
        FLVSessionContext *session = [[FLVSessionContext alloc] initWithHost:h config:config status:&status];
        if (!session || status != FLV_OK) return status;
        int rc = [h registerSession:session];
        if (rc != FLV_OK) return rc;
        /* registerSession retained the object. A second opaque +1 retain
         * would leak when host_destroy closes a still-live session. */
        *session_out = (__bridge FLVSession *)session;
        return FLV_OK;
    }
}

int flv_session_submit_packet(FLVSession *session, const FLVPacket *packet) {
    @autoreleasepool {
        if (!session || !packet) return FLV_INVALID;
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        return [s submitPacket:packet];
    }
}

int flv_session_submit_frame(FLVSession *session, const FLVFrame *frame) {
    @autoreleasepool {
        if (!session || !frame) return FLV_INVALID;
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        return [s submitFrame:frame];
    }
}

int flv_session_dequeue(FLVSession *session, FLVOutput *output) {
    @autoreleasepool {
        if (!session || !output) return FLV_INVALID;
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        return [s dequeueOutput:output];
    }
}

void flv_session_release_output(FLVSession *session, FLVOutput *output) {
    @autoreleasepool {
        if (!session || !output) return;
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        [s releaseOutputToken:output->release_token];
        output->release_token = NULL;
        output->data = NULL;
        output->bytes = 0;
    }
}

int flv_session_flush(FLVSession *session, int drain) {
    @autoreleasepool {
        if (!session) return FLV_INVALID;
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        return [s flushWithDrain:drain ? 1 : 0];
    }
}

void flv_session_cancel(FLVSession *session) {
    @autoreleasepool {
        if (!session) return;
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        [s cancel];
    }
}

void flv_session_close(FLVSession *session) {
    @autoreleasepool {
        if (!session) return;
        /* Keep a local strong reference while close joins callbacks and
         * removes the host registry's ownership. The handle then expires. */
        FLVSessionContext *s = (__bridge FLVSessionContext *)session;
        [s close];
        s = nil;
    }
}
