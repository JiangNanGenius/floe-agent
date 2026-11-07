#ifndef FLOE_LATEX_SUPPORT_H
#define FLOE_LATEX_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
/* Bounded gzip decoding for generated SyncTeX, no subprocess or interpreter. */
int floe_tex_gunzip(const uint8_t *input, size_t count, size_t limit, uint8_t **output, size_t *output_count);
void floe_tex_buffer_free(void *buffer);
#endif
