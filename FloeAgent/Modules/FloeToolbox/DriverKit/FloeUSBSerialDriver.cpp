#include "FloeUSBSerialDriver.h"
#include "FloeUSBSerialUserClient.h"
#include "USBSerialBackend.hpp"
#include "../Sources/FloeToolboxUSBWire/include/FloeUSBWire.h"
#include <DriverKit/OSData.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <stdlib.h>
#include <string.h>
struct FloeUSBSerialDriver_IVars {
    FloeUSBSerialBackend *backend;
    IOUSBHostInterface *interface;
    IOLock *lock;
    uint64_t generation;
    FloeUSBDeviceInfo info;
    bool active;
    bool clientClaimed;
};
struct FloeUSBSerialUserClient_IVars { FloeUSBSerialDriver *driver; bool claimed; uint64_t lastRequestID; };
bool FloeUSBSerialDriver::init() {
    if (!super::init()) return false;
    ivars=IONewZero(FloeUSBSerialDriver_IVars,1);
    if (!ivars) return false;
    ivars->lock=IOLockAlloc(); ivars->backend=new FloeUSBSerialBackend; ivars->generation=1;
    return ivars->lock && ivars->backend;
}
void FloeUSBSerialDriver::free() {
    if (ivars) { if (ivars->backend) delete ivars->backend; if (ivars->interface) ivars->interface->release(); if (ivars->lock) IOLockFree(ivars->lock); IODelete(ivars,FloeUSBSerialDriver_IVars,1); }
    super::free();
}
kern_return_t IMPL(FloeUSBSerialDriver,Start) {
    kern_return_t status=Start(provider,SUPERDISPATCH);
    if (status!=kIOReturnSuccess) return status;
    auto interface=OSDynamicCast(IOUSBHostInterface,provider);
    if (!interface || !ivars || !ivars->backend) return kIOReturnNoDevice;
    status=interface->Open(this,0,nullptr); if (status!=kIOReturnSuccess) return status;
    const IOUSBConfigurationDescriptor *configuration=interface->CopyConfigurationDescriptor();
    const IOUSBInterfaceDescriptor *descriptor=configuration ? interface->GetInterfaceDescriptor(configuration) : nullptr;
    FloeUSBEndpoints endpoints={}; IOUSBHostDevice *device=nullptr;
    const IOUSBDeviceDescriptor *deviceDescriptor=nullptr;
    if (!configuration || !descriptor) status=kIOReturnUnsupported;
    else {
        size_t total=(uint16_t)configuration->wTotalLength;
        if (!floe_usb_find_endpoints(configuration,total,descriptor->bInterfaceNumber,descriptor->bAlternateSetting,&endpoints)) status=kIOReturnUnsupported;
        else if (interface->CopyDevice(&device)!=kIOReturnSuccess || !device || !(deviceDescriptor=device->CopyDeviceDescriptor())) status=kIOReturnNoDevice;
        else {
            FloeUSBDeviceInfo info={}; info.vendor=deviceDescriptor->idVendor; info.product=deviceDescriptor->idProduct;
            info.usbVersion=deviceDescriptor->bcdUSB; info.deviceVersion=deviceDescriptor->bcdDevice;
            info.deviceClass=deviceDescriptor->bDeviceClass; info.controlPacketSize=deviceDescriptor->bMaxPacketSize0;
            info.interfaceNumber=descriptor->bInterfaceNumber; info.interfaceClass=endpoints.interfaceClass; info.interfaceSubclass=endpoints.interfaceSubclass;
            info.controlInterface=endpoints.controlInterface; info.inputEndpoint=endpoints.input; info.outputEndpoint=endpoints.output;
            info.maximumPacketSize=endpoints.maximumPacketSize; info.alternateSetting=endpoints.alternateSetting;
            status=ivars->backend->attach(interface,endpoints.input,endpoints.output);
            if (status==kIOReturnSuccess) { IOLockLock(ivars->lock); ivars->info=info; ivars->interface=interface; interface->retain(); ivars->active=true; IOLockUnlock(ivars->lock); }
        }
    }
    if (deviceDescriptor) ::free((void *)deviceDescriptor); if (device) device->release(); if (configuration) ::free((void *)configuration);
    if (status==kIOReturnSuccess) status=RegisterService();
    if (status!=kIOReturnSuccess) { ivars->backend->detach(); interface->Close(this,0); IOLockLock(ivars->lock); ivars->active=false; if (ivars->interface) { ivars->interface->release(); ivars->interface=nullptr; } IOLockUnlock(ivars->lock); }
    return status;
}
kern_return_t IMPL(FloeUSBSerialDriver,Stop) {
    if (ivars) {
        IOLockLock(ivars->lock); ivars->active=false; ++ivars->generation;
        ivars->backend->detach(); if (ivars->interface) { ivars->interface->Close(this,0); ivars->interface->release(); ivars->interface=nullptr; }
        IOLockUnlock(ivars->lock);
    }
    return Stop(provider,SUPERDISPATCH);
}
kern_return_t IMPL(FloeUSBSerialDriver,NewUserClient) {
    if (!userClient || type!=0 || !ivars) return kIOReturnBadArgument;
    IOService *service=nullptr; kern_return_t status=Create(this,"FloeUSBUserClientProperties",&service);
    if (status!=kIOReturnSuccess) return status;
    auto client=OSDynamicCast(IOUserClient,service);
    if (!client) { if (service) service->release(); return kIOReturnUnsupported; }
    *userClient=client; return kIOReturnSuccess;
}
kern_return_t FloeUSBSerialDriver::ClaimClient() {
    if (!ivars || !ivars->lock) return kIOReturnNoDevice;
    IOLockLock(ivars->lock);
    kern_return_t status=!ivars->active ? kIOReturnNoDevice : ivars->clientClaimed ? kIOReturnBusy : ivars->generation==UINT64_MAX ? kIOReturnNoResources : kIOReturnSuccess;
    if (status==kIOReturnSuccess) { ivars->clientClaimed=true; ++ivars->generation; }
    IOLockUnlock(ivars->lock); return status;
}
void FloeUSBSerialDriver::ReleaseClient() { if (!ivars || !ivars->lock) return; IOLockLock(ivars->lock); ivars->clientClaimed=false; IOLockUnlock(ivars->lock); }
kern_return_t FloeUSBSerialDriver::Exchange(const void *input,uint32_t size,void *output,uint32_t capacity,uint32_t *actual) {
    if (actual) *actual=0; FloeUSBRequest request={};
    if (!ivars || !actual || !output || capacity<sizeof(FloeUSBResponse) || capacity>sizeof(FloeUSBResponse)+FLOE_USB_MAX_PAYLOAD || !floe_usb_validate_request(input,size,&request)) return kIOReturnBadArgument;
    const uint32_t expectedPayload=request.operation==FLOE_USB_OP_INFO ? sizeof(FloeUSBDeviceInfo) : (request.operation==FLOE_USB_OP_READ || (request.operation==FLOE_USB_OP_CONTROL && (request.requestType&0x80))) ? request.capacity : 0;
    if (capacity<sizeof(FloeUSBResponse)+expectedPayload) return kIOReturnNoSpace;
    IOLockLock(ivars->lock);
    FloeUSBResponse response={FLOE_USB_MAGIC,FLOE_USB_VERSION,request.operation,ivars->generation,request.requestID,kIOReturnSuccess,0};
    uint8_t payload[FLOE_USB_MAX_PAYLOAD]={}; uint32_t transferred=0; bool returnsPayload=false;
    if (!ivars->active || (request.operation!=FLOE_USB_OP_INFO && request.generation!=ivars->generation)) response.status=kIOReturnNoDevice;
    else switch (request.operation) {
        case FLOE_USB_OP_INFO:
            memcpy(payload,&ivars->info,sizeof(ivars->info)); transferred=sizeof(ivars->info); returnsPayload=true; break;
        case FLOE_USB_OP_CONTROL: {
            uint16_t count=0; returnsPayload=(request.requestType&0x80)!=0;
            if (request.payloadSize) memcpy(payload,(const uint8_t *)input+sizeof(request),request.payloadSize);
            response.status=ivars->backend->control(request.requestType,request.request,request.value,request.index,payload,(uint16_t)(returnsPayload ? request.capacity : request.payloadSize),request.timeoutMS,&count);
            transferred=count; break;
        }
        case FLOE_USB_OP_READ:
            returnsPayload=true; response.status=ivars->backend->read(payload,request.capacity,request.timeoutMS,&transferred); break;
        case FLOE_USB_OP_WRITE:
            response.status=ivars->backend->write((const uint8_t *)input+sizeof(request),request.payloadSize,request.timeoutMS,&transferred); break;
        default: response.status=kIOReturnUnsupported;
    }
    if (!response.status && (transferred>FLOE_USB_MAX_PAYLOAD || (returnsPayload && transferred>request.capacity))) response.status=kIOReturnOverrun;
    if (!response.status) response.actual=transferred;
    uint32_t required=sizeof(response)+(!response.status && returnsPayload ? transferred : 0);
    if (required>capacity) { IOLockUnlock(ivars->lock); return kIOReturnNoSpace; }
    memcpy(output,&response,sizeof(response)); if (required>sizeof(response)) memcpy((uint8_t *)output+sizeof(response),payload,transferred);
    *actual=required; IOLockUnlock(ivars->lock); return kIOReturnSuccess;
}
bool FloeUSBSerialUserClient::init() { if (!super::init()) return false; ivars=IONewZero(FloeUSBSerialUserClient_IVars,1); return ivars!=nullptr; }
void FloeUSBSerialUserClient::free() { if (ivars) { if (ivars->driver) { if (ivars->claimed) ivars->driver->ReleaseClient(); ivars->driver->release(); } IODelete(ivars,FloeUSBSerialUserClient_IVars,1); }; super::free(); }
kern_return_t IMPL(FloeUSBSerialUserClient,Start) {
    kern_return_t status=Start(provider,SUPERDISPATCH); if (status!=kIOReturnSuccess) return status;
    auto driver=OSDynamicCast(FloeUSBSerialDriver,provider); if (!driver || !ivars) return kIOReturnNoDevice;
    status=driver->ClaimClient(); if (status!=kIOReturnSuccess) return status;
    ivars->driver=driver; ivars->claimed=true; driver->retain(); return kIOReturnSuccess;
}
kern_return_t IMPL(FloeUSBSerialUserClient,Stop) { if (ivars && ivars->driver && ivars->claimed) { ivars->claimed=false; ivars->driver->ReleaseClient(); } return Stop(provider,SUPERDISPATCH); }
kern_return_t FloeUSBSerialUserClient::ExternalMethod(uint64_t selector,IOUserClientMethodArguments *args,const IOUserClientMethodDispatch *,OSObject *,void *) {
    if (selector || !args || args->version!=kIOUserClientMethodArgumentsCurrentVersion || args->completion || args->scalarInputCount || args->scalarOutputCount || args->structureInputDescriptor || args->structureOutputDescriptor || !args->structureInput || !ivars || !ivars->driver || !ivars->claimed || args->structureInput->getLength()>sizeof(FloeUSBRequest)+FLOE_USB_MAX_PAYLOAD || args->structureOutputMaximumSize>sizeof(FloeUSBResponse)+FLOE_USB_MAX_PAYLOAD) return kIOReturnBadArgument;
    FloeUSBRequest request={};
    if (!floe_usb_validate_request(args->structureInput->getBytesNoCopy(),args->structureInput->getLength(),&request) || request.requestID<=ivars->lastRequestID) return kIOReturnBadArgument;
    ivars->lastRequestID=request.requestID;
    uint8_t output[sizeof(FloeUSBResponse)+FLOE_USB_MAX_PAYLOAD]={}; uint32_t actual=0;
    kern_return_t status=ivars->driver->Exchange(args->structureInput->getBytesNoCopy(),(uint32_t)args->structureInput->getLength(),output,(uint32_t)args->structureOutputMaximumSize,&actual);
    if (status==kIOReturnSuccess) { args->structureOutput=OSData::withBytes(output,actual); if (!args->structureOutput) return kIOReturnNoMemory; }
    return status;
}
