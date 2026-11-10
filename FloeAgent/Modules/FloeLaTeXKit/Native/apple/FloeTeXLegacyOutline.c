// SPDX-License-Identifier: MPL-2.0
// Links only the already qualified FTL FreeType in the native XeTeX closure.
#include "FloeTeXLegacyOutline.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include <string.h>

typedef struct {
    FloeTeXOutlineSink sink;
    void *context;
    size_t count;
    int contour_open;
} OutlineOutput;

static int emit(OutlineOutput *out, int32_t op,
        double x1,double y1,double x2,double y2,double x3,double y3) {
    if (++out->count > 65536) return 1;
    return out->sink(out->context,op,x1,y1,x2,y2,x3,y3) != 0;
}
static int move_to(const FT_Vector *point, void *opaque) {
    OutlineOutput *out=opaque;
    if (out->contour_open && emit(out,4,0,0,0,0,0,0)) return 1;
    out->contour_open=1;
    return emit(out,0,(double)point->x,(double)point->y,0,0,0,0);
}
static int line_to(const FT_Vector *point, void *opaque) {
    return emit(opaque,1,(double)point->x,(double)point->y,0,0,0,0);
}
static int conic_to(const FT_Vector *control, const FT_Vector *end, void *opaque) {
    return emit(opaque,2,(double)control->x,(double)control->y,(double)end->x,(double)end->y,0,0);
}
static int cubic_to(const FT_Vector *a, const FT_Vector *b, const FT_Vector *end, void *opaque) {
    return emit(opaque,3,(double)a->x,(double)a->y,(double)b->x,(double)b->y,(double)end->x,(double)end->y);
}

int32_t floe_tex_legacy_outline(const uint8_t *font, size_t length,
        uint32_t face_index, const char *glyph_name, int32_t character,
        double *units_per_em, FloeTeXOutlineSink sink, void *context) {
    if (!font || !length || length > 64*1024*1024 || face_index > 65535 || !units_per_em || !sink) return -1;
    *units_per_em=0;
    if (glyph_name && strnlen(glyph_name,257)>256) return -1;
    FT_Library library=NULL;
    FT_Face face=NULL;
    if (FT_Init_FreeType(&library)) return -2;
    int32_t result=-2;
    if (FT_New_Memory_Face(library,font,(FT_Long)length,(FT_Long)face_index,&face)) goto done;
    FT_UInt glyph=0;
    if (glyph_name && glyph_name[0]) {
        if (!FT_HAS_GLYPH_NAMES(face)) {result=-3;goto done;}
        glyph=FT_Get_Name_Index(face,glyph_name);
        if (!glyph && strcmp(glyph_name,".notdef") != 0) {result=-4;goto done;}
    } else {
        if (character < 0 || character > 255) {result=-1;goto done;}
        if (FT_Select_Charmap(face,FT_ENCODING_ADOBE_CUSTOM)
                && FT_Select_Charmap(face,FT_ENCODING_ADOBE_STANDARD)) {result=-3;goto done;}
        glyph=FT_Get_Char_Index(face,(FT_ULong)character);
        if (!glyph) {result=-4;goto done;}
    }
    if (FT_Load_Glyph(face,glyph,FT_LOAD_NO_SCALE|FT_LOAD_NO_HINTING|FT_LOAD_NO_BITMAP)) {result=-4;goto done;}
    if (face->glyph->format != FT_GLYPH_FORMAT_OUTLINE || !face->units_per_EM) {result=-5;goto done;}
    if (face->glyph->outline.n_points < 0
            || face->glyph->outline.n_contours < 0 || face->glyph->outline.n_contours > 4096) {result=-6;goto done;}
    if (FT_Outline_Check(&face->glyph->outline)) {result=-5;goto done;}
    *units_per_em=(double)face->units_per_EM;
    // An encoded whitespace glyph is valid even when its outline is empty.
    if (!face->glyph->outline.n_points) {result=0;goto done;}
    OutlineOutput out={sink,context,0,0};
    FT_Outline_Funcs callbacks={move_to,line_to,conic_to,cubic_to,0,0};
    if (FT_Outline_Decompose(&face->glyph->outline,&callbacks,&out)) {result=out.count>65536 ? -6 : -7;goto done;}
    if (out.contour_open && emit(&out,4,0,0,0,0,0,0)) {result=-7;goto done;}
    result=0;
done:
    if (face) FT_Done_Face(face);
    FT_Done_FreeType(library);
    return result;
}
