#include "FloeUSBWire.h"
#include <string.h>
bool floe_usb_validate_request(const void *bytes, size_t length, FloeUSBRequest *result) {
    if (!bytes || !result || length < sizeof(FloeUSBRequest) || length > sizeof(FloeUSBRequest)+FLOE_USB_MAX_PAYLOAD) return false;
    FloeUSBRequest r; memcpy(&r,bytes,sizeof(r));
    if (r.magic!=FLOE_USB_MAGIC || r.version!=FLOE_USB_VERSION || !r.requestID || r.reserved8 || r.reserved32 || r.interfaceNumber ||
        r.payloadSize>FLOE_USB_MAX_PAYLOAD || r.capacity>FLOE_USB_MAX_PAYLOAD || length!=sizeof(r)+r.payloadSize ||
        !r.timeoutMS || r.timeoutMS>5000) return false;
    switch (r.operation) {
        case FLOE_USB_OP_INFO:
            if (r.payloadSize || r.capacity<sizeof(FloeUSBDeviceInfo) || r.generation || r.requestType || r.request || r.value || r.index) return false; break;
        case FLOE_USB_OP_CONTROL:
            if (!r.generation || ((r.requestType&0x80) ? r.payloadSize!=0 : r.capacity!=0)) return false; break;
        case FLOE_USB_OP_READ:
            if (!r.generation || r.payloadSize || !r.capacity || r.requestType || r.request || r.value || r.index) return false; break;
        case FLOE_USB_OP_WRITE:
            if (!r.generation || !r.payloadSize || r.capacity || r.requestType || r.request || r.value || r.index) return false; break;
        default: return false;
    }
    *result=r; return true;
}
bool floe_usb_validate_response(const void *bytes, size_t length, const FloeUSBRequest *request, FloeUSBResponse *result) {
    if (!bytes || !request || !result || length<sizeof(FloeUSBResponse) || length>sizeof(FloeUSBResponse)+FLOE_USB_MAX_PAYLOAD) return false;
    FloeUSBResponse r; memcpy(&r,bytes,sizeof(r));
    if (r.magic!=FLOE_USB_MAGIC || r.version!=FLOE_USB_VERSION || r.operation!=request->operation || r.requestID!=request->requestID || !r.generation ||
        (request->generation && r.generation!=request->generation) || r.actual>FLOE_USB_MAX_PAYLOAD) return false;
    bool input=request->operation==FLOE_USB_OP_INFO || request->operation==FLOE_USB_OP_READ || (request->operation==FLOE_USB_OP_CONTROL && (request->requestType&0x80));
    if (r.status && (r.actual || length!=sizeof(r))) return false;
    if (!r.status && input && (r.actual>request->capacity || length!=sizeof(r)+r.actual)) return false;
    if (!r.status && !input && (r.actual>request->payloadSize || length!=sizeof(r))) return false;
    *result=r; return true;
}
bool floe_usb_find_endpoints(const void *bytes, size_t length, uint8_t number, uint8_t alternate, FloeUSBEndpoints *result) {
    if (!bytes || !result || length<9 || length>65535) return false;
    const uint8_t *p=(const uint8_t *)bytes; const size_t total=(size_t)p[2]|((size_t)p[3]<<8);
    if (p[0]<9 || p[1]!=2 || total<9 || total>length) return false;
    FloeUSBEndpoints value; memset(&value,0,sizeof(value)); value.controlInterface=number;
    bool selected=false, found=false; unsigned descriptors=0;
    // CDC Union descriptors bind a data interface to its control interface.
    for (size_t offset=0;offset<total;) {
        if (++descriptors>256 || total-offset<2 || p[offset]<2 || p[offset]>total-offset) return false;
        uint8_t size=p[offset],type=p[offset+1];
        if (type==0x24 && size>=5 && p[offset+2]==6) {
            for (unsigned i=4;i<size;i++) if (p[offset+i]==number) value.controlInterface=p[offset+3];
        }
        offset+=size;
    }
    descriptors=0;
    for (size_t offset=0;offset<total;) {
        if (++descriptors>256 || total-offset<2 || p[offset]<2 || p[offset]>total-offset) return false;
        uint8_t size=p[offset],type=p[offset+1];
        if (type==4) {
            if (size<9) return false;
            selected=p[offset+2]==number && p[offset+3]==alternate;
            if (selected) { if (found) return false; found=true; value.interfaceClass=p[offset+5]; value.interfaceSubclass=p[offset+6]; value.alternateSetting=alternate; }
        } else if (selected && type==5) {
            if (size<7) return false;
            uint8_t address=p[offset+2]; uint16_t packet=((uint16_t)p[offset+4]|((uint16_t)p[offset+5]<<8))&0x7ff;
            if ((p[offset+3]&3)==2) {
                if (!(address&15) || (address&0x70) || !packet || packet>1024) return false;
                if (address&0x80) { if (value.input) return false; value.input=address; value.maximumPacketSize=packet; }
                else { if (value.output) return false; value.output=address; }
            }
        }
        offset+=size;
    }
    if (!found || !value.input || !value.output) return false;
    *result=value; return true;
}
