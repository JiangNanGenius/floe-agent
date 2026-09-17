/* SPDX-License-Identifier: MPL-2.0 */
/* WASI libc has no L_tmpnam, tmpnam, tmpfile or a shared /tmp. Give Lua
   jailed unique-name generators that stay inside the command's working
   directory; io.tmpfile() opens its own file. */
#ifndef FLOE_LUA_WASI_CFG_H
#define FLOE_LUA_WASI_CFG_H
#include <stdio.h>
#define LUA_TMPNAMBUFSIZE 64
#define lua_tmpnam(b,e) { \
        static unsigned int counter = 0; \
        snprintf(b, LUA_TMPNAMBUFSIZE, "lua_tmp_%08x", counter++); \
        e = 0; }
/* os.execute() reports "no shell" like upstream's LUA_USE_IOS path. */
#define l_system(cmd) ((cmd) == NULL ? 0 : -1)
FILE *floe_lua_tmpfile(void);
#define tmpfile() floe_lua_tmpfile()
#endif
