#include "USBSerialBackend.hpp"
#include <string.h>

FloeUSBSerialBackend::FloeUSBSerialBackend() { lock_ = IOLockAlloc(); }
FloeUSBSerialBackend::~FloeUSBSerialBackend() {
    detach();
    if (lock_) { IOLockFree(lock_); lock_ = nullptr; }
}
void FloeUSBSerialBackend::releaseUnlocked() {
    mapped_ = nullptr;
    if (input_) { input_->release(); input_ = nullptr; }
    if (output_) { output_->release(); output_ = nullptr; }
    if (buffer_) { buffer_->release(); buffer_ = nullptr; }
    if (interface_) { interface_->release(); interface_ = nullptr; }
}
IOReturn FloeUSBSerialBackend::attach(IOUSBHostInterface *interface, uint8_t inEP, uint8_t outEP) {
    if (!lock_) return kIOReturnNoMemory;
    if (!interface || !(inEP & 0x80) || (outEP & 0x80) || (inEP & 0x0f) == 0 || (outEP & 0x0f) == 0)
        return kIOReturnBadArgument;
    IOLockLock(lock_);
    if (interface_) { IOLockUnlock(lock_); return kIOReturnBusy; }
    interface_ = interface; interface_->retain();
    IOReturn status = interface_->CopyPipe(inEP, &input_);
    if (status == kIOReturnSuccess && input_) status = interface_->CopyPipe(outEP, &output_);
    if (status == kIOReturnSuccess && input_ && output_)
        status = interface_->CreateIOBuffer(kIOMemoryDirectionInOut, maximumTransfer, &buffer_);
    if (status == kIOReturnSuccess && buffer_) {
        IOAddressSegment segment = {};
        status = buffer_->GetAddressRange(&segment);
        if (status == kIOReturnSuccess && segment.address && segment.length >= maximumTransfer)
            mapped_ = reinterpret_cast<uint8_t *>(segment.address);
        else status = kIOReturnNoMemory;
    }
    if (status != kIOReturnSuccess || !input_ || !output_ || !buffer_ || !mapped_) {
        releaseUnlocked();
        if (status == kIOReturnSuccess) status = kIOReturnNoDevice;
    }
    IOLockUnlock(lock_);
    return status;
}
void FloeUSBSerialBackend::detach() {
    if (!lock_) return;
    IOLockLock(lock_);
    releaseUnlocked();
    IOLockUnlock(lock_);
}
IOReturn FloeUSBSerialBackend::control(uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                                     void *bytes, uint16_t length, uint32_t timeoutMS, uint16_t *actual) {
    if (actual) *actual = 0;
    if (!lock_) return kIOReturnNoMemory;
    if (!actual || (length && !bytes) || length > 4096 || timeoutMS == 0 || timeoutMS > 5000) return kIOReturnBadArgument;
    IOLockLock(lock_);
    if (!interface_ || !buffer_ || !mapped_) { IOLockUnlock(lock_); return kIOReturnNoDevice; }
    const bool input = (type & 0x80) != 0;
    if (!input && length) memcpy(mapped_, bytes, length);
    IOReturn status = buffer_->SetLength(length ? length : 1);
    uint16_t transferred = 0;
    if (status == kIOReturnSuccess)
        status = interface_->DeviceRequest(type, request, value, index, length, buffer_, &transferred, timeoutMS);
    if (status == kIOReturnSuccess && transferred > length) status = kIOReturnOverrun;
    if (status == kIOReturnSuccess) {
        if (input && transferred) memcpy(bytes, mapped_, transferred);
        *actual = transferred;
    }
    IOLockUnlock(lock_);
    return status;
}
IOReturn FloeUSBSerialBackend::transfer(bool read, void *bytes, uint32_t length, uint32_t timeoutMS, uint32_t *actual) {
    if (actual) *actual = 0;
    if (!lock_) return kIOReturnNoMemory;
    if (!bytes || !actual || length == 0 || length > maximumTransfer || timeoutMS == 0 || timeoutMS > 5000)
        return kIOReturnBadArgument;
    IOLockLock(lock_);
    IOUSBHostPipe *pipe = read ? input_ : output_;
    if (!interface_ || !pipe || !buffer_ || !mapped_) { IOLockUnlock(lock_); return kIOReturnNoDevice; }
    if (!read) memcpy(mapped_, bytes, length);
    IOReturn status = buffer_->SetLength(length);
    uint32_t transferred = 0;
    if (status == kIOReturnSuccess) status = pipe->IO(buffer_, length, &transferred, timeoutMS);
    if (status == kIOReturnSuccess && transferred > length) status = kIOReturnOverrun;
    if (status == kIOReturnSuccess) {
        if (read && transferred) memcpy(bytes, mapped_, transferred);
        *actual = transferred;
        if (!read && transferred != length) status = kIOReturnUnderrun;
    }
    IOLockUnlock(lock_);
    return status;
}
IOReturn FloeUSBSerialBackend::read(void *bytes, uint32_t capacity, uint32_t timeoutMS, uint32_t *actual) {
    return transfer(true, bytes, capacity, timeoutMS, actual);
}
IOReturn FloeUSBSerialBackend::write(const void *bytes, uint32_t length, uint32_t timeoutMS, uint32_t *actual) {
    return transfer(false, const_cast<void *>(bytes), length, timeoutMS, actual);
}
