#ifndef FLOE_LLAMA_VISION_SHIM_H
#define FLOE_LLAMA_VISION_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct llama_model llama_model;
typedef struct llama_context llama_context;

void * floe_mtmd_init(const char * projector_path, const llama_model * model, bool use_gpu);
bool floe_mtmd_supports_vision(const void * context);
void floe_mtmd_free(void * context);

int32_t floe_mtmd_eval_images(
    void * context,
    llama_context * llama,
    const char * prompt,
    const uint8_t * const * image_bytes,
    const size_t * image_lengths,
    size_t image_count,
    int32_t batch_size,
    int32_t * new_position,
    size_t * token_count
);

#endif
