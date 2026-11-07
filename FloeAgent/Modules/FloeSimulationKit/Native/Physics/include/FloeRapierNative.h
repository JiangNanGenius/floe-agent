#ifndef FLOE_RAPIER_NATIVE_H
#define FLOE_RAPIER_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint8_t *data; size_t length; int32_t status; } FloePhysicsBuffer;
typedef int32_t (*FloePhysicsShouldCancel)(void *context);
typedef void (*FloePhysicsProgress)(void *context, uint32_t step, uint32_t total);
FloePhysicsBuffer floe_physics_run(const uint8_t *json, size_t length, size_t result_value_budget, FloePhysicsShouldCancel cancelled, FloePhysicsProgress progress, void *context);
void floe_physics_buffer_free(FloePhysicsBuffer buffer);
const char *floe_physics_version(void);
#ifdef __cplusplus
}
#endif
#endif
