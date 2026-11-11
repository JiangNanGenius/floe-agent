/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* GPU shared-memory aperture: constants plus the thin wrapper the virtio-gpu
 * transport uses over the generic region registry (memory_regions.h).
 * Implemented in virtio_gpu.c.
 *
 * The aperture is a STABLE, SPARSE address range. Capacity != budget:
 *   - capacity  = FLOE_GPU_SHM_CAP, the guest-visible address range described
 *                 by the virtio-mmio SharedMemoryRegion registers;
 *   - budget    = live blob bytes the device will accept (default 1 GiB),
 *                 accounted LOGICALLY from guest requests. The host backend
 *                 owns physical GPU usage; the two numbers are never summed.
 * Nothing preallocates the 4 GiB. Each mapped blob registers its REAL host
 * pages (exported by the renderer through ->resource_map_blob) at the
 * driver-chosen aperture offset; unmapped offsets are holes that fault like any
 * other unmapped guest PA.
 *
 * Safety: map/unmap are coordinator-only. Unmap while native workers are live
 * is DEFERRED (the segment stays fully mapped and the backend keeps its pages)
 * because a whole-machine TLB flush is illegal outside quiescence; the owner
 * retries through floe_gpu_shm_flush_pending() at a quiet point. See
 * memory_regions.h for the D-TLB host-pointer reasoning. */
#ifndef A64_VIRTIO_GPU_SHM_H
#define A64_VIRTIO_GPU_SHM_H

#include "../types.h"
#include "../memory_regions.h"

struct Machine;

/* 64 GiB base: above the current 1 GiB RAM end (0x80000000) so future RAM
 * growth cannot collide, below pcie-ecam (0x4010000000), inside the 48-bit
 * stage-1 output-address field the emulator implements (mmu.c), and disjoint
 * from every region platform.c registers. */
#define FLOE_GPU_SHM_BASE 0x1000000000ULL
#define FLOE_GPU_SHM_CAP  0x100000000ULL   /* 4 GiB stable aperture capacity */
#define FLOE_GPU_SHM_PAGE FLOE_REGION_PAGE
#define FLOE_GPU_SHM_NAME "gpu-shm"

/* virtio-mmio SharedMemoryRegion register offsets. These are the CANONICAL
 * wire offsets from Linux include/uapi/linux/virtio_mmio.h (verified against
 * torvalds/linux v6.12, BSD-3-Clause):
 *   VIRTIO_MMIO_SHM_SEL        0x0ac
 *   VIRTIO_MMIO_SHM_LEN_LOW    0x0b0
 *   VIRTIO_MMIO_SHM_LEN_HIGH   0x0b4
 *   VIRTIO_MMIO_SHM_BASE_LOW   0x0b8
 *   VIRTIO_MMIO_SHM_BASE_HIGH  0x0bc
 * An earlier revision of this candidate had all five shifted +4 (SEL at 0x0b0),
 * which made a real Linux 6.12 boot fail with "Could not reserve host visible
 * region" and virtio-gpu probe -16: the driver read LEN as 0 instead of the
 * aperture size. The static asserts below pin the values so this cannot
 * silently regress.
 *
 * Per the transport spec and Linux vm_get_shm_region(), selecting a ShmId that
 * does not exist must make BOTH length registers read all-ones (0xffffffff),
 * not zero: that is how the driver distinguishes "no such region" from "region
 * of length 0". */
#define VIRTIO_MMIO_SHM_SEL        0x0acu
#define VIRTIO_MMIO_SHM_LEN_LOW    0x0b0u
#define VIRTIO_MMIO_SHM_LEN_HIGH   0x0b4u
#define VIRTIO_MMIO_SHM_BASE_LOW   0x0b8u
#define VIRTIO_MMIO_SHM_BASE_HIGH  0x0bcu
/* Legacy aliases are deliberately NOT provided; use the canonical names. */

_Static_assert(VIRTIO_MMIO_SHM_SEL       == 0x0acu, "canonical virtio-mmio ShmSel offset");
_Static_assert(VIRTIO_MMIO_SHM_LEN_LOW   == 0x0b0u, "canonical virtio-mmio ShmLenLow offset");
_Static_assert(VIRTIO_MMIO_SHM_LEN_HIGH  == 0x0b4u, "canonical virtio-mmio ShmLenHigh offset");
_Static_assert(VIRTIO_MMIO_SHM_BASE_LOW  == 0x0b8u, "canonical virtio-mmio ShmBaseLow offset");
_Static_assert(VIRTIO_MMIO_SHM_BASE_HIGH == 0x0bcu, "canonical virtio-mmio ShmBaseHigh offset");

#ifdef __cplusplus
extern "C" {
#endif

/* Create (or find) the sparse aperture region. Returns the registry index or a
 * negative FLOE_REGION_E*. Idempotent across device reset. */
int  floe_gpu_shm_region_create(struct Machine *m);

/* Register [gpa, gpa+len) inside the aperture. host non-NULL aliases real
 * backend pages (never freed here); NULL asks for engine-anonymous backing. */
int  floe_gpu_shm_map(struct Machine *m, u64 gpa, u64 len, void *host);
/* FLOE_REGION_OK when really unmapped, FLOE_REGION_DEFERRED when workers were
 * live (range stays mapped; retry via flush_pending when quiet). */
int  floe_gpu_shm_unmap(struct Machine *m, u64 gpa, u64 len);
int  floe_gpu_shm_flush_pending(struct Machine *m);

void *floe_gpu_shm_host_ptr(struct Machine *m, u64 gpa, u64 len);
u64   floe_gpu_shm_contig(struct Machine *m, u64 gpa);
bool  floe_gpu_shm_span_ok(u64 gpa, u64 len);

#ifdef __cplusplus
}
#endif
#endif /* A64_VIRTIO_GPU_SHM_H */
