/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_submit.c — Venus command submission + exact-token fences. */
#include "fvgpu_priv.h"

int
floe_gpu_submit(FloeGPUSession *s, uint32_t ctx_id,
                const void *cmds, uint32_t size)
{
    if (!fvgpu_context_exists(s, ctx_id))
        return FVGPU_RESP_INVALID;
    if (!cmds || !size)
        return FVGPU_RESP_INVALID;
    /* vkr takes ownership of the stream buffer; copy is transport-owned
     * policy (v1: copy into renderer-owned memory) */
    if (!vkr_renderer_submit_cmd(ctx_id, (void *)cmds, size))
        return FVGPU_RESP_ERR_UNSPEC;
    return FVGPU_RESP_OK;
}

int
floe_gpu_create_fence(FloeGPUSession *s, uint32_t ctx_id,
                      uint32_t ring_idx, uint64_t fence_id)
{
    if (!fvgpu_context_exists(s, ctx_id))
        return FVGPU_RESP_INVALID;
    /* exact per-timeline token on the Venus path; the queue keeps accepting
     * subsequent commands (this is an independent fence op, not tied to a
     * command stream submission) */
    if (!vkr_renderer_submit_fence(ctx_id, 0, ring_idx, fence_id))
        return FVGPU_RESP_ERR_UNSPEC;
    return FVGPU_RESP_OK;
}
