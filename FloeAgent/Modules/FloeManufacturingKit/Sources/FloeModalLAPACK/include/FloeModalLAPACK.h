// SPDX-License-Identifier: MPL-2.0
#ifndef FLOE_MODAL_LAPACK_H
#define FLOE_MODAL_LAPACK_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* K,M are n*n column-major symmetric matrices. On success K contains
 mass-orthonormal eigenvectors by column and eigenvalues are ascending omega^2.
 Inputs are overwritten by LAPACK. n is bounded to512. No global state or IO.
 Status:0 success,1 invalid input,2 workspace/memory,3 convergence,
 4 non-positive mass matrix,5 invalid native argument. A synchronous native
 call drains before its caller may release arrays; cancellation is checked
 immediately before/after it by the owned Swift request. */
int floe_modal_generalized_eigen(int n,double *k,double *m,double *eigenvalues,int64_t *native_info);
#ifdef __cplusplus
}
#endif
#endif
