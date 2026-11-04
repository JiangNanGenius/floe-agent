/* SPDX-License-Identifier: MPL-2.0 */
#ifndef FLOE_ARM64EMU_H
#define FLOE_ARM64EMU_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI version 2 adds explicit device configuration (network/NAT, loopback
 * port forwards, contained host 9P shares, extra virtio-consoles with
 * geometry) and per-console channel operations. Version 1 callers keep the
 * exact version-1 contract: create accepts abi_version 1 with the original
 * struct, devices stay disabled, floe_ae_console_* remain the single PL011
 * channel. Nothing about the version-1 layout is reinterpreted. */
#define FLOE_AE_ABI_VERSION 2u
#define FLOE_AE_MAX_VCPUS 5u /* engine ceiling; caller chooses device limit before boot */
#define FLOE_AE_MAX_SHARES 8u
#define FLOE_AE_MAX_CONSOLES 8u
#define FLOE_AE_MAX_NET_FORWARDS 16u
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
/* ---- ABI version 2: explicit device configuration -----------------------
 *
 * Devices are configured at create time (they are built with the platform),
 * through floe_ae_config_v2 below. All strings are deep-copied during
 * create; callers retain ownership of their buffers. Every pointer may be
 * NULL when the corresponding count is 0.
 */
typedef struct {
    uint32_t struct_size;   /* == sizeof(floe_ae_share_config) */
    const char *host_path;  /* existing host directory; resolved and pinned at create */
    const char *mount_tag;  /* 9P2000.L mount tag, 1..127 bytes */
    uint32_t read_only;     /* whole-tree read-only */
    uint32_t reserved;
} floe_ae_share_config;

typedef struct {
    uint32_t struct_size;   /* == sizeof(floe_ae_net_forward) */
    uint32_t is_udp;        /* 0 = TCP listener, otherwise UDP socket */
    uint32_t host_port;     /* 1..65535; listeners always bind host loopback only */
    uint32_t guest_port;    /* 1..65535 on 10.0.2.15 */
} floe_ae_net_forward;

typedef struct {
    uint32_t struct_size;   /* == sizeof(floe_ae_devices_config) */
    uint32_t network_enabled; /* nonzero: virtio-net + built-in NAT */
    uint32_t virtio_consoles; /* extra hvc consoles, 0..FLOE_AE_MAX_CONSOLES */
    uint32_t share_count;   /* 0..FLOE_AE_MAX_SHARES */
    const floe_ae_share_config *shares;
    uint32_t forward_count; /* 0..FLOE_AE_MAX_NET_FORWARDS */
    const floe_ae_net_forward *forwards;
    /* Optional dotted-quad IPv4 of the resolver guest DNS (10.0.2.3) relays
     * to. NULL asks the engine to probe the host resolver (resolv.conf on
     * Linux/macOS, public res_ninit on Apple platforms). When no resolver can be determined
     * the engine reports dns_available == 0 in floe_ae_net_info and refuses
     * guest DNS with an honest unreachable notification; it never fabricates
     * a hardcoded public DNS. An explicit resolver may be supplied when required by the embedding app. */
    const char *dns_server;
    uint64_t reserved[4];
} floe_ae_devices_config;

/* Version 2 create configuration. abi_version must be 2 and struct_size at
 * least sizeof(floe_ae_config_v2); the embedded `machine` fields follow the
 * version-1 rules exactly (its own abi_version field carries the 2). */
typedef struct {
    floe_ae_config machine;
    floe_ae_devices_config devices;
} floe_ae_config_v2;

/* Console channel indices for the channel operations below: channel 0 is the
 * PL011 UART (the legacy floe_ae_console_* target); channels 1..N are the
 * virtio-consoles in creation order (hvc0 -> channel 1, hvc1 -> channel 2,
 * ...). channel_count reports 1 + the configured virtio console count. */
typedef struct {
    uint32_t struct_size;        /* == sizeof(floe_ae_net_info) */
    uint32_t network_enabled;
    uint32_t dns_available;      /* nonzero when a resolver relay target exists */
    uint32_t dns_server;         /* host-order IPv4 actually in use, else 0 */
    uint32_t forward_count;
    uint32_t active_tcp;         /* live TCP proxy connections */
    uint32_t active_udp;         /* live UDP NAT flows */
    uint32_t share_count;
    uint32_t console_count;      /* virtio consoles (excludes the PL011) */
    uint64_t rx_frames, tx_frames;   /* guest frames in / out of the device */
    uint64_t rx_refused;             /* frames the guest RX ring could not take */
    uint64_t reserved[4];
} floe_ae_net_info;
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
/* ---- ABI version 2 operations -------------------------------------------
 *
 * Channel operations are ring-buffered and bounded; partial reads/writes
 * return the actual counts. Geometry pushes mark the channel resized: the
 * next guest-visible poll raises the virtio config-change interrupt, so the
 * guest tty follows the host window without SIGWINCH or a host terminal.
 */
FLOE_AE_API int floe_ae_channel_count(floe_ae_handle, uint32_t *count);
FLOE_AE_API int floe_ae_channel_read(floe_ae_handle, uint32_t channel, void *, size_t capacity, size_t *read_count);
FLOE_AE_API int floe_ae_channel_write(floe_ae_handle, uint32_t channel, const void *, size_t length, size_t *accepted);
FLOE_AE_API int floe_ae_channel_get_winsize(floe_ae_handle, uint32_t channel, uint16_t *cols, uint16_t *rows);
FLOE_AE_API int floe_ae_channel_set_winsize(floe_ae_handle, uint32_t channel, uint16_t cols, uint16_t rows);
/* Live port-forward management (network must be enabled at create). Both
 * return FLOE_AE_OK or an honest error: FLOE_AE_INVALID (bad rule),
 * FLOE_AE_UNSUPPORTED (network disabled), FLOE_AE_IO (bind/listen failure,
 * e.g. EADDRINUSE from the host), FLOE_AE_NOT_PRESENT-style miss encoded as
 * FLOE_AE_INVALID for remove of a rule that does not exist. Listeners bind
 * host loopback only and are closed synchronously on remove/destroy. */
FLOE_AE_API int floe_ae_net_forward_add(floe_ae_handle, const floe_ae_net_forward *);
FLOE_AE_API int floe_ae_net_forward_remove(floe_ae_handle, uint32_t is_udp, uint32_t host_port);
FLOE_AE_API int floe_ae_net_get_info(floe_ae_handle, floe_ae_net_info *);
#ifdef __cplusplus
}
#endif
#endif
