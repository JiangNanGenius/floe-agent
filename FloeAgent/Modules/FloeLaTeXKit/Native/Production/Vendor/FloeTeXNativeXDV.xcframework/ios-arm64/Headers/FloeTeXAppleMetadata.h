// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_TEX_APPLE_METADATA_H
#define FLOE_TEX_APPLE_METADATA_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

// The App registers its existing PDFKitGate + ObjC exception boundary once,
// before native typesetting starts. No second PDF queue is created here.
typedef int32_t (*FloeTeXApplePDFBody)(void *context);
typedef int32_t (*FloeTeXApplePDFGate)(FloeTeXApplePDFBody body, void *context);
// 0 registered/already identical; -1 nil; -2 a different gate already owns it.
int32_t floe_tex_apple_set_pdf_gate(FloeTeXApplePDFGate gate);

// Bounded, already-authorized bytes, never an arbitrary native filesystem path.
// requested_page: 0/1 first, positive 1-based, negative from last (-1 last).
// box: 0 raster frame, 1 crop, 2 media, 3 bleed, 4 trim, 5 art.
// rect_bp=[x,y,width,height] in PDF bp (72/in). PDF /Rotate is applied to
// the selected page box (clockwise rotation in its Cartesian coordinates).
// Raster uses embedded DPI (72 if unspecified); EXIF axes 5...8 swap dimensions.
// Returns 0 success, otherwise -1 invalid/bounded input, -2 unsupported raster,
// -3 corrupt PDF, -4 locked PDF, -5 page range, -6 invalid geometry,
// -7 missing App PDF gate, -8 caught platform exception.
int32_t floe_tex_image_metadata(const uint8_t *data, size_t length,
    int32_t requested_page, int32_t box, double rect_bp[4], int32_t *page_count);
#ifdef __cplusplus
}
#endif
#endif
