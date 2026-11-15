/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVHostContext.h"

@implementation FLVHostContext

- (instancetype)initWithConfig:(const FLVHostConfig *)config status:(int *)status {
    self = [super init];
    if (!self) { if (status) *status = FLV_INTERNAL; return nil; }
    if (!config || config->abi_version != FLV_ABI_VERSION) {
        if (status) *status = FLV_INVALID;
        return nil;
    }
    if (!config->notify) {
        /* A notify hook is required: without it the owner cannot be woken
         * for output/input readiness and polling would be undefined. */
        if (status) *status = FLV_INVALID;
        return nil;
    }
    if (config->max_sessions == 0 || config->max_inflight_per_session == 0) {
        /* Zero session/inflight budgets are invalid; silently defaulting
         * would mask driver bugs. Byte limits default below. */
        if (status) *status = FLV_INVALID;
        return nil;
    }
    _max_sessions = config->max_sessions;
    _max_inflight_per_session = config->max_inflight_per_session;
    _max_inflight_per_session = config->max_inflight_per_session ? config->max_inflight_per_session : 1;
    _max_packet_bytes = config->max_packet_bytes ? config->max_packet_bytes : 1;
    _max_frame_bytes = config->max_frame_bytes ? config->max_frame_bytes : 1;
    _max_owned_bytes = config->max_owned_bytes ? config->max_owned_bytes : 1;
    if (_max_packet_bytes > FLV_STRUCT_MAX_PACKET_BYTES) _max_packet_bytes = FLV_STRUCT_MAX_PACKET_BYTES;
    if (_max_frame_bytes > FLV_STRUCT_MAX_FRAME_BYTES) _max_frame_bytes = FLV_STRUCT_MAX_FRAME_BYTES;
    _config = *config;
    pthread_mutex_init(&_lock, NULL);
    _sessions = [[NSMutableArray alloc] init];
    _owned_bytes = 0;
    _peak_owned_bytes = 0;
    if (status) *status = FLV_OK;
    return self;
}

- (void)dealloc {
    [self closeAllSessions];
    pthread_mutex_lock(&_lock);
    [_sessions removeAllObjects];
    pthread_mutex_unlock(&_lock);
    pthread_mutex_destroy(&_lock);
}

- (uint32_t)maxInflightPerSession { return _max_inflight_per_session; }
- (uint64_t)maxPacketBytes { return _max_packet_bytes; }
- (uint64_t)maxFrameBytes { return _max_frame_bytes; }

- (int)claimBytes:(uint64_t)bytes {
    int rc = FLV_OK;
    pthread_mutex_lock(&_lock);
    if (_owned_bytes + bytes > _max_owned_bytes) {
        rc = FLV_LIMIT;
    } else {
        _owned_bytes += bytes;
        if (_owned_bytes > _peak_owned_bytes) _peak_owned_bytes = _owned_bytes;
    }
    pthread_mutex_unlock(&_lock);
    return rc;
}

- (void)releaseBytes:(uint64_t)bytes {
    pthread_mutex_lock(&_lock);
    _owned_bytes = (_owned_bytes >= bytes) ? _owned_bytes - bytes : 0;
    pthread_mutex_unlock(&_lock);
}

- (int)registerSession:(FLVSessionContext *)session {
    int rc = FLV_OK;
    pthread_mutex_lock(&_lock);
    if ([_sessions count] >= _max_sessions) rc = FLV_LIMIT;
    else [_sessions addObject:session];
    pthread_mutex_unlock(&_lock);
    return rc;
}

- (void)unregisterSession:(FLVSessionContext *)session {
    pthread_mutex_lock(&_lock);
    [_sessions removeObjectIdenticalTo:session];
    pthread_mutex_unlock(&_lock);
}

- (void)bumpSubmitted { pthread_mutex_lock(&_lock); _submitted++; pthread_mutex_unlock(&_lock); }
- (void)bumpCompleted { pthread_mutex_lock(&_lock); _completed++; pthread_mutex_unlock(&_lock); }
- (void)bumpCancelled { pthread_mutex_lock(&_lock); _cancelled++; pthread_mutex_unlock(&_lock); }

- (void)emitNotify:(uint64_t)sessionTag events:(uint32_t)events {
    FLVNotify fn = _config.notify;
    if (!fn) return;
    fn(_config.notify_opaque, sessionTag, events);
}

- (void)stats:(FLVStats *)stats {
    if (!stats) return;
    memset(stats, 0, sizeof(*stats));
    pthread_mutex_lock(&_lock);
    NSArray *snapshot = [_sessions copy];
    uint64_t owned = _owned_bytes, peak = _peak_owned_bytes;
    uint64_t submitted = _submitted, completed = _completed, cancelled = _cancelled;
    pthread_mutex_unlock(&_lock);
    /* Session locks are taken without the host lock to respect the
     * session-lock -> host-lock ordering used by VT callbacks. */
    uint32_t inflight = 0, queued = 0;
    for (FLVSessionContext *s in snapshot) {
        inflight += [s inflightCount];
        queued += [s queuedOutputCount];
    }
    stats->sessions = (uint32_t)[snapshot count];
    stats->owned_bytes = owned;
    stats->peak_owned_bytes = peak;
    stats->submitted = submitted;
    stats->completed = completed;
    stats->cancelled = cancelled;
    stats->inflight = inflight;
    stats->queued_outputs = queued;
}

- (void)closeAllSessions {
    pthread_mutex_lock(&_lock);
    NSArray *snapshot = [_sessions copy];
    [_sessions removeAllObjects];
    pthread_mutex_unlock(&_lock);
    for (FLVSessionContext *s in snapshot) {
        [s close];
    }
}

@end
