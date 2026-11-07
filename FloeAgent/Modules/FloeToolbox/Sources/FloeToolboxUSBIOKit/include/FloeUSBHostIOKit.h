// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_USB_HOST_IOKIT_H
#define FLOE_USB_HOST_IOKIT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define FLOE_USB_HOST_MAX_DEVICES 32u
#define FLOE_USB_HOST_MAX_SCANNED 256u
#define FLOE_USB_HOST_INVALID_ARGUMENT (-1)
#define FLOE_USB_HOST_IDENTITY_UNAVAILABLE (-2)
#define FLOE_USB_HOST_IDENTITY_CHANGED (-3)
#define FLOE_USB_HOST_LIMIT (-4)
#define FLOE_USB_HOST_UNSUPPORTED (-5)

/// A transient native registry observation, not a durable ID or permission.
typedef struct {
    uint64_t serviceID;
    uint64_t providerID;
    uint64_t deviceID;
    uint16_t vendor;
    uint16_t product;
    uint8_t configuration;
    uint8_t interfaceNumber;
    uint8_t interfaceClass;
    uint8_t interfaceSubclass;
    uint8_t interfaceProtocol;
} FloeUSBRegistryIdentity;

/// Matches only the fixed Floe driver class/server and its actual USB provider.
/// Never opens a user client or sends a USB control transfer during discovery.
int32_t floe_usb_host_discover(FloeUSBRegistryIdentity *devices, size_t capacity, size_t *count);
/// Revalidates the exact selected identity immediately before AND after open.
/// Failure closes any created connection and leaves *connection == 0.
int32_t floe_usb_host_open(const FloeUSBRegistryIdentity *expected, uint32_t *connection);
int32_t floe_usb_host_exchange(uint32_t connection, const void *request, size_t requestSize,
                               void *reply, size_t *replySize);
int32_t floe_usb_host_close(uint32_t connection);
#ifdef __cplusplus
}
#endif
#endif
