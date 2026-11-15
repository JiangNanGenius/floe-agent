/* SPDX-License-Identifier: Apache-2.0 */
#ifndef FLOE_BLAS_POLICY_H
#define FLOE_BLAS_POLICY_H

#include <stddef.h>

#define FLOE_BLAS_POLICY_AUTO 0
#define FLOE_BLAS_POLICY_ON 1
#define FLOE_BLAS_POLICY_OFF 2

#define FLOE_BLAS_MODE_ENV "FLOE_BLAS_MODE"
#define FLOE_BLAS_CONFIG_SUFFIX "/floe-acceleration/blas.conf"

/* Exact per-environment config field:
 *   $XDG_CONFIG_HOME/floe-acceleration/blas.conf
 * or
 *   $HOME/.config/floe-acceleration/blas.conf
 * containing one recognized line: `mode=auto|on|off`.
 * XDG_CONFIG_HOME is used only when absolute.  A missing or unsafe file is
 * treated as the default (auto), never as an error that disables execution. */

/* -1 invalid, otherwise FLOE_BLAS_POLICY_AUTO/ON/OFF. */
int floe_blas_policy_parse_name(const char *name);

/* 0: default auto, 1: environment, 2: config file. */
int floe_blas_policy_resolve(char *config_path, size_t config_path_size,
                             int *source);

/* Build the config path without opening it.  Returns 0 on success. */
int floe_blas_config_path(char *buffer, size_t size);

/* Read only an owned, non-group/world-writable regular file.  Returns the
 * parsed mode or -1 when the file is absent, unsafe or has no recognized
 * mode field.  A config file that cannot be used leaves the default. */
int floe_blas_config_read_mode(const char *path);

/* Regular file owned by required_uid with no group/world write permission. */
int floe_blas_trusted_regular_file(const char *path, unsigned int required_uid);
/* Character device check (the virtio-gpu render node). */
int floe_blas_trusted_character_device(const char *path);

#endif /* FLOE_BLAS_POLICY_H */
