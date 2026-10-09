//
//  OS3DLinearAlgebra.c
//  openshape3d
//
//  See OS3DLinearAlgebra.h. The three LAPACK routines are declared here with
//  their Fortran ABI (32-bit integers by reference, the `_`-suffixed symbols
//  Accelerate's libLAPACK exports) instead of including <Accelerate/…>:
//  clang modules compile that framework header once, so a file-local
//  `#define ACCELERATE_NEW_LAPACK` never reaches it and the classic CLAPACK
//  declarations it falls back to are deprecated. The framework itself is
//  linked by `import Accelerate` in LinearAlgebra.swift.
//

#include <stdlib.h>
#include <string.h>

#include "OS3DLinearAlgebra.h"

extern void dposv_(const char *uplo, const int *n, const int *nrhs,
                   double *a, const int *lda, double *b, const int *ldb,
                   int *info);
extern void dgesdd_(const char *jobz, const int *m, const int *n, double *a,
                    const int *lda, double *s, double *u, const int *ldu,
                    double *vt, const int *ldvt, double *work,
                    const int *lwork, int *iwork, int *info);
extern void dsyev_(const char *jobz, const char *uplo, const int *n,
                   double *a, const int *lda, double *w, double *work,
                   const int *lwork, int *info);

bool os3d_solve_spd(const double *a, int n, double *b) {
    if (n <= 0) return true;
    size_t bytes = sizeof(double) * (size_t)n * (size_t)n;
    double *work = malloc(bytes);
    if (!work) return false;
    memcpy(work, a, bytes); // dposv factorises in place
    char uplo = 'U';
    int N = n, nrhs = 1, lda = n, ldb = n, info = 0;
    dposv_(&uplo, &N, &nrhs, work, &lda, b, &ldb, &info);
    free(work);
    return info == 0;
}

bool os3d_singular_values(const double *a_row_major, int m, int n, double *s) {
    if (m <= 0 || n <= 0) return true;
    // The row-major m×n buffer IS the column-major n×m transpose, and a
    // matrix and its transpose share singular values.
    size_t bytes = sizeof(double) * (size_t)m * (size_t)n;
    double *work_a = malloc(bytes);
    if (!work_a) return false;
    memcpy(work_a, a_row_major, bytes); // dgesdd destroys its input
    char jobz = 'N';
    int M = n, Nn = m, lda = n, ldu = 1, ldvt = 1, info = 0;
    int lwork = -1;
    double query = 0;
    int minmn = m < n ? m : n;
    int *iwork = malloc(sizeof(int) * (size_t)(8 * minmn));
    if (!iwork) { free(work_a); return false; }
    dgesdd_(&jobz, &M, &Nn, work_a, &lda, s, NULL, &ldu, NULL, &ldvt,
            &query, &lwork, iwork, &info);
    if (info != 0) { free(work_a); free(iwork); return false; }
    lwork = (int)query;
    double *work = malloc(sizeof(double) * (size_t)lwork);
    if (!work) { free(work_a); free(iwork); return false; }
    dgesdd_(&jobz, &M, &Nn, work_a, &lda, s, NULL, &ldu, NULL, &ldvt,
            work, &lwork, iwork, &info);
    free(work);
    free(iwork);
    free(work_a);
    return info == 0;
}

bool os3d_symmetric_eigen(const double *a, int n, double *w, double *vectors) {
    if (n <= 0) return true;
    size_t bytes = sizeof(double) * (size_t)n * (size_t)n;
    memcpy(vectors, a, bytes); // dsyev overwrites with the eigenvectors (columns, column-major = rows here)
    char jobz = 'V', uplo = 'U';
    int N = n, lda = n, lwork = -1, info = 0;
    double query = 0;
    dsyev_(&jobz, &uplo, &N, vectors, &lda, w, &query, &lwork, &info);
    if (info != 0) return false;
    lwork = (int)query;
    double *work = malloc(sizeof(double) * (size_t)lwork);
    if (!work) return false;
    dsyev_(&jobz, &uplo, &N, vectors, &lda, w, work, &lwork, &info);
    free(work);
    return info == 0;
}
