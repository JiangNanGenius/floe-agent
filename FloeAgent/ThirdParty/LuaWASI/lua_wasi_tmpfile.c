/* SPDX-License-Identifier: MPL-2.0 */
#include <stdio.h>

/* WASI libc declares but never defines tmpfile. Back io.tmpfile() with a
   uniquely named file inside the jailed working directory. */
FILE *floe_lua_tmpfile(void) {
    static unsigned int counter = 0;
    char name[64];
    snprintf(name, sizeof name, "lua_tmpf_%08x", counter++);
    return fopen(name, "w+b");
}
