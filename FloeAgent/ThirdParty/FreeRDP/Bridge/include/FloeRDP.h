// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_RDP_H
#define FLOE_RDP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloeRDP FloeRDP;
typedef enum {
    FLOE_RDP_STOPPED = 0, FLOE_RDP_CONNECTING = 1,
    FLOE_RDP_CONNECTED = 2, FLOE_RDP_FAILED = 3
} FloeRDPState;
typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *password;
    const char *domain;
    uint32_t width;
    uint32_t height;
} FloeRDPOptions;
typedef struct {
    void *user;
    // Callbacks run on the worker. Copy pixel/certificate bytes before return.
    // Never destroy the session synchronously from a callback.
    void (*state)(void *user, FloeRDPState state, uint32_t error);
    void (*frame)(void *user, const uint8_t *bgra, uint32_t width,
                  uint32_t height, uint32_t stride);
    // Required: evaluate system hostname/chain trust or an explicit user pin.
    // Return 1 only if accepted. Missing callbacks reject all certificates.
    int (*certificate)(void *user, const uint8_t *pem, size_t length,
                       const char *host, uint16_t port);
} FloeRDPCallbacks;

// Copies options. The caller owns callback context through successful destroy.
FloeRDP *floe_rdp_create(const FloeRDPOptions *options, FloeRDPCallbacks callbacks);
int floe_rdp_start(FloeRDP *session);
void floe_rdp_stop(FloeRDP *session);
// Stops, joins, then frees. Call off the UI/worker thread, after excluding other
// callers. Returns 0 on the worker thread; no memory is freed in that case.
int floe_rdp_destroy(FloeRDP *session);
// Entire input batches are admitted atomically; overflow returns failure.
// Flags use the public RDP input protocol bitfields, not platform key codes.
typedef struct {
    uint16_t kind; // 0 mouse, 1 scan code, 2 UTF-16 code unit
    uint16_t flags;
    uint16_t code;
    uint16_t x;
    uint16_t y;
} FloeRDPInput;
int floe_rdp_input(FloeRDP *session, const FloeRDPInput *events, size_t count);
const char *floe_rdp_version(void);
#ifdef __cplusplus
}
#endif
#endif
