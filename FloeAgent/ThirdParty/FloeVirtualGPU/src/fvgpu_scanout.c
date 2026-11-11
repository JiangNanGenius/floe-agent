/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_scanout.c — display-on-demand scanout state. Closing a scanout
 * releases ONLY scanout state (scratch pixmap + rect); compute contexts,
 * resources and submissions are untouched. */
#include "fvgpu_priv.h"

#include <stdlib.h>
#include <string.h>

static void
fvgpu_scanout_release_scratch(FloeGPUSession *s)
{
    free(s->scanout.scratch);
    s->scanout.scratch = NULL;
    s->scanout.scratch_size = 0;
}

int
floe_gpu_scanout_set(FloeGPUSession *s, uint32_t scanout_id,
                     uint32_t res_id, const struct floe_gpu_rect *r)
{
    if (scanout_id != 0)
        return FVGPU_RESP_INVALID; /* v1: one scanout */
    if (!fvgpu_resource_find(s, res_id))
        return FVGPU_RESP_INVALID;
    fvgpu_scanout_release_scratch(s);
    s->scanout.active = true;
    s->scanout.res_id = res_id;
    s->scanout.rect = *r;
    s->scanout.width = r->width;
    s->scanout.height = r->height;
    return FVGPU_RESP_OK;
}

int
floe_gpu_scanout_close(FloeGPUSession *s, uint32_t scanout_id)
{
    if (scanout_id != 0 || !s->scanout.active)
        return FVGPU_RESP_INVALID;
    /* display off: only scanout resources go away */
    fvgpu_scanout_release_scratch(s);
    s->scanout.active = false;
    s->scanout.res_id = 0;
    memset(&s->scanout.rect, 0, sizeof(s->scanout.rect));
    return FVGPU_RESP_OK;
}

int
floe_gpu_scanout_snapshot(FloeGPUSession *s, uint32_t scanout_id,
                          FloeGPUScanout *out)
{
    if (scanout_id != 0 || !s->scanout.active)
        return FVGPU_RESP_INVALID;
    /* v1: no GL/2D pipeline is wired yet (venus-only renderer), so there is
     * no pixel source to snapshot. This is reported honestly; the pixmap
     * ABI (fields, not guesses) is what the transport aligns to. Once the
     * display path attaches (2D via venus images / future zink), this fills
     * stride/format/pixels from the real layout with conversion only when
     * the layout differs. */
    (void)s; (void)out;
    return FVGPU_RESP_ERR_UNSPEC;
}
