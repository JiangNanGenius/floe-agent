// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_DIAGRAM_COMPRESSION_H
#define FLOE_DIAGRAM_COMPRESSION_H
#include <stddef.h>
#include <stdint.h>
// Raw DEFLATE, matching draw.io. Output size is bounded by the caller.
int floe_diagram_inflate(const uint8_t *input, size_t input_count, uint8_t *output, size_t *output_count);
int floe_diagram_deflate(const uint8_t *input, size_t input_count, uint8_t *output, size_t *output_count);
#endif
