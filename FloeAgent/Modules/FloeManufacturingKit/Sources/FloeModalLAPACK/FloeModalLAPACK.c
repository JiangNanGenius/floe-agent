// SPDX-License-Identifier: MPL-2.0
#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK
#endif
#ifndef ACCELERATE_LAPACK_ILP64
#define ACCELERATE_LAPACK_ILP64
#endif
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include "FloeModalLAPACK.h"

int floe_modal_generalized_eigen(int size,double *k,double *m,double *values,int64_t *native_info) {
    if(native_info)*native_info=0;
    if(size<1||size>512||!k||!m||!values)return 1;
    __LAPACK_int n=size,type=1,info=0,lwork=-1,liwork=-1,integer_query=0;
    char job='V',upper='U';double query=0;
    dsygvd_(&type,&job,&upper,&n,k,&n,m,&n,values,&query,&lwork,&integer_query,&liwork,&info);
    if(native_info)*native_info=info;
    if(info)return 5;
    if(!isfinite(query)||query<1||query>8.0*size*size+64*size+1024||integer_query<1||integer_query>32*size+1024)return 2;
    lwork=(__LAPACK_int)ceil(query);liwork=integer_query;
    double *work=malloc((size_t)lwork*sizeof(double));
    __LAPACK_int *iwork=malloc((size_t)liwork*sizeof(__LAPACK_int));
    if(!work||!iwork){free(work);free(iwork);return 2;}
    dsygvd_(&type,&job,&upper,&n,k,&n,m,&n,values,work,&lwork,iwork,&liwork,&info);
    free(work);free(iwork);if(native_info)*native_info=info;
    if(info<0)return 5;
    if(info>n)return 4;
    return info?3:0;
}
