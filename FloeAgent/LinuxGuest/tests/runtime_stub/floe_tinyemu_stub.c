/*
 * floe_tinyemu_stub.c — host-only stand-in for the FloeTinyEMU engine.
 * See floe_tinyemu_stub.h. Compiled for the RuntimeLifecycleCheck harness
 * only; never linked into the app.
 */
#include "floe_tinyemu_stub.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct FloeVM {
    uint64_t magic;
    int destroyed;
    int in_slice;
};

#define STUB_MAGIC 0x464c4f45564dULL

static int g_slice_ms = 2;
static int g_slices_before_poweroff = 0;
static int g_destroy_while_slicing = 0;
static int g_use_after_destroy = 0;
static int g_console_input_calls = 0;
static int g_partial_accept = -1;
static long g_console_bytes = 0;
static unsigned long long g_console_checksum = 0;
static int g_hostfwd_add_calls = 0;
static int g_slice_calls = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void sleep_ms(int ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

void floe_stub_set_slice_ms(int ms) {
    pthread_mutex_lock(&g_lock);
    g_slice_ms = ms < 0 ? 0 : ms;
    pthread_mutex_unlock(&g_lock);
}

void floe_stub_set_slices_before_poweroff(int slices) {
    pthread_mutex_lock(&g_lock);
    g_slices_before_poweroff = slices < 0 ? 0 : slices;
    pthread_mutex_unlock(&g_lock);
}

int floe_stub_destroy_while_slicing(void) {
    pthread_mutex_lock(&g_lock);
    int value = g_destroy_while_slicing;
    pthread_mutex_unlock(&g_lock);
    return value;
}

int floe_stub_use_after_destroy(void) {
    pthread_mutex_lock(&g_lock);
    int value = g_use_after_destroy;
    pthread_mutex_unlock(&g_lock);
    return value;
}

int floe_stub_console_input_calls(void) {
    pthread_mutex_lock(&g_lock);
    int value = g_console_input_calls;
    pthread_mutex_unlock(&g_lock);
    return value;
}

int floe_stub_hostfwd_add_calls(void) {
    pthread_mutex_lock(&g_lock);
    int value = g_hostfwd_add_calls;
    pthread_mutex_unlock(&g_lock);
    return value;
}

int floe_stub_slice_calls(void) {
    pthread_mutex_lock(&g_lock);
    int value = g_slice_calls;
    pthread_mutex_unlock(&g_lock);
    return value;
}

static int check_live(FloeVM *vm) {
    if (!vm || vm->magic != STUB_MAGIC || vm->destroyed) {
        pthread_mutex_lock(&g_lock);
        g_use_after_destroy = 1;
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    return 0;
}

FloeVM *floe_vm_create(const FloeVMConfig *cfg,
                       FloeVMConsoleOutFn out_fn, void *out_opaque) {
    (void)out_fn;
    (void)out_opaque;
    if (!cfg || !cfg->bios_path) return NULL;
    FloeVM *vm = calloc(1, sizeof *vm);
    if (!vm) return NULL;
    vm->magic = STUB_MAGIC;
    pthread_mutex_lock(&g_lock);
    g_slice_calls = 0;
    pthread_mutex_unlock(&g_lock);
    return vm;
}

int floe_vm_console_input(FloeVM *vm, const uint8_t *data, int len) {
    if (check_live(vm) != 0) return -1;
    if (len < 0 || (!data && len > 0)) return -1;
    pthread_mutex_lock(&g_lock);
    int n = len;
    if (g_partial_accept == 0) n = 0;
    else if (g_partial_accept > 0 && n > g_partial_accept) n = g_partial_accept;
    for (int i = 0; i < n; i++) {
        g_console_checksum = g_console_checksum * 31u + (unsigned long long)data[i];
    }
    g_console_bytes += n;
    g_console_input_calls++;
    pthread_mutex_unlock(&g_lock);
    return n;
}

void floe_stub_reset_console_counters(void) {
    pthread_mutex_lock(&g_lock);
    g_console_bytes = 0;
    g_console_checksum = 0;
    g_console_input_calls = 0;
    pthread_mutex_unlock(&g_lock);
}

void floe_stub_set_partial_accept(int max_bytes) {
    pthread_mutex_lock(&g_lock);
    g_partial_accept = max_bytes;
    pthread_mutex_unlock(&g_lock);
}

long floe_stub_console_bytes_received(void) {
    pthread_mutex_lock(&g_lock);
    long value = g_console_bytes;
    pthread_mutex_unlock(&g_lock);
    return value;
}

unsigned long long floe_stub_console_checksum(void) {
    pthread_mutex_lock(&g_lock);
    unsigned long long value = g_console_checksum;
    pthread_mutex_unlock(&g_lock);
    return value;
}

int floe_vm_run_slice(FloeVM *vm, int timeout_ms) {
    (void)timeout_ms;
    if (check_live(vm) != 0) return -1;
    pthread_mutex_lock(&g_lock);
    vm->in_slice = 1;
    int slice_ms = g_slice_ms;
    g_slice_calls++;
    int count = g_slice_calls;
    int poweroff_after = g_slices_before_poweroff;
    pthread_mutex_unlock(&g_lock);
    sleep_ms(slice_ms);
    pthread_mutex_lock(&g_lock);
    vm->in_slice = 0;
    pthread_mutex_unlock(&g_lock);
    if (poweroff_after > 0 && count >= poweroff_after) return 1;
    return 0;
}

int floe_vm_poweroff_requested(const FloeVM *vm) {
    if (!vm || vm->magic != STUB_MAGIC || vm->destroyed) return 0;
    return 0;
}

int floe_vm_hostfwd_add(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                        int host_port, uint32_t guest_ipv4, int guest_port) {
    (void)is_udp; (void)host_ipv4; (void)host_port; (void)guest_ipv4; (void)guest_port;
    if (check_live(vm) != 0) return -1;
    pthread_mutex_lock(&g_lock);
    g_hostfwd_add_calls++;
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int floe_vm_hostfwd_remove(FloeVM *vm, int is_udp, uint32_t host_ipv4,
                           int host_port) {
    (void)is_udp; (void)host_ipv4; (void)host_port;
    if (check_live(vm) != 0) return -1;
    return 0;
}

void floe_vm_destroy(FloeVM *vm) {
    if (!vm || vm->magic != STUB_MAGIC) return;
    pthread_mutex_lock(&g_lock);
    if (vm->in_slice) g_destroy_while_slicing = 1;
    vm->destroyed = 1;
    pthread_mutex_unlock(&g_lock);
    vm->magic = 0;
    free(vm);
}

const char *floe_vm_engine_version(void) { return "stub-2019-12-21"; }
