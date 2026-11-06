#pragma once
#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>

// Owned by one DriverKit service. Caller keeps the object alive for each method invocation.
// The service opens the provider; this backend retains it and serializes transfers/detach.
// No App entitlement, activation or USB device matching is changed by this component.
class FloeUSBSerialBackend final {
public:
    FloeUSBSerialBackend();
    ~FloeUSBSerialBackend();
    FloeUSBSerialBackend(const FloeUSBSerialBackend&) = delete;
    FloeUSBSerialBackend& operator=(const FloeUSBSerialBackend&) = delete;

    IOReturn attach(IOUSBHostInterface *interface, uint8_t inputEndpoint, uint8_t outputEndpoint);
    void detach();
    IOReturn control(uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                     void *bytes, uint16_t length, uint32_t timeoutMS, uint16_t *actual);
    IOReturn read(void *bytes, uint32_t capacity, uint32_t timeoutMS, uint32_t *actual);
    IOReturn write(const void *bytes, uint32_t length, uint32_t timeoutMS, uint32_t *actual);

private:
    static constexpr uint32_t maximumTransfer = 65536;
    IOLock *lock_ = nullptr;
    IOUSBHostInterface *interface_ = nullptr;
    IOUSBHostPipe *input_ = nullptr;
    IOUSBHostPipe *output_ = nullptr;
    IOBufferMemoryDescriptor *buffer_ = nullptr;
    uint8_t *mapped_ = nullptr;
    void releaseUnlocked();
    IOReturn transfer(bool read, void *bytes, uint32_t length, uint32_t timeoutMS, uint32_t *actual);
};
