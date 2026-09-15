// SPDX-License-Identifier: MPL-2.0
#include "FloeRDP.h"
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <freerdp/version.h>
#include <winpr/synch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define INPUT_CAPACITY 16384u
#define INPUT_BATCH 256u
#define MAX_FRAME_BYTES (32u * 1024u * 1024u)
#define FLOE_ERROR_INPUT 0xF10E0001u
#define FLOE_ERROR_FRAME 0xF10E0002u
#define FLOE_ERROR_WAIT 0xF10E0003u

typedef struct { rdpContext context; struct FloeRDP *owner; } FloeRDPContext;
struct FloeRDP {
    freerdp *instance;
    FloeRDPCallbacks callbacks;
    pthread_t worker;
    pthread_mutex_t input_lock;
    HANDLE wake;
    atomic_bool stopping;
    atomic_bool connected;
    int started;
    FloeRDPInput inputs[INPUT_CAPACITY];
    size_t input_head;
    size_t input_count;
    uint32_t local_error;
};

static FloeRDP *owner(rdpContext *context) {
    return ((FloeRDPContext *)context)->owner;
}
static void report(FloeRDP *s, FloeRDPState state, uint32_t error) {
    if (s->callbacks.state) s->callbacks.state(s->callbacks.user, state, error);
}
static int valid_size(uint32_t width, uint32_t height, uint32_t stride) {
    return width > 0 && height > 0 && width <= 4096 && height <= 4096 &&
           stride >= width * 4u && (uint64_t)stride * height <= MAX_FRAME_BYTES;
}
static BOOL begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc) return FALSE;
    HGDI_WND window = gdi->primary->hdc->hwnd;
    if (window && window->invalid) window->invalid->null = TRUE;
    return !atomic_load(&owner(context)->stopping);
}
static BOOL end_paint(rdpContext *context) {
    FloeRDP *s = owner(context);
    rdpGdi *gdi = context->gdi;
    if (atomic_load(&s->stopping)) return FALSE;
    if (!gdi || !gdi->primary_buffer ||
        !valid_size((uint32_t)gdi->width, (uint32_t)gdi->height, gdi->stride)) {
        s->local_error = FLOE_ERROR_FRAME;
        return FALSE;
    }
    // EndPaint can run for protocol batches with no dirty pixels. Publishing
    // these would repeatedly copy a full desktop and invalidate tool evidence.
    if (gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd &&
        gdi->primary->hdc->hwnd->invalid && gdi->primary->hdc->hwnd->invalid->null)
        return TRUE;
    if (s->callbacks.frame)
        s->callbacks.frame(s->callbacks.user, gdi->primary_buffer,
                           (uint32_t)gdi->width, (uint32_t)gdi->height, gdi->stride);
    return TRUE;
}
static BOOL desktop_resize(rdpContext *context) {
    uint32_t width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    uint32_t height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!valid_size(width, height, width * 4u)) {
        owner(context)->local_error = FLOE_ERROR_FRAME;
        return FALSE;
    }
    return gdi_resize(context->gdi, width, height);
}
static BOOL post_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    uint32_t width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    uint32_t height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!valid_size(width, height, width * 4u)) {
        owner(context)->local_error = FLOE_ERROR_FRAME;
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    context->update->BeginPaint = begin_paint;
    context->update->EndPaint = end_paint;
    context->update->DesktopResize = desktop_resize;
    return TRUE;
}
static void post_disconnect(freerdp *instance) {
    if (instance->context->gdi) gdi_free(instance);
}
static int verify_certificate(freerdp *instance, const BYTE *data, size_t length,
                              const char *host, UINT16 port, DWORD flags) {
    (void)flags;
    FloeRDP *s = owner(instance->context);
    if (atomic_load(&s->stopping) || !s->callbacks.certificate || !data ||
        length == 0 || length > 256u * 1024u) return 0;
    return s->callbacks.certificate(s->callbacks.user, data, length, host, port) == 1 ? 2 : 0;
}
static int drain_input(FloeRDP *s) {
    FloeRDPInput batch[INPUT_BATCH];
    pthread_mutex_lock(&s->input_lock);
    size_t count = s->input_count < INPUT_BATCH ? s->input_count : INPUT_BATCH;
    for (size_t i = 0; i < count; ++i)
        batch[i] = s->inputs[(s->input_head + i) % INPUT_CAPACITY];
    s->input_head = (s->input_head + count) % INPUT_CAPACITY;
    s->input_count -= count;
    // Reset while holding the same lock used by producers; never lose a wake.
    if (s->input_count == 0) ResetEvent(s->wake);
    pthread_mutex_unlock(&s->input_lock);
    rdpInput *input = s->instance->context->input;
    for (size_t i = 0; i < count; ++i) {
        if (atomic_load(&s->stopping)) return 0;
        FloeRDPInput e = batch[i];
        BOOL ok = FALSE;
        switch (e.kind) {
            case 0: ok = freerdp_input_send_mouse_event(input, e.flags, e.x, e.y); break;
            case 1: ok = freerdp_input_send_keyboard_event(input, e.flags, (UINT8)e.code); break;
            case 2: ok = freerdp_input_send_unicode_keyboard_event(input, e.flags, e.code); break;
            default: break;
        }
        if (!ok) { s->local_error = FLOE_ERROR_INPUT; return 0; }
    }
    return 1;
}
static void *run(void *argument) {
    FloeRDP *s = argument;
    // The start barrier publishes worker identity before any user callback.
    pthread_mutex_lock(&s->input_lock);
    pthread_mutex_unlock(&s->input_lock);
    report(s, FLOE_RDP_CONNECTING, 0);
    BOOL connected = !atomic_load(&s->stopping) && freerdp_connect(s->instance);
    if (connected && !atomic_load(&s->stopping)) {
        atomic_store(&s->connected, true);
        report(s, FLOE_RDP_CONNECTED, 0);
        while (!atomic_load(&s->stopping) &&
               !freerdp_shall_disconnect_context(s->instance->context)) {
            HANDLE handles[64];
            DWORD count = freerdp_get_event_handles(s->instance->context, handles, 63);
            if (count == 0 || count > 63) { s->local_error = FLOE_ERROR_WAIT; break; }
            handles[count++] = s->wake;
            DWORD status = WaitForMultipleObjects(count, handles, FALSE, 100);
            if (status == WAIT_FAILED) { s->local_error = FLOE_ERROR_WAIT; break; }
            if (!drain_input(s)) break;
            if (!freerdp_check_event_handles(s->instance->context)) break;
        }
    }
    atomic_store(&s->connected, false);
    uint32_t error = s->local_error ? s->local_error : freerdp_get_last_error(s->instance->context);
    if (connected) { BOOL ignored = freerdp_disconnect(s->instance); (void)ignored; }
    if (!atomic_load(&s->stopping) && (!connected || error)) report(s, FLOE_RDP_FAILED, error);
    else report(s, FLOE_RDP_STOPPED, 0);
    return NULL;
}

FloeRDP *floe_rdp_create(const FloeRDPOptions *o, FloeRDPCallbacks callbacks) {
    if (!o || !o->host || !o->host[0] || !o->username || !o->username[0] ||
        !o->password || !o->port || !valid_size(o->width, o->height, o->width * 4u) ||
        !callbacks.certificate || !callbacks.frame) return NULL;
    FloeRDP *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->callbacks = callbacks;
    atomic_init(&s->stopping, false);
    atomic_init(&s->connected, false);
    if (pthread_mutex_init(&s->input_lock, NULL) != 0) { free(s); return NULL; }
    s->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
    s->instance = freerdp_new();
    if (!s->wake || !s->instance) goto fail;
    s->instance->ContextSize = sizeof(FloeRDPContext);
    s->instance->PostConnect = post_connect;
    s->instance->PostDisconnect = post_disconnect;
    s->instance->VerifyX509Certificate = verify_certificate;
    if (!freerdp_context_new(s->instance)) goto fail;
    ((FloeRDPContext *)s->instance->context)->owner = s;
    rdpSettings *settings = s->instance->context->settings;
#define SET_STRING(key, value) if (!freerdp_settings_set_string(settings, key, value)) goto fail
#define SET_UINT(key, value) if (!freerdp_settings_set_uint32(settings, key, value)) goto fail
#define SET_BOOL(key, value) if (!freerdp_settings_set_bool(settings, key, value)) goto fail
    SET_STRING(FreeRDP_ServerHostname, o->host);
    SET_STRING(FreeRDP_Username, o->username);
    SET_STRING(FreeRDP_Password, o->password);
    SET_STRING(FreeRDP_Domain, o->domain ? o->domain : "");
    SET_UINT(FreeRDP_ServerPort, o->port);
    SET_UINT(FreeRDP_DesktopWidth, o->width);
    SET_UINT(FreeRDP_DesktopHeight, o->height);
    SET_UINT(FreeRDP_ColorDepth, 32);
    SET_UINT(FreeRDP_TcpConnectTimeout, 15000);
    SET_BOOL(FreeRDP_ExternalCertificateManagement, TRUE);
    SET_BOOL(FreeRDP_TlsSecurity, TRUE);
    SET_BOOL(FreeRDP_NlaSecurity, TRUE);
    SET_BOOL(FreeRDP_RdpSecurity, FALSE);
    SET_BOOL(FreeRDP_Authentication, TRUE);
    SET_BOOL(FreeRDP_SoftwareGdi, TRUE);
    SET_BOOL(FreeRDP_SupportGraphicsPipeline, FALSE);
    SET_BOOL(FreeRDP_GfxH264, FALSE);
    SET_BOOL(FreeRDP_DesktopResize, TRUE);
    SET_BOOL(FreeRDP_RedirectClipboard, FALSE);
    SET_BOOL(FreeRDP_RedirectDrives, FALSE);
    SET_BOOL(FreeRDP_RedirectPrinters, FALSE);
    SET_BOOL(FreeRDP_RedirectSmartCards, FALSE);
    SET_BOOL(FreeRDP_RedirectSerialPorts, FALSE);
#undef SET_STRING
#undef SET_UINT
#undef SET_BOOL
    return s;
fail:
    if (s->instance) {
        if (s->instance->context) freerdp_context_free(s->instance);
        freerdp_free(s->instance);
    }
    if (s->wake) CloseHandle(s->wake);
    pthread_mutex_destroy(&s->input_lock);
    free(s);
    return NULL;
}
int floe_rdp_start(FloeRDP *s) {
    if (!s || s->started || atomic_load(&s->stopping)) return 0;
    pthread_mutex_lock(&s->input_lock);
    int result = pthread_create(&s->worker, NULL, run, s);
    s->started = result == 0;
    pthread_mutex_unlock(&s->input_lock);
    return result == 0;
}
void floe_rdp_stop(FloeRDP *s) {
    if (!s) return;
    atomic_store(&s->stopping, true);
    atomic_store(&s->connected, false);
    BOOL ignored = freerdp_abort_connect_context(s->instance->context);
    (void)ignored;
    SetEvent(s->wake);
}
int floe_rdp_destroy(FloeRDP *s) {
    if (!s) return 1;
    if (s->started && pthread_equal(pthread_self(), s->worker)) return 0;
    floe_rdp_stop(s);
    if (s->started && pthread_join(s->worker, NULL) != 0) return 0;
    freerdp_context_free(s->instance);
    freerdp_free(s->instance);
    CloseHandle(s->wake);
    pthread_mutex_destroy(&s->input_lock);
    free(s);
    return 1;
}
int floe_rdp_input(FloeRDP *s, const FloeRDPInput *events, size_t count) {
    if (!s || !events || count == 0 || count > INPUT_CAPACITY ||
        !atomic_load(&s->connected) || atomic_load(&s->stopping)) return 0;
    for (size_t i = 0; i < count; ++i)
        if (events[i].kind > 2 || (events[i].kind == 1 && events[i].code > 255)) return 0;
    pthread_mutex_lock(&s->input_lock);
    if (s->input_count + count > INPUT_CAPACITY || atomic_load(&s->stopping)) {
        pthread_mutex_unlock(&s->input_lock); return 0;
    }
    for (size_t i = 0; i < count; ++i)
        s->inputs[(s->input_head + s->input_count + i) % INPUT_CAPACITY] = events[i];
    s->input_count += count;
    SetEvent(s->wake);
    pthread_mutex_unlock(&s->input_lock);
    return 1;
}
const char *floe_rdp_version(void) { return FREERDP_VERSION_FULL; }
