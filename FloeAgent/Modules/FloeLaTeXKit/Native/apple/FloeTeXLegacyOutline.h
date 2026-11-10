// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_TEX_LEGACY_OUTLINE_H
#define FLOE_TEX_LEGACY_OUTLINE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Coordinates are REAL unscaled font units; units_per_em supplies the scale.
// op 0 move(x1,y1), 1 line(x1,y1), 2 quadratic(control x1/y1,end x2/y2),
// 3 cubic(control1 x1/y1,control2 x2/y2,end x3/y3), 4 close contour.
// Nonzero callback result stops decomposition; no pointers outlive the call.
typedef int32_t (*FloeTeXOutlineSink)(void *context, int32_t op,
    double x1, double y1, double x2, double y2, double x3, double y3);
// The trusted caller already resolved/read the exact Type1/font bytes.
// glyph_name nonempty uses FT_Get_Name_Index on this exact face; otherwise
// character 0...255 uses ADOBE_CUSTOM or ADOBE_STANDARD, never Unicode.
// 0 success; -1 invalid/bounded input, -2 FT init/font, -3 encoding/name,
// -4 no exact glyph, -5 non-outline/invalid units, -6 outline limit,
// -7 callback/decomposition failure. Each call owns its FT library/face.
int32_t floe_tex_legacy_outline(const uint8_t *font, size_t length,
    uint32_t face_index, const char *glyph_name, int32_t character,
    double *units_per_em, FloeTeXOutlineSink sink, void *context);
#ifdef __cplusplus
}
#endif
#endif
