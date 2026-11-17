/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * file2alias-ONLY Darwin host compat. Injected exclusively into the
 * file2alias.o compile via the kernel's own per-target hook:
 *   gmake ... HOSTCFLAGS_file2alias.o="-include <this header>"
 * (scripts/Makefile.host appends $(HOSTCFLAGS_$(target-stem).o); no kernel
 * source is modified). It is NOT in the global KBUILD_USERHOSTCFLAGS.
 *
 * Problem: scripts/mod/file2alias.c defines its OWN
 *   typedef struct { __u8 b[16]; } uuid_t;          (line 45)
 * and later uses uuid->b[i]. The macOS SDK already typedefs
 *   typedef unsigned char uuid_t[16];               (<sys/_types/_uuid_t.h>)
 * via <sys/types.h>/<unistd.h>, so on Darwin the two collide (and whichever
 * wins breaks the other side: struct vs array). glibc does not force uuid_t
 * through <sys/types.h>, so upstream never sees this.
 *
 * Scoped fix: inside THIS TU only, include the REAL SDK headers first so
 * every SDK prototype (gethostuuid(2) and friends) is compiled with the real
 * array uuid_t, THEN rename the token for the remainder of the translation
 * unit. file2alias.c's line-45 typedef and all kernel-side uuid_t uses then
 * resolve to fvm_kernel_uuid_t (the struct layout it expects). No SDK header
 * is suppressed and no global typedef is replaced; fixdep/modpost/dtc/selinux
 * TUs never see this header.
 */
#ifndef FVM_DARWIN_HOST_COMPAT_H
#define FVM_DARWIN_HOST_COMPAT_H
#ifdef __APPLE__
#include <sys/types.h>   /* real SDK chain incl. <sys/_types/_uuid_t.h> (array uuid_t) */
#include <unistd.h>      /* gethostuuid.h and other uuid_t consumers, real type */
#define uuid_t fvm_kernel_uuid_t
#endif /* __APPLE__ */
#endif /* FVM_DARWIN_HOST_COMPAT_H */
