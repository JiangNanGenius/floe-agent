#ifndef FLOE_TEX_NATIVE_H
#define FLOE_TEX_NATIVE_H
#include "FloeTeXAppleMetadata.h"
#include "FloeTeXLegacyOutline.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FloeTeXJob FloeTeXJob;
typedef void (*FloeTeXProgress)(const char *message, void *context);
FloeTeXJob *floe_tex_job_create(void);
void floe_tex_job_cancel(FloeTeXJob *job);
void floe_tex_job_progress(FloeTeXJob *job, FloeTeXProgress callback, void *context);
/* Call free only after compile returns, including cancellation. */
void floe_tex_job_free(FloeTeXJob *job);
/* Returns real xdvPath/displayListPath, not a PDF. */
char *floe_tex_compile(const char *request_json, FloeTeXJob *job);
void floe_tex_free(char *response_json);
#ifdef __cplusplus
}
#endif
#endif
