#include "FloeLlamaVisionShim.h"
#include <TargetConditionals.h>
#include <stdlib.h>
#include <string.h>

// Stable C ABI subset from llama.cpp b10581. Keeping the shim opaque prevents
// C++ helpers from leaking into Swift while the final target still links the
// audited llama.framework binary.
typedef int32_t llama_pos;
typedef int32_t llama_seq_id;
typedef struct mtmd_context mtmd_context;
typedef struct mtmd_bitmap mtmd_bitmap;
typedef struct mtmd_input_chunks mtmd_input_chunks;
typedef void * ggml_backend_dev_t;
typedef bool (*mtmd_progress_callback)(float, void *);
typedef bool (*ggml_backend_sched_eval_callback)(void *, bool, void *);
struct mtmd_context_params {
    bool use_gpu;
    ggml_backend_dev_t device;
    bool print_timings;
    int n_threads;
    const char * image_marker;
    const char * media_marker;
    int flash_attn_type;
    bool warmup;
    int image_min_tokens;
    int image_max_tokens;
    ggml_backend_sched_eval_callback cb_eval;
    void * cb_eval_user_data;
    int32_t batch_max_tokens;
    mtmd_progress_callback progress_callback;
    void * progress_callback_user_data;
};
struct mtmd_input_text { const char * text; size_t text_len; bool add_special; bool parse_special; };
struct mtmd_helper_bitmap_wrapper { mtmd_bitmap * bitmap; void * video_ctx; };

extern struct mtmd_context_params mtmd_context_params_default(void);
extern mtmd_context * mtmd_init_from_file(const char *, const llama_model *, struct mtmd_context_params);
extern bool mtmd_support_vision(const mtmd_context *);
extern void mtmd_free(mtmd_context *);
extern mtmd_input_chunks * mtmd_input_chunks_init(void);
extern void mtmd_input_chunks_free(mtmd_input_chunks *);
extern struct mtmd_helper_bitmap_wrapper mtmd_helper_bitmap_init_from_buf(mtmd_context *, const unsigned char *, size_t, bool);
extern void mtmd_bitmap_free(mtmd_bitmap *);
extern int32_t mtmd_tokenize(mtmd_context *, mtmd_input_chunks *, const struct mtmd_input_text *, const mtmd_bitmap **, size_t);
extern size_t mtmd_helper_get_n_tokens(const mtmd_input_chunks *);
extern int32_t mtmd_helper_eval_chunks(mtmd_context *, llama_context *, const mtmd_input_chunks *, llama_pos, llama_seq_id, int32_t, bool, llama_pos *);

#if TARGET_OS_SIMULATOR

void * floe_mtmd_init(const char * projector_path, const llama_model * model, bool use_gpu) {
    (void) projector_path; (void) model; (void) use_gpu;
    return NULL;
}
bool floe_mtmd_supports_vision(const void * context) { (void) context; return false; }
void floe_mtmd_free(void * context) { (void) context; }
int32_t floe_mtmd_eval_images(
    void * context, llama_context * llama, const char * prompt,
    const uint8_t * const * image_bytes, const size_t * image_lengths,
    size_t image_count, int32_t batch_size, int32_t * new_position, size_t * token_count
) {
    (void) context; (void) llama; (void) prompt; (void) image_bytes; (void) image_lengths;
    (void) image_count; (void) batch_size; (void) new_position; (void) token_count;
    return -100;
}

#else

void * floe_mtmd_init(const char * projector_path, const llama_model * model, bool use_gpu) {
    struct mtmd_context_params params = mtmd_context_params_default();
    params.use_gpu = use_gpu;
    params.print_timings = false;
    return mtmd_init_from_file(projector_path, model, params);
}

bool floe_mtmd_supports_vision(const void * context) {
    return context != NULL && mtmd_support_vision((const mtmd_context *) context);
}

void floe_mtmd_free(void * context) {
    if (context != NULL) mtmd_free((mtmd_context *) context);
}

int32_t floe_mtmd_eval_images(
    void * raw_context,
    llama_context * llama,
    const char * prompt,
    const uint8_t * const * image_bytes,
    const size_t * image_lengths,
    size_t image_count,
    int32_t batch_size,
    int32_t * new_position,
    size_t * token_count
) {
    if (raw_context == NULL || llama == NULL || prompt == NULL || image_count == 0) return -1;
    mtmd_context * context = (mtmd_context *) raw_context;
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    const mtmd_bitmap ** bitmaps = calloc(image_count, sizeof(mtmd_bitmap *));
    if (chunks == NULL || bitmaps == NULL) {
        if (chunks != NULL) mtmd_input_chunks_free(chunks);
        free(bitmaps);
        return -2;
    }
    int32_t result = 0;
    for (size_t index = 0; index < image_count; index++) {
        struct mtmd_helper_bitmap_wrapper wrapper = mtmd_helper_bitmap_init_from_buf(
            context, image_bytes[index], image_lengths[index], false
        );
        if (wrapper.bitmap == NULL || wrapper.video_ctx != NULL) {
            result = -3;
            break;
        }
        bitmaps[index] = wrapper.bitmap;
    }
    if (result == 0) {
        struct mtmd_input_text text = {
            .text = prompt,
            .text_len = strlen(prompt),
            .add_special = true,
            .parse_special = true,
        };
        result = mtmd_tokenize(context, chunks, &text, bitmaps, image_count);
    }
    if (result == 0) {
        if (token_count != NULL) *token_count = mtmd_helper_get_n_tokens(chunks);
        llama_pos position = 0;
        result = mtmd_helper_eval_chunks(context, llama, chunks, 0, 0, batch_size, true, &position);
        if (new_position != NULL) *new_position = position;
    }
    for (size_t index = 0; index < image_count; index++) {
        if (bitmaps[index] != NULL) mtmd_bitmap_free((mtmd_bitmap *) bitmaps[index]);
    }
    free(bitmaps);
    mtmd_input_chunks_free(chunks);
    return result;
}

#endif
