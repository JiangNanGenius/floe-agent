/* SPDX-License-Identifier: MPL-2.0 */
/* Applied only to vendor TUs. Never touches a process terminal or callbacks. */
#ifndef FLOE_AE_HOST_HOOKS_H
#define FLOE_AE_HOST_HOOKS_H
#include <stdio.h>
int ae_vendor_fprintf(FILE *,const char *,...);
int ae_vendor_printf(const char *,...);
int ae_vendor_fputc(int,FILE *);
#define fprintf ae_vendor_fprintf
#define printf ae_vendor_printf
#define fputc ae_vendor_fputc
#endif
