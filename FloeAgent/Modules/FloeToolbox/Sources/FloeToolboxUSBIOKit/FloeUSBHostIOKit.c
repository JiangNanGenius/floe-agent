// SPDX-License-Identifier: MPL-2.0
#include "FloeUSBHostIOKit.h"
#include "FloeUSBWire.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

// This is host IOKit only. It is deliberately separate from the wire C source
// that is also compiled inside DriverKit. No canImport or simulator exclusion.
static int32_t result(kern_return_t status) {
    return status == kIOReturnUnsupported ? FLOE_USB_HOST_UNSUPPORTED : (int32_t)status;
}
static int string_equals(io_registry_entry_t entry, CFStringRef key, CFStringRef expected) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    int equal = value && CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, expected);
    if (value) CFRelease(value);
    return equal;
}
static int number(io_registry_entry_t entry, CFStringRef key, int64_t minimum, int64_t maximum, int64_t *output) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    int64_t integer = 0;
    int valid = value && CFGetTypeID(value) == CFNumberGetTypeID() && !CFNumberIsFloatType(value) &&
        CFNumberGetValue(value, kCFNumberSInt64Type, &integer) && integer >= minimum && integer <= maximum;
    if (value) CFRelease(value);
    if (valid) *output = integer;
    return valid;
}
static int same_identity(const FloeUSBRegistryIdentity *a, const FloeUSBRegistryIdentity *b) {
    return a->serviceID == b->serviceID && a->providerID == b->providerID && a->deviceID == b->deviceID &&
        a->vendor == b->vendor && a->product == b->product && a->configuration == b->configuration &&
        a->interfaceNumber == b->interfaceNumber && a->interfaceClass == b->interfaceClass &&
        a->interfaceSubclass == b->interfaceSubclass && a->interfaceProtocol == b->interfaceProtocol;
}
static int32_t identity(io_service_t service, FloeUSBRegistryIdentity *output) {
    memset(output, 0, sizeof(*output));
    if (!IOObjectConformsTo(service, "IOUserService") ||
        !string_equals(service, CFSTR("IOUserClass"), CFSTR("FloeUSBSerialDriver")) ||
        !string_equals(service, CFSTR("IOUserServerName"), CFSTR("org.floeagent.ios.FloeUSBSerialDriver")))
        return FLOE_USB_HOST_IDENTITY_UNAVAILABLE;
    io_registry_entry_t provider = 0, device = 0;
    int32_t status = FLOE_USB_HOST_IDENTITY_UNAVAILABLE;
    int64_t vendor, product, configuration, number_, class_, subclass, protocol;
    if (IORegistryEntryGetRegistryEntryID(service, &output->serviceID) != KERN_SUCCESS || !output->serviceID ||
        IORegistryEntryGetParentEntry(service, kIOServicePlane, &provider) != KERN_SUCCESS || !provider)
        goto done;
    if (!IOObjectConformsTo(provider, "IOUSBHostInterface") ||
        IORegistryEntryGetRegistryEntryID(provider, &output->providerID) != KERN_SUCCESS || !output->providerID ||
        !number(provider, CFSTR("bConfigurationValue"), 1, 255, &configuration) ||
        !number(provider, CFSTR("bInterfaceNumber"), 0, 255, &number_) ||
        !number(provider, CFSTR("bInterfaceClass"), 0, 255, &class_) ||
        !number(provider, CFSTR("bInterfaceSubClass"), 0, 255, &subclass) ||
        !number(provider, CFSTR("bInterfaceProtocol"), 0, 255, &protocol)) goto done;
    // Follow only this provider's bounded service-plane ancestry, never an
    // arbitrary global device or a first vendor/product match.
    if (IORegistryEntryGetParentEntry(provider, kIOServicePlane, &device) != KERN_SUCCESS || !device) goto done;
    for (unsigned depth = 0; depth < 8; ++depth) {
        if (IOObjectConformsTo(device, "IOUSBHostDevice")) break;
        if (depth == 7) goto done;
        io_registry_entry_t parent = 0;
        kern_return_t parentStatus = IORegistryEntryGetParentEntry(device, kIOServicePlane, &parent);
        IOObjectRelease(device); device = parent;
        if (parentStatus != KERN_SUCCESS || !device) goto done;
    }
    if (IORegistryEntryGetRegistryEntryID(device, &output->deviceID) != KERN_SUCCESS || !output->deviceID ||
        !number(device, CFSTR("idVendor"), 1, 65535, &vendor) ||
        !number(device, CFSTR("idProduct"), 0, 65535, &product)) goto done;
    output->vendor = (uint16_t)vendor; output->product = (uint16_t)product;
    output->configuration = (uint8_t)configuration; output->interfaceNumber = (uint8_t)number_;
    output->interfaceClass = (uint8_t)class_; output->interfaceSubclass = (uint8_t)subclass;
    output->interfaceProtocol = (uint8_t)protocol;
    status = 0;
done:
    if (device) IOObjectRelease(device);
    if (provider) IOObjectRelease(provider);
    if (status) memset(output, 0, sizeof(*output));
    return status;
}
int32_t floe_usb_host_discover(FloeUSBRegistryIdentity *devices, size_t capacity, size_t *count) {
    if (count) *count = 0;
    if (!devices || !count || !capacity || capacity > FLOE_USB_HOST_MAX_DEVICES) return FLOE_USB_HOST_INVALID_ARGUMENT;
    memset(devices, 0, sizeof(*devices) * capacity);
    CFMutableDictionaryRef matching = IOServiceMatching("IOUserService");
    if (!matching) return FLOE_USB_HOST_IDENTITY_UNAVAILABLE;
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties) { CFRelease(matching); return FLOE_USB_HOST_IDENTITY_UNAVAILABLE; }
    CFDictionarySetValue(properties, CFSTR("IOUserClass"), CFSTR("FloeUSBSerialDriver"));
    CFDictionarySetValue(properties, CFSTR("IOUserServerName"), CFSTR("org.floeagent.ios.FloeUSBSerialDriver"));
    CFDictionarySetValue(matching, CFSTR("IOPropertyMatch"), properties); CFRelease(properties);
    io_iterator_t iterator = 0;
    kern_return_t found = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator); // consumes matching
    if (found != KERN_SUCCESS) { if (iterator) IOObjectRelease(iterator); return result(found); }
    if (!iterator) return 0; // A successful empty lookup is not a grant or enabled-state receipt.
    int32_t status = 0; size_t used = 0, scanned = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (++scanned > FLOE_USB_HOST_MAX_SCANNED || used == capacity) {
            IOObjectRelease(service); status = FLOE_USB_HOST_LIMIT; break;
        }
        status = identity(service, &devices[used]); IOObjectRelease(service);
        if (status) break; // Do not misreport an unreadable own service as an empty list.
        for (size_t i = 0; i < used; ++i) {
            if (devices[i].serviceID == devices[used].serviceID) { status = FLOE_USB_HOST_IDENTITY_CHANGED; break; }
        }
        if (status) break;
        ++used;
    }
    if (!status && !IOIteratorIsValid(iterator)) status = FLOE_USB_HOST_IDENTITY_CHANGED;
    IOObjectRelease(iterator);
    if (status) { memset(devices, 0, sizeof(*devices) * capacity); return status; }
    *count = used; return 0;
}
int32_t floe_usb_host_open(const FloeUSBRegistryIdentity *expected, uint32_t *connection) {
    if (connection) *connection = 0;
    if (!expected || !connection || !expected->serviceID || !expected->providerID || !expected->deviceID)
        return FLOE_USB_HOST_INVALID_ARGUMENT;
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(expected->serviceID);
    if (!matching) return FLOE_USB_HOST_IDENTITY_UNAVAILABLE;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching); // consumes matching
    if (!service) return FLOE_USB_HOST_IDENTITY_CHANGED;
    FloeUSBRegistryIdentity actual;
    int32_t status = identity(service, &actual);
    if (!status && !same_identity(expected, &actual)) status = FLOE_USB_HOST_IDENTITY_CHANGED;
    io_connect_t opened = 0;
    if (!status) status = result(IOServiceOpen(service, mach_task_self_, 0, &opened));
    if (!status && !opened) status = FLOE_USB_HOST_IDENTITY_UNAVAILABLE;
    if (!status) {
        status = identity(service, &actual);
        if (!status && !same_identity(expected, &actual)) status = FLOE_USB_HOST_IDENTITY_CHANGED;
    }
    IOObjectRelease(service);
    if (status) { if (opened) IOServiceClose(opened); return status; }
    *connection = opened; return 0;
}
int32_t floe_usb_host_exchange(uint32_t connection, const void *request, size_t requestSize,
                               void *reply, size_t *replySize) {
    FloeUSBRequest verified;
    if (!connection || !request || !reply || !replySize ||
        *replySize < sizeof(FloeUSBResponse) || *replySize > sizeof(FloeUSBResponse) + FLOE_USB_MAX_PAYLOAD ||
        !floe_usb_validate_request(request, requestSize, &verified)) return FLOE_USB_HOST_INVALID_ARGUMENT;
    size_t capacity = *replySize;
    kern_return_t status = IOConnectCallStructMethod(connection, 0, request, requestSize, reply, replySize);
    if (status != KERN_SUCCESS) { *replySize = 0; return result(status); }
    if (*replySize > capacity) { *replySize = 0; return FLOE_USB_HOST_LIMIT; }
    return 0;
}
int32_t floe_usb_host_close(uint32_t connection) {
    return connection ? result(IOServiceClose(connection)) : 0;
}
