/* SPDX-License-Identifier: MPL-2.0 */
#ifndef FLOE_ARM64EMU_H
#define FLOE_ARM64EMU_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define FLOE_AE_ABI_VERSION 1u
#define FLOE_AE_MAX_VCPUS 5u /* engine ceiling; caller chooses device limit before boot */
#define FLOE_AE_API __attribute__((visibility("default")))
typedef uint64_t floe_ae_handle;
enum { FLOE_AE_OK=0, FLOE_AE_INVALID=-1, FLOE_AE_STALE=-2, FLOE_AE_FAULT=-3,
       FLOE_AE_BUSY=-4, FLOE_AE_IO=-5, FLOE_AE_NOMEM=-6, FLOE_AE_VERSION=-7,
       FLOE_AE_UNSUPPORTED=-8 };
enum { FLOE_AE_CREATED=1, FLOE_AE_RUNNING=2, FLOE_AE_STOPPED=3,
       FLOE_AE_POWEROFF=4, FLOE_AE_FAILED=5 };
enum { FLOE_AE_BUDGET=1, FLOE_AE_PARKED=2, FLOE_AE_OUTPUT_FULL=3,
       FLOE_AE_CANCELLED=4, FLOE_AE_GUEST_OFF=5, FLOE_AE_GUEST_FAULT=6 };
typedef struct {
    uint32_t abi_version, struct_size;
    uint32_t ram_mib, requested_vcpus; /* immutable possible topology: exactly1..5 */
    const char *firmware_path, *kernel_path, *initrd_path, *command_line;
    const char *private_writable_disk_path; /* explicit caller-owned sandbox copy */
    uint32_t input_capacity, output_capacity; /* 0=64KiB/1MiB, fixed upper bounds */
    uint64_t reserved[4];
} floe_ae_config;
typedef struct {
    uint32_t struct_size, reason;
    uint64_t instructions, host_elapsed_ns, wake_sequence;
    uint64_t next_deadline_ns; /* relative; UINT64_MAX=no timer. Machine aggregate */
    uint32_t state, reserved;
} floe_ae_slice;
typedef struct {
    uint32_t struct_size, state;
    uint64_t instructions, pc, slice_calls, park_waits, wake_sequence;
    uint64_t input_queued, output_queued, diagnostic_dropped;
    uint64_t ram_bytes, flash_bytes, owned_disk_fds, reset_count; /* mapped capacities, not RSS */
    uint32_t supported_vcpus, active_slice; /* configured possible count; host workers may execute concurrently */
    int32_t last_error;
    uint32_t reserved;
} floe_ae_stats;
/* No callbacks or implicit host terminal. create reads paths synchronously;
 * strings need live only for create. firmware-only fixtures may omit kernel and
 * initrd; create/CREATED never claims Linux readiness. Disk must be an explicit
 * private writable regular-file copy, never a bundle or shared/base image.
 * Current implementation allows ONE live Machine; additional create is BUSY.
 * Handles are monotonically generated and never reused, including after failure.
 */
FLOE_AE_API int floe_ae_create(const floe_ae_config *, floe_ae_handle *);
/* Exactly one caller coordinates slices per handle. Both budgets are nonzero;
 * accepted ns<=100ms, instructions<=100M. The instruction budget aggregates
 * retirement across native per-hart workers, with tickets bounded by4096 and
 * per-instruction control/IRQ/TLB safe points. Return requires all granted
 * workers quiescent. Host time is a cooperative bound; pread/pwrite/fsync are
 * not preemptible. Caller must inspect slice reason, never assume readiness.
 * Concurrent workers provide no guarantee of a workload's measured speedup.
 */
FLOE_AE_API int floe_ae_run_slice(floe_ae_handle, uint64_t max_host_ns,
                                uint64_t max_instructions, floe_ae_slice *);
FLOE_AE_API int floe_ae_console_read(floe_ae_handle, void *, size_t capacity, size_t *read_count);
FLOE_AE_API int floe_ae_console_write(floe_ae_handle, const void *, size_t length, size_t *accepted);
FLOE_AE_API int floe_ae_diagnostic_read(floe_ae_handle, void *, size_t capacity, size_t *read_count);
/* stop is sticky and thread-safe; it never writes another worker's raw CPU
 * fields. After run_slice returns with workers quiescent, resume clears stop;
 * active resume/destroy is BUSY. Destroy joins owned workers before freeing.
 */
FLOE_AE_API int floe_ae_request_stop(floe_ae_handle);
FLOE_AE_API int floe_ae_resume(floe_ae_handle);
FLOE_AE_API int floe_ae_destroy(floe_ae_handle);
FLOE_AE_API int floe_ae_get_stats(floe_ae_handle, floe_ae_stats *);
/* Optional caller parking between slices. expected_sequence comes from last slice;
 * an input/stop/output-drain race returns immediately rather than losing a wake.
 * Combines CPU timer+RTC deadlines with control/input events. No fixed50ms poll.
 * max_wait_ns<=60s; a parked waiter pins the instance, so destroy returns BUSY.
 * No hart ID is baked into this aggregate Machine event API. It parks only
 * after all powered PEs sleep; OFF PEs require guest PSCI CPU_ON to start.
 */
FLOE_AE_API int floe_ae_wait_event(floe_ae_handle, uint64_t expected_sequence,
                                 uint64_t max_wait_ns, uint64_t *new_sequence);
#ifdef __cplusplus
}
#endif
#endif
