#ifndef FLOE_MUSL_COMPAT_H
#define FLOE_MUSL_COMPAT_H
/*
 * Floe build-time compat header, -include'd into every PRoot compile.
 * Contents are C-only: this producer also rebuilds loader/assembly.S, and
 * musl's <errno.h> carries extern declarations that are not valid
 * assembler source. The verified incremental qualification build only ever
 * applied this header to C TUs (loader objects pre-dated it), so guarding
 * on __ASSEMBLER__ preserves the verified semantics exactly while allowing
 * a full clean rebuild.
 */
#ifndef __ASSEMBLER__
#include <errno.h>
#ifndef MSG_COPY
#define MSG_COPY 040000
#endif
#ifndef TEMP_FAILURE_RETRY
#define TEMP_FAILURE_RETRY(expr) __extension__ ({ long int _result; do { _result = (long int)(expr); } while (_result == -1L && errno == EINTR); _result; })
#endif
#endif
#endif
