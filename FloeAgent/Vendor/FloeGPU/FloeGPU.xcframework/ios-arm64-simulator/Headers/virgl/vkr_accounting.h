/* Copyright 2026 Floe contributors; SPDX-License-Identifier: MIT */
#ifndef VKR_ACCOUNTING_H
#define VKR_ACCOUNTING_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Callbacks are serialized under the registry mutex; never re-enter this API.
 * Unregister only after renderer workers have joined. */
typedef void (*vkr_accounting_cb)(uint64_t size,uint32_t type,bool aliased,bool alloc,uint64_t key,void *user);
typedef bool (*vkr_accounting_admit_cb)(uint64_t size,bool aliased,bool blob,void *user);
typedef void (*vkr_accounting_cancel_cb)(uint64_t size,bool aliased,bool blob,void *user);
void vkr_accounting_set_callback(vkr_accounting_cb cb,void *user);
void vkr_accounting_set_blob_callback(vkr_accounting_cb cb,void *user);
void vkr_accounting_set_admission(vkr_accounting_admit_cb admit,vkr_accounting_cancel_cb cancel,void *user);
/* Reserve bookkeeping and quota BEFORE driver/shm allocation. The cleanup
 * handler rolls back every early return; commit consumes the reservation. */
struct vkr_accounting_reservation { void *entry; };
bool vkr_accounting_reserve(struct vkr_accounting_reservation *r,uint64_t size,bool aliased,bool blob);
uint64_t vkr_accounting_commit(struct vkr_accounting_reservation *r,uint32_t type);
bool vkr_accounting_link_parent(struct vkr_accounting_reservation *r,uint64_t parent);
bool vkr_accounting_ref(uint64_t key);
void vkr_accounting_unref(uint64_t key);
uint64_t vkr_renderer_resource_accounting_key(uint32_t ctx,uint32_t resource);
bool vkr_renderer_resource_accounting_import(uint32_t ctx,uint32_t resource,uint64_t key);
void vkr_accounting_cancel(struct vkr_accounting_reservation *r);
void vkr_accounting_report_free(uint64_t key);
void vkr_accounting_report_blob_free(uint64_t key);
uint64_t vkr_accounting_entry_count(void);
#ifdef __cplusplus
}
#endif
#endif
