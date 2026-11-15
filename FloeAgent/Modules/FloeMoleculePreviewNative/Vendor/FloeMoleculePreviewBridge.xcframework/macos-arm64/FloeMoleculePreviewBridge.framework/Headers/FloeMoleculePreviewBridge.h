#ifndef FLOE_MOLECULE_PREVIEW_BRIDGE_H
#define FLOE_MOLECULE_PREVIEW_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
void *fmp_cancel_create(void);
void fmp_cancel_request(void *token);
void fmp_cancel_destroy(void *token);
/* 0 waiting, 1 parsing, 2 embedding, 3 optimization, 4 stopped. */
int fmp_stage(void *token);
/* Bounded JSON request/result; caller frees the returned string. */
char *fmp_generate(const char *request, void *token);
void fmp_free(char *response);
#ifdef __cplusplus
}
#endif
#endif
