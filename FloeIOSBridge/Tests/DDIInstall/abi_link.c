#include "idevice.h"
int main(void) {
    if (floe_ddi_abi_version() != 1) return 1;
    if (floe_ddi_scope_begin(10, 0, 0, 0) != 0) return 2;
    floe_ddi_scope_end();
    return 0;
}
