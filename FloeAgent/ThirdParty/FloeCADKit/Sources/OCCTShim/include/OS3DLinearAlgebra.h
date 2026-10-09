//
//  OS3DLinearAlgebra.h
//  openshape3d
//
//  Dense linear-algebra kernels for the 2D constraint solver, on Accelerate's
//  LAPACK. A C shim rather than Swift calls so the NEW LAPACK interface
//  (`ACCELERATE_NEW_LAPACK`, stable since iOS 16.4) is what gets linked — the
//  classic CLAPACK symbols Swift sees by default are deprecated and their ABI
//  moved between SDKs, which is why this file did not exist before. Every
//  matrix is n×n or m×n `double`, fully stored; the callers keep them
//  row-major, which for the symmetric inputs here is the same as LAPACK's
//  column-major, and for the SVD is handled by passing the transpose.
//

#ifndef OS3DLinearAlgebra_h
#define OS3DLinearAlgebra_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Solve `A x = b` for a symmetric positive-definite `A` (n×n, full storage)
/// by Cholesky (`dposv`). `b` (length n) is overwritten with `x`. Returns
/// false — and leaves `b` unspecified — when `A` is not positive-definite.
bool os3d_solve_spd(const double *a, int n, double *b);

/// Singular values of an m×n ROW-MAJOR matrix, descending, into `s`
/// (length min(m, n)) via `dgesdd`. Returns false if the SVD failed to
/// converge (`s` unspecified).
bool os3d_singular_values(const double *a_row_major, int m, int n, double *s);

/// Eigen-decomposition of a symmetric n×n matrix (`dsyev`). On success `w`
/// (length n) holds the eigenvalues ASCENDING and `vectors` (n×n) holds the
/// eigenvectors as ROWS: `vectors[k*n + j]` is component j of eigenvector k.
bool os3d_symmetric_eigen(const double *a, int n, double *w, double *vectors);

#ifdef __cplusplus
}
#endif

#endif /* OS3DLinearAlgebra_h */
