// SPDX-License-Identifier: MPL-2.0
#include "CDiagramCompression.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>
int floe_diagram_inflate(const uint8_t *input, size_t input_count, uint8_t *output, size_t *output_count) {
    if (input_count > UINT_MAX || *output_count > UINT_MAX) return Z_BUF_ERROR;
    z_stream stream; memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)input_count;
    stream.next_out = output; stream.avail_out = (uInt)*output_count;
    int status = inflateInit2(&stream, -MAX_WBITS); if (status != Z_OK) return status;
    status = inflate(&stream, Z_FINISH); *output_count = stream.total_out;
    int complete = status == Z_STREAM_END && stream.avail_in == 0; inflateEnd(&stream);
    return complete ? Z_OK : (status == Z_STREAM_END ? Z_DATA_ERROR : status);
}
int floe_diagram_deflate(const uint8_t *input, size_t input_count, uint8_t *output, size_t *output_count) {
    if (input_count > UINT_MAX || *output_count > UINT_MAX) return Z_BUF_ERROR;
    z_stream stream; memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)input_count;
    stream.next_out = output; stream.avail_out = (uInt)*output_count;
    int status = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    if (status != Z_OK) return status;
    status = deflate(&stream, Z_FINISH); *output_count = stream.total_out;
    deflateEnd(&stream); return status == Z_STREAM_END ? Z_OK : status;
}
