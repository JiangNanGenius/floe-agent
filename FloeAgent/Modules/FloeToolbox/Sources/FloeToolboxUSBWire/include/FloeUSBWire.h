#ifndef FLOE_USB_WIRE_H
#define FLOE_USB_WIRE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
#define FLOE_USB_MAGIC 0x46555342u
#define FLOE_USB_VERSION 1u
#define FLOE_USB_MAX_PAYLOAD 3072u
#define FLOE_USB_OP_INFO 1u
#define FLOE_USB_OP_CONTROL 2u
#define FLOE_USB_OP_READ 3u
#define FLOE_USB_OP_WRITE 4u
typedef struct {
    uint32_t magic; uint16_t version; uint16_t operation;
    uint64_t generation; uint64_t requestID;
    uint32_t timeoutMS; uint32_t payloadSize; uint32_t capacity;
    uint16_t value; uint16_t index;
    uint8_t requestType; uint8_t request; uint8_t interfaceNumber; uint8_t reserved8;
    uint32_t reserved32;
} FloeUSBRequest;
typedef struct {
    uint32_t magic; uint16_t version; uint16_t operation;
    uint64_t generation; uint64_t requestID; int32_t status; uint32_t actual;
} FloeUSBResponse;
typedef struct {
    uint16_t vendor; uint16_t product; uint16_t usbVersion; uint16_t deviceVersion;
    uint16_t maximumPacketSize;
    uint8_t deviceClass; uint8_t controlPacketSize; uint8_t interfaceNumber; uint8_t interfaceClass;
    uint8_t interfaceSubclass; uint8_t controlInterface; uint8_t inputEndpoint; uint8_t outputEndpoint;
    uint8_t alternateSetting; uint8_t reserved[5];
} FloeUSBDeviceInfo;
typedef struct {
    uint8_t input; uint8_t output; uint8_t controlInterface; uint8_t interfaceClass;
    uint8_t interfaceSubclass; uint8_t alternateSetting; uint16_t maximumPacketSize;
} FloeUSBEndpoints;
bool floe_usb_validate_request(const void *bytes, size_t length, FloeUSBRequest *result);
bool floe_usb_validate_response(const void *bytes, size_t length, const FloeUSBRequest *request, FloeUSBResponse *result);
bool floe_usb_find_endpoints(const void *bytes, size_t length, uint8_t interfaceNumber, uint8_t alternateSetting, FloeUSBEndpoints *result);
#ifdef __cplusplus
}
static_assert(sizeof(FloeUSBRequest)==48,"USB request ABI");
static_assert(sizeof(FloeUSBResponse)==32,"USB response ABI");
static_assert(sizeof(FloeUSBDeviceInfo)==24,"USB device ABI");
#endif
#endif
