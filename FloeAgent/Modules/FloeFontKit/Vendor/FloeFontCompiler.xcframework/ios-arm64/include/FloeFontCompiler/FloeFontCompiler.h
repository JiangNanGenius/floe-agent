// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_FONT_COMPILER_H
#define FLOE_FONT_COMPILER_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint8_t *bytes; size_t length; char *error; } FloeFontResult;
FloeFontResult floe_font_compile(const char *source_path);
void floe_font_result_free(FloeFontResult result);
#endif
