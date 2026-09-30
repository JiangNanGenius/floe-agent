// Harness shim for the pinned upstream <config.h>. The upstream build defines
// EXPORT/EXTERNC through its autotools config; the harness only needs linkage
// consistency across translation units.
#pragma once

#ifdef __cplusplus
#define EXTERNC extern "C"
#define EXPORT extern "C"
#else
#define EXTERNC
#define EXPORT
#endif
