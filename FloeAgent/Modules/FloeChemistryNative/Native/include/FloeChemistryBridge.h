#ifndef FLOE_CHEMISTRY_BRIDGE_H
#define FLOE_CHEMISTRY_BRIDGE_H
#ifdef __cplusplus
extern "C" {
#endif
void *fch_cancel_create(void);
void fch_cancel_request(void *token);
void fch_cancel_destroy(void *token);
char *fch_execute(const char *request, void *token);
void fch_free(char *response);
#ifdef __cplusplus
}
#endif
#endif
