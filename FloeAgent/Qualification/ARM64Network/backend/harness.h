/* SPDX-License-Identifier: Apache-2.0 */
/* Minimal assertion harness for the libslirp backend component tests.
 * No framework, no allocation tracking magic: every failure prints the file,
 * line and both operands, and the process exit status is the number of failed
 * checks. Original failures are never retried away. */
#ifndef FLOE_NET_HARNESS_H
#define FLOE_NET_HARNESS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned g_checks, g_failures;
static const char *g_current_test = "";

#define T_BEGIN(name) do { g_current_test = (name); \
    fprintf(stderr, "\n--- %s ---\n", (name)); } while (0)

#define T_CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { \
        g_failures++; \
        fprintf(stderr, "FAIL [%s] %s:%d: %s\n", g_current_test, __FILE__, \
                __LINE__, #cond); \
    } \
} while (0)

#define T_EQ_U(a, b) do { \
    unsigned long long _a = (unsigned long long)(a), _b = (unsigned long long)(b); \
    g_checks++; \
    if (_a != _b) { \
        g_failures++; \
        fprintf(stderr, "FAIL [%s] %s:%d: %s == %s (%llu != %llu)\n", \
                g_current_test, __FILE__, __LINE__, #a, #b, _a, _b); \
    } \
} while (0)

#define T_NE_U(a, b) do { \
    unsigned long long _a = (unsigned long long)(a), _b = (unsigned long long)(b); \
    g_checks++; \
    if (_a == _b) { \
        g_failures++; \
        fprintf(stderr, "FAIL [%s] %s:%d: %s != %s (both %llu)\n", \
                g_current_test, __FILE__, __LINE__, #a, #b, _a); \
    } \
} while (0)

#define T_EQ_S(a, b) do { \
    const char *_a = (a), *_b = (b); \
    g_checks++; \
    if (!_a || !_b || strcmp(_a, _b) != 0) { \
        g_failures++; \
        fprintf(stderr, "FAIL [%s] %s:%d: \"%s\" != \"%s\"\n", \
                g_current_test, __FILE__, __LINE__, _a ? _a : "(null)", \
                _b ? _b : "(null)"); \
    } \
} while (0)

#define T_MEM_EQ(a, b, n) do { \
    g_checks++; \
    if (memcmp((a), (b), (n)) != 0) { \
        g_failures++; \
        fprintf(stderr, "FAIL [%s] %s:%d: %zu bytes differ\n", \
                g_current_test, __FILE__, __LINE__, (size_t)(n)); \
    } \
} while (0)

#define T_NOTE(fmt, ...) fprintf(stderr, "  note: " fmt "\n", ##__VA_ARGS__)

#define T_SUMMARY(suite) do { \
    fprintf(stderr, "\n=== %s: %u checks, %u failures ===\n", (suite), \
            g_checks, g_failures); \
    printf("%s checks=%u failures=%u\n", (suite), g_checks, g_failures); \
} while (0)

#define T_EXIT(suite) do { T_SUMMARY(suite); \
    return g_failures ? 1 : 0; } while (0)

#endif
