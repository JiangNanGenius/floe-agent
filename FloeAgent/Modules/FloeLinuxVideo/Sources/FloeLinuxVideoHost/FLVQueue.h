/* SPDX-License-Identifier: MPL-2.0 */
/* Host-owned output buffers. The release token handed to callers of
 * flv_session_dequeue is a pointer to one of these; it is freed by
 * flv_session_release_output (or by session close for stragglers). */
#ifndef FLV_QUEUE_H
#define FLV_QUEUE_H

#include "FLVInternal.h"

typedef struct FLVOutputBuffer {
    uint32_t kind, flags;
    int32_t status;
    uint32_t hardware_used;
    uint64_t tag;
    int64_t pts_ns, dts_ns, duration_ns;
    uint8_t *data;
    size_t bytes;
    uint32_t width, height, pixel_format, plane_count;
    uint64_t plane_offsets[FLV_MAX_PLANES];
    uint64_t plane_bytes[FLV_MAX_PLANES];
    uint32_t plane_strides[FLV_MAX_PLANES];
    struct FLVOutputBuffer *next;
} FLVOutputBuffer;

typedef struct {
    FLVOutputBuffer *head, *tail;
    uint32_t count;
    uint64_t bytes;
} FLVOutputQueue;

static inline void flv_queue_init(FLVOutputQueue *q) {
    memset(q, 0, sizeof(*q));
}

static inline void flv_queue_push(FLVOutputQueue *q, FLVOutputBuffer *b) {
    b->next = NULL;
    if (q->tail) q->tail->next = b;
    else q->head = b;
    q->tail = b;
    q->count++;
    q->bytes += b->bytes;
}

static inline FLVOutputBuffer *flv_queue_pop(FLVOutputQueue *q) {
    FLVOutputBuffer *b = q->head;
    if (!b) return NULL;
    q->head = b->next;
    if (!q->head) q->tail = NULL;
    b->next = NULL;
    q->count--;
    q->bytes -= b->bytes;
    return b;
}

static inline void flv_queue_discard_all(FLVOutputQueue *q, uint64_t *freed_bytes, uint32_t *freed_count) {
    FLVOutputBuffer *b = q->head;
    uint64_t fb = 0; uint32_t fc = 0;
    while (b) {
        FLVOutputBuffer *n = b->next;
        fb += b->bytes;
        fc++;
        if (b->data) free(b->data);
        free(b);
        b = n;
    }
    flv_queue_init(q);
    if (freed_bytes) *freed_bytes = fb;
    if (freed_count) *freed_count = fc;
}

#endif /* FLV_QUEUE_H */
