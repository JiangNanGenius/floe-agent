#include "FloeUSBWire.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cstdio>
int main() {
    FloeUSBRequest r={}; r.magic=FLOE_USB_MAGIC; r.version=1; r.operation=FLOE_USB_OP_INFO; r.timeoutMS=1000; r.capacity=24; r.requestID=1;
    FloeUSBRequest out={}; assert(floe_usb_validate_request(&r,sizeof(r),&out));
    for (size_t n=0;n<sizeof(r);n++) assert(!floe_usb_validate_request(&r,n,&out));
    r.payloadSize=UINT32_MAX; assert(!floe_usb_validate_request(&r,sizeof(r),&out));
    uint32_t random=0x6f1e79; unsigned cases=0;
    for (unsigned i=0;i<150000;i++) {
        random=random*1664525+1013904223; size_t size=random%4097;
        std::vector<uint8_t> data(size); for (auto &b:data) { random=random*1664525+1013904223; b=random>>24; }
        FloeUSBEndpoints ep={}; FloeUSBResponse reply={};
        floe_usb_validate_request(data.data(),data.size(),&out);
        floe_usb_validate_response(data.data(),data.size(),&r,&reply);
        floe_usb_find_endpoints(data.data(),data.size(),(uint8_t)i,(uint8_t)(i>>8),&ep); cases++;
    }
    std::printf("USB IPC/descriptor sanitizer corpus passed: %u cases\n",cases);
}
