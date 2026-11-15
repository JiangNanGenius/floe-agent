/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Minimal LP64 CBLAS / Fortran BLAS declarations used by the provider, its
 * probe and its tests.  This header is deliberately not a replacement for a
 * system <cblas.h>: the provider exports exactly these ABI-compatible
 * symbols and does not include a conflicting enum typedef.
 *
 * Debian trixie's libblas3 uses 32-bit integer indices (LP64, not ILP64).
 * The provider does not intercept the ILP64 `*64_` symbols; callers using an
 * ILP64 BLAS keep their original provider.
 */
#ifndef FLOE_BLAS_CBLAS_H
#define FLOE_BLAS_CBLAS_H

#ifdef __cplusplus
extern "C" {
#endif

#define FLOE_CBLAS_ROW_MAJOR 101
#define FLOE_CBLAS_COL_MAJOR 102
#define FLOE_CBLAS_NO_TRANS 111
#define FLOE_CBLAS_TRANS 112
#define FLOE_CBLAS_CONJ_TRANS 113

void cblas_sgemm(int order, int transa, int transb,
                 int m, int n, int k, float alpha,
                 const float *a, int lda,
                 const float *b, int ldb,
                 float beta, float *c, int ldc);

void cblas_sgemv(int order, int transa,
                 int m, int n, float alpha,
                 const float *a, int lda,
                 const float *x, int incx,
                 float beta, float *y, int incy);

/* GNU Fortran passes hidden character lengths after the explicit arguments.
 * A C declaration with the standard 13/11 explicit parameters accepts those
 * trailing arguments on the arm64 ELF ABI; the implementation ignores them. */
void sgemm_(const char *transa, const char *transb,
            const int *m, const int *n, const int *k,
            const float *alpha, const float *a, const int *lda,
            const float *b, const int *ldb,
            const float *beta, float *c, const int *ldc);

void sgemm(const char *transa, const char *transb,
           const int *m, const int *n, const int *k,
           const float *alpha, const float *a, const int *lda,
           const float *b, const int *ldb,
           const float *beta, float *c, const int *ldc);

void sgemv_(const char *transa,
            const int *m, const int *n,
            const float *alpha, const float *a, const int *lda,
            const float *x, const int *incx,
            const float *beta, float *y, const int *incy);

void sgemv(const char *transa,
           const int *m, const int *n,
           const float *alpha, const float *a, const int *lda,
           const float *x, const int *incx,
           const float *beta, float *y, const int *incy);

#ifdef __cplusplus
}
#endif

#endif /* FLOE_BLAS_CBLAS_H */
