// SPDX-License-Identifier: MPL-2.0
#include "CLaTeXSupport.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <zlib.h>
int floe_tex_gunzip(const uint8_t *input, size_t count, size_t limit, uint8_t **output, size_t *output_count) {
    if (!input || !output || !output_count || !limit || count > UINT_MAX) return Z_DATA_ERROR;
    *output = NULL; *output_count = 0;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)count;
    int code = inflateInit2(&stream, 15 + 16);
    if (code != Z_OK) return code;
    uint8_t *buffer = NULL; size_t capacity = 0, used = 0;
    do {
        if (used == capacity) {
            size_t next = capacity ? capacity * 2 : 65536;
            if (next > limit) next = limit;
            if (next <= capacity) { code = Z_MEM_ERROR; break; }
            uint8_t *grown = realloc(buffer, next);
            if (!grown) { code = Z_MEM_ERROR; break; }
            buffer = grown; capacity = next;
        }
        stream.next_out = buffer + used;
        stream.avail_out = (uInt)(capacity - used);
        code = inflate(&stream, Z_NO_FLUSH);
        used = (size_t)stream.total_out;
    } while (code == Z_OK);
    /* Reject trailing bytes and concatenated streams, keeping one bounded document. */
    int complete = code == Z_STREAM_END && stream.avail_in == 0;
    inflateEnd(&stream);
    if (!complete) { free(buffer); return code == Z_STREAM_END ? Z_DATA_ERROR : code; }
    *output = buffer; *output_count = used; return Z_OK;
}
void floe_tex_buffer_free(void *buffer) { free(buffer); }
