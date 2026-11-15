/* SPDX-License-Identifier: Apache-2.0 */
#define _POSIX_C_SOURCE 200809L

#include "floe_blas_policy.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int floe_blas_policy_parse_name(const char *name)
{
    if (name == NULL) return -1;
    if (strcmp(name, "auto") == 0) return FLOE_BLAS_POLICY_AUTO;
    if (strcmp(name, "on") == 0) return FLOE_BLAS_POLICY_ON;
    if (strcmp(name, "off") == 0) return FLOE_BLAS_POLICY_OFF;
    return -1;
}

int floe_blas_config_path(char *buffer, size_t size)
{
    const char *xdg;
    const char *home;
    const char *base;
    int written;

    if (buffer == NULL || size < 2) return -1;
    xdg = getenv("XDG_CONFIG_HOME");
    if (xdg != NULL && xdg[0] == '/') {
        base = xdg;
    } else {
        home = getenv("HOME");
        if (home == NULL || home[0] != '/') {
            buffer[0] = '\0';
            return -1;
        }
        base = home;
    }

    if (base[0] != '\0' && base[strlen(base) - 1] == '/') {
        written = snprintf(buffer, size, "%sfloe-acceleration/blas.conf", base);
    } else {
        written = snprintf(buffer, size, "%s%s", base, FLOE_BLAS_CONFIG_SUFFIX);
    }
    if (written < 0 || (size_t)written >= size) {
        buffer[0] = '\0';
        return -1;
    }
    return 0;
}

int floe_blas_config_read_mode(const char *path)
{
    unsigned char buffer[1024];
    struct stat status;
    ssize_t length;
    int fd;
    int mode = -1;
    size_t offset = 0;

    if (path == NULL || path[0] == '\0') return -1;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    if (fstat(fd, &status) != 0 ||
        !S_ISREG(status.st_mode) ||
        status.st_uid != geteuid() ||
        (status.st_mode & 0022) != 0) {
        close(fd);
        return -1;
    }
    length = read(fd, buffer, sizeof buffer - 1);
    close(fd);
    if (length <= 0) return -1;
    buffer[length] = '\0';

    while (offset < (size_t)length) {
        size_t start = offset;
        size_t end;
        size_t value;
        size_t value_end;

        while (offset < (size_t)length && buffer[offset] != '\n') offset++;
        end = offset;
        if (offset < (size_t)length) offset++;

        while (start < end && (buffer[start] == ' ' || buffer[start] == '\t')) start++;
        while (end > start &&
               (buffer[end - 1] == ' ' || buffer[end - 1] == '\t' ||
                buffer[end - 1] == '\r')) end--;

        if (end - start < 5 || memcmp(buffer + start, "mode=", 5) != 0) continue;
        value = start + 5;
        while (value < end && (buffer[value] == ' ' || buffer[value] == '\t')) value++;
        value_end = end;
        while (value_end > value &&
               (buffer[value_end - 1] == ' ' || buffer[value_end - 1] == '\t')) value_end--;
        if (value_end > value && value_end - value < 8) {
            char name[8];
            size_t name_length = value_end - value;

            memcpy(name, buffer + value, name_length);
            name[name_length] = '\0';
            mode = floe_blas_policy_parse_name(name);
            if (mode >= 0) break;
        }
    }
    return mode;
}

int floe_blas_policy_resolve(char *config_path, size_t config_path_size,
                             int *source)
{
    const char *environment;
    char fallback_path[512];
    int mode;

    if (source == NULL) return FLOE_BLAS_POLICY_AUTO;
    *source = 0;
    if (config_path != NULL && config_path_size > 0) config_path[0] = '\0';

    environment = getenv(FLOE_BLAS_MODE_ENV);
    if (environment != NULL && environment[0] != '\0') {
        *source = 1;
        mode = floe_blas_policy_parse_name(environment);
        /* An explicit but malformed value is a policy error; use the
         * conservative default rather than silently treating it as "on". */
        return mode >= 0 ? mode : FLOE_BLAS_POLICY_AUTO;
    }

    if (config_path == NULL || config_path_size == 0) {
        config_path = fallback_path;
        config_path_size = sizeof fallback_path;
    }
    if (floe_blas_config_path(config_path, config_path_size) == 0) {
        mode = floe_blas_config_read_mode(config_path);
        if (mode >= 0) {
            *source = 2;
            return mode;
        }
    }
    return FLOE_BLAS_POLICY_AUTO;
}

int floe_blas_trusted_regular_file(const char *path, unsigned int required_uid)
{
    struct stat status;

    if (path == NULL || path[0] == '\0') return 0;
    if (stat(path, &status) != 0) return 0;
    if (!S_ISREG(status.st_mode)) return 0;
    if (status.st_uid != (uid_t)required_uid) return 0;
    if ((status.st_mode & 0022) != 0) return 0;
    return 1;
}

int floe_blas_trusted_character_device(const char *path)
{
    struct stat status;

    if (path == NULL || path[0] == '\0') return 0;
    if (stat(path, &status) != 0) return 0;
    return S_ISCHR(status.st_mode) ? 1 : 0;
}
