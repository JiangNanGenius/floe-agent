/* SPDX-License-Identifier: MPL-2.0 */
/*
 * FLVHostContext — process-wide owner of sessions and the shared memory /
 * concurrency budget. Locking order is always session lock -> host lock;
 * the host never takes a session lock while holding its own lock.
 */
#ifndef FLV_HOST_CONTEXT_H
#define FLV_HOST_CONTEXT_H

#import "FLVInternal.h"
#import "FLVSessionContext.h"

@interface FLVHostContext : NSObject {
    @package
    FLVHostConfig _config;
    uint32_t _max_sessions;
    uint32_t _max_inflight_per_session;
    uint64_t _max_packet_bytes;
    uint64_t _max_frame_bytes;
    uint64_t _max_owned_bytes;
    pthread_mutex_t _lock;
    NSMutableArray *_sessions;      /* FLVSessionContext, owned */
    uint64_t _owned_bytes;
    uint64_t _peak_owned_bytes;
    uint64_t _submitted, _completed, _cancelled;
}

- (instancetype)initWithConfig:(const FLVHostConfig *)config status:(int *)status;

- (uint32_t)maxInflightPerSession;
- (uint64_t)maxPacketBytes;
- (uint64_t)maxFrameBytes;

/* Returns FLV_OK and accounts bytes, or FLV_LIMIT without side effects. */
- (int)claimBytes:(uint64_t)bytes;
- (void)releaseBytes:(uint64_t)bytes;

- (int)registerSession:(FLVSessionContext *)session; /* FLV_LIMIT when session budget hit */
- (void)unregisterSession:(FLVSessionContext *)session;

- (void)bumpSubmitted;
- (void)bumpCompleted;
- (void)bumpCancelled;

/* Invoke the configured notify hook with no locks held. */
- (void)emitNotify:(uint64_t)sessionTag events:(uint32_t)events;

/* Snapshot of host-wide counters. */
- (void)stats:(FLVStats *)stats;

/* Host teardown: close every remaining session, then release. Sessions are
 * closed without holding the host lock to respect lock ordering. */
- (void)closeAllSessions;

@end

#endif /* FLV_HOST_CONTEXT_H */
