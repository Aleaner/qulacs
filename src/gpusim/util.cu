#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <cuda_runtime.h>
//#include <cuda.h>
// for using cublas 
#include <cublas_v2.h>

#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <complex>
#include <assert.h>
#include <algorithm>
#include <cuComplex.h>
#include "util.h"
#include "util_common.h"
#include "util.cuh"

// return GTYPE*
GTYPE* allocate_quantum_state(ITYPE dim){
	GTYPE *state_gpu;
	checkCudaErrors(cudaSetDevice(0));
	checkCudaErrors(cudaMalloc((void**)&state_gpu, dim * sizeof(GTYPE)));
	//void* psi_gpu = reinterpret_cast<void*>(state_gpu);
    return state_gpu;
}

void initialize_quantum_state(GTYPE *state_gpu, ITYPE dim){
	//GTYPE* state_gpu = reinterpret_cast<cuDoubleComplex*>(psi_gpu);
	cudaError cudaStatus;
	unsigned int block = dim <= 1024 ? dim : 1024;
	unsigned int grid = dim / block;
	init_qstate << <grid, block >> >(state_gpu, dim);
	cudaStatus = cudaGetLastError();
	if (cudaStatus != cudaSuccess) {
		fprintf(stderr, "init_state_gpu failed: %s\n", cudaGetErrorString(cudaStatus));
	}
    //print_quantum_state(state_gpu, dim);
    //psi_gpu = reinterpret_cast<void*>(state_gpu);
}


void get_quantum_state(GTYPE* psi_gpu, void* psi_cpu_copy, ITYPE dim){
    // GTYPE* psi_gpu = reinterpret_cast<GTYPE*>(state_gpu);
    // CTYPE* state_cpu=(CTYPE*)malloc(sizeof(CTYPE)*dim);
    psi_cpu_copy = reinterpret_cast<CTYPE*>(psi_cpu_copy);
    checkCudaErrors(cudaDeviceSynchronize());
	checkCudaErrors(cudaMemcpy(psi_cpu_copy, psi_gpu, dim * sizeof(CTYPE), cudaMemcpyDeviceToHost));
    //state_cpu = reinterpret_cast<void*>(state_cpu);
    //print_quantum_state(psi_gpu, dim);
	//return psi_cpu_copy;
}

ITYPE insert_zero_to_basis_index(ITYPE basis_index, unsigned int qubit_index){
    ITYPE temp_basis = (basis_index >> qubit_index) << (qubit_index+1);
    return temp_basis + (basis_index & ( (1ULL<<qubit_index) -1));
}

void get_Pauli_masks_partial_list(const UINT* target_qubit_index_list, const UINT* Pauli_operator_type_list, UINT target_qubit_index_count, 
    ITYPE* bit_flip_mask, ITYPE* phase_flip_mask, UINT* global_phase_90rot_count, UINT* pivot_qubit_index){
    (*bit_flip_mask)=0;
    (*phase_flip_mask)=0;
    (*global_phase_90rot_count)=0;
    (*pivot_qubit_index)=0;
    for(UINT cursor=0;cursor < target_qubit_index_count; ++cursor){
        UINT target_qubit_index = target_qubit_index_list[cursor];
        switch(Pauli_operator_type_list[cursor]){
        case 0: // I
            break;
        case 1: // X
            (*bit_flip_mask) ^= 1ULL << target_qubit_index;
            (*pivot_qubit_index) = target_qubit_index;
            break;
        case 2: // Y
            (*bit_flip_mask) ^= 1ULL << target_qubit_index;
            (*phase_flip_mask) ^= 1ULL << target_qubit_index;
            (*global_phase_90rot_count) ++;
            (*pivot_qubit_index) = target_qubit_index;
            break;
        case 3: // Z
            (*phase_flip_mask) ^= 1ULL << target_qubit_index;
            break;
        default:
            fprintf(stderr,"Invalid Pauli operator ID called");
            assert(0);
        }
    }
}

void get_Pauli_masks_whole_list(const UINT* Pauli_operator_type_list, UINT target_qubit_index_count, 
    ITYPE* bit_flip_mask, ITYPE* phase_flip_mask, UINT* global_phase_90rot_count, UINT* pivot_qubit_index){

    (*bit_flip_mask)=0;
    (*phase_flip_mask)=0;
    (*global_phase_90rot_count)=0;
    (*pivot_qubit_index)=0;
    for(UINT target_qubit_index=0; target_qubit_index < target_qubit_index_count; ++target_qubit_index){
        switch(Pauli_operator_type_list[target_qubit_index]){
        case 0: // I
            break;
        case 1: // X
            (*bit_flip_mask) ^= 1ULL << target_qubit_index;
            (*pivot_qubit_index) = target_qubit_index;
            break;
        case 2: // Y
            (*bit_flip_mask) ^= 1ULL << target_qubit_index;
            (*phase_flip_mask) ^= 1ULL << target_qubit_index;
            (*global_phase_90rot_count) ++;
            (*pivot_qubit_index) = target_qubit_index;
            break;
        case 3: // Z
            (*phase_flip_mask) ^= 1ULL << target_qubit_index;
            break;
        default:
            fprintf(stderr,"Invalid Pauli operator ID called");
            assert(0);
        }
    }
}

ITYPE* create_matrix_mask_list(const UINT* qubit_index_list, UINT qubit_index_count){
    const ITYPE matrix_dim = 1ULL << qubit_index_count;
    ITYPE* mask_list = (ITYPE*) calloc((size_t)matrix_dim, sizeof(ITYPE));
    ITYPE cursor = 0;

    for(cursor=0;cursor < matrix_dim; ++cursor){
        for(UINT bit_cursor = 0; bit_cursor < qubit_index_count;++bit_cursor){
			if ((cursor >> bit_cursor) & 1) {
				UINT bit_index = qubit_index_list[bit_cursor];
				mask_list[cursor] ^= (1ULL << bit_index);
			}
        }
    }
    return mask_list;
}

UINT* create_sorted_ui_list(const UINT* array, size_t size){
    UINT* new_array = (UINT*)calloc(size,sizeof(UINT));
    memcpy(new_array, array, size*sizeof(UINT));
    std::sort(new_array, new_array+size);
    return new_array;
}

// C=alpha*A*B+beta*C
// in this wrapper, we assume beta is always zero!
int cublas_zgemm_wrapper(ITYPE n, CTYPE alpha, const CTYPE *h_A, const CTYPE *h_B, CTYPE beta, CTYPE *h_C){
    ITYPE n2 = n*n;
    cublasStatus_t status;
    cublasHandle_t handle;
    GTYPE *d_A;// = make_cuDoubleComplex(0.0,0.0);
    GTYPE *d_B;// = make_cuDoubleComplex(0,0);
    GTYPE *d_C;// = make_cuDoubleComplex(0,0);
    GTYPE d_alpha=make_cuDoubleComplex(alpha.real(), alpha.imag());
    GTYPE d_beta=make_cuDoubleComplex(beta.real(), beta.imag());
    int dev = 0; //findCudaDevice(argc, (const char **)argv);
    
    /* Initialize CUBLAS */
    status = cublasCreate(&handle);

    if (status != CUBLAS_STATUS_SUCCESS){
        fprintf(stderr, "!!!! CUBLAS initialization error\n");
        return EXIT_FAILURE;
    }

    /* Allocate device memory for the matrices */
    if (cudaMalloc(reinterpret_cast<void **>(&d_A), n2 * sizeof(d_A[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate A)\n");
        return EXIT_FAILURE;
    }

    if (cudaMalloc(reinterpret_cast<void **>(&d_B), n2 * sizeof(d_B[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate B)\n");
        return EXIT_FAILURE;
    }

    if (cudaMalloc(reinterpret_cast<void **>(&d_C), n2 * sizeof(d_C[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate C)\n");
        return EXIT_FAILURE;
    }

    /* Initialize the device matrices with the host matrices */
    //status = cublasSetVector(n2, sizeof(h_A[0]), h_A, 1, d_A, 1);
    status = cublasSetMatrix(n, n, sizeof(h_A[0]), h_A, n, d_A, n);
    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write A)\n");
        return EXIT_FAILURE;
    }

    //status = cublasSetVector(n2, sizeof(h_B[0]), h_B, 1, d_B, 1);
    status = cublasSetMatrix(n, n, sizeof(h_B[0]), h_B, n, d_B, n);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write B)\n");
        return EXIT_FAILURE;
    }

    //status = cublasSetVector(n2, sizeof(h_C[0]), h_C, 1, d_C, 1);
    status = cublasSetMatrix(n, n, sizeof(h_C[0]), h_C, n, d_C, n);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write C)\n");
        return EXIT_FAILURE;
    }
    /* Performs operation using cublas */
    status = cublasZgemm(handle, CUBLAS_OP_T, CUBLAS_OP_T, n, n, n, &d_alpha, d_A,
        n, d_B, n, &d_beta, d_C, n);

    //status=cublasZgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, d_A, N, d_B, N, &beta, d_C, N);
    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! kernel execution error.\n");
        return EXIT_FAILURE;
    }

    /* Allocate host memory for reading back the result from device memory */
    CTYPE* tmp_h_C = reinterpret_cast<CTYPE *>(malloc(n2 * sizeof(h_C[0])));

    if (tmp_h_C == 0) {
        fprintf(stderr, "!!!! host memory allocation error (C)\n");
        return EXIT_FAILURE;
    }

    /* Read the result back */
    status = cublasGetMatrix(n, n, sizeof(GTYPE), d_C, n, tmp_h_C, n);
    memcpy(h_C, tmp_h_C, sizeof(h_C[0])*n2);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (read C)\n");
        return EXIT_FAILURE;
    }
    if (cudaFree(d_A) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (A)\n");
        return EXIT_FAILURE;
    }

    if (cudaFree(d_B) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (B)\n");
        return EXIT_FAILURE;
    }

    if (cudaFree(d_C) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (C)\n");
        return EXIT_FAILURE;
    }

    /* Shutdown */
    status = cublasDestroy(handle);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! shutdown error (A)\n");
        return EXIT_FAILURE;
    }
    return 0;
}

// C=alpha*A*x+beta*y
// in this wrapper, we assume beta is always zero!
int cublas_zgemv_wrapper(ITYPE n, CTYPE alpha, const CTYPE *h_A, const CTYPE *h_x, CTYPE beta, CTYPE *h_y){
    ITYPE n2 = n*n;
    cublasStatus_t status;
    cublasHandle_t handle;
    GTYPE *d_A;
    GTYPE *d_x;
    GTYPE *d_y;
    GTYPE d_alpha=make_cuDoubleComplex(alpha.real(), alpha.imag());
    GTYPE d_beta=make_cuDoubleComplex(beta.real(), beta.imag());
    int dev = 0; //findCudaDevice(argc, (const char **)argv);
    
    /* Initialize CUBLAS */
    printf("simpleCUBLAS test running..\n");
    status = cublasCreate(&handle);

    if (status != CUBLAS_STATUS_SUCCESS){
        fprintf(stderr, "!!!! CUBLAS initialization error\n");
        return EXIT_FAILURE;
    }

    /* Allocate device memory for the matrices */
    if (cudaMalloc(reinterpret_cast<void **>(&d_A), n2 * sizeof(d_A[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate A)\n");
        return EXIT_FAILURE;
    }

    if (cudaMalloc(reinterpret_cast<void **>(&d_x), n * sizeof(d_x[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate x)\n");
        return EXIT_FAILURE;
    }

    if (cudaMalloc(reinterpret_cast<void **>(&d_y), n * sizeof(d_y[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate y)\n");
        return EXIT_FAILURE;
    }

    /* Initialize the device matrices with the host matrices */
    //status = cublasSetVector(n2, sizeof(h_A[0]), h_A, 1, d_A, 1);
    status = cublasSetMatrix(n, n, sizeof(h_A[0]), h_A, n, d_A, n);
    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write A)\n");
        return EXIT_FAILURE;
    }

    status = cublasSetVector(n, sizeof(h_x[0]), h_x, 1, d_x, 1);
    //status = cublasSetMatrix(n, n, sizeof(h_B[0]), h_B, n, d_B, n);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write x)\n");
        return EXIT_FAILURE;
    }

    status = cublasSetVector(n, sizeof(h_y[0]), h_y, 1, d_y, 1);
    //status = cublasSetMatrix(n, n, sizeof(h_C[0]), h_C, n, d_C, n);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write C)\n");
        return EXIT_FAILURE;
    }
    /* Performs operation using cublas */
    status = cublasZgemv(handle, CUBLAS_OP_T, n, n, &d_alpha, d_A, n,
        d_x, 1, &d_beta, d_y, 1);
/*
cublasStatus_t cublasZgemv(cublasHandle_t handle, cublasOperation_t trans,
                           int m, int n,
                           const cuDoubleComplex *alpha,
                           const cuDoubleComplex *A, int lda,
                           const cuDoubleComplex *x, int incx,
                           const cuDoubleComplex *beta,
                           cuDoubleComplex *y, int incy)
*/
    //status=cublasZgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, d_A, N, d_B, N, &beta, d_C, N);
    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! kernel execution error.\n");
        return EXIT_FAILURE;
    }

    /* Allocate host memory for reading back the result from device memory */
    CTYPE* tmp_h_y = reinterpret_cast<CTYPE *>(malloc(n * sizeof(h_y[0])));

    if (tmp_h_y == 0) {
        fprintf(stderr, "!!!! host memory allocation error (y)\n");
        return EXIT_FAILURE;
    }

    /* Read the result back */
    status = cublasGetVector(n, sizeof(GTYPE), d_y, 1, tmp_h_y, 1);
    /*
    cublasStatus_t cublasGetVector(int n, int elemSize, const void *x, int incx, void *y, int incy)
    */
    memcpy(h_y, tmp_h_y, sizeof(h_y[0])*n);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (read C)\n");
        return EXIT_FAILURE;
    }
    if (cudaFree(d_A) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (A)\n");
        return EXIT_FAILURE;
    }

    if (cudaFree(d_x) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (x)\n");
        return EXIT_FAILURE;
    }

    if (cudaFree(d_y) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (y)\n");
        return EXIT_FAILURE;
    }

    /* Shutdown */
    status = cublasDestroy(handle);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! shutdown error (A)\n");
        return EXIT_FAILURE;
    }
    return 0;
}

// we assume state has already allocated at device
int cublas_zgemv_wrapper(ITYPE n, const CTYPE *h_matrix, GTYPE *d_state){
    ITYPE n2 = n*n;
    cublasStatus_t status;
    cublasHandle_t handle;
    GTYPE *d_matrix;
    GTYPE *d_y; // this will include the answer of the state.
    GTYPE d_alpha = make_cuDoubleComplex(1.0, 0.0);
    GTYPE d_beta = make_cuDoubleComplex(0.0, 0.0);
    int dev = 0;
    
    /* Initialize CUBLAS */
    status = cublasCreate(&handle);

    if (status != CUBLAS_STATUS_SUCCESS){
        fprintf(stderr, "!!!! CUBLAS initialization error\n");
        return EXIT_FAILURE;
    }

    /* Allocate device memory for the matrices */
    if (cudaMalloc(reinterpret_cast<void **>(&d_matrix), n2 * sizeof(d_matrix[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate A)\n");
        return EXIT_FAILURE;
    }

    if (cudaMalloc(reinterpret_cast<void **>(&d_y), n * sizeof(d_y[0])) != cudaSuccess) {
        fprintf(stderr, "!!!! device memory allocation error (allocate y)\n");
        return EXIT_FAILURE;
    }
    // cudaMemset(&d_y, 0, sizeof(d_y[0])*n);
    /* Initialize the device matrices with the host matrices */
    status = cublasSetMatrix(n, n, sizeof(h_matrix[0]), h_matrix, n, d_matrix, n);
    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (write A)\n");
        return EXIT_FAILURE;
    }

    /* Performs operation using cublas */
    status = cublasZgemv(handle, CUBLAS_OP_T, n, n, &d_alpha, d_matrix, n,
        d_state, 1, &d_beta, d_y, 1);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! kernel execution error.\n");
        return EXIT_FAILURE;
    }

    cudaMemcpy(d_state, d_y, n * sizeof(GTYPE), cudaMemcpyDeviceToDevice);
   
    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! device access error (read C)\n");
        return EXIT_FAILURE;
    }
    if (cudaFree(d_matrix) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (A)\n");
        return EXIT_FAILURE;
    }

    if (cudaFree(d_y) != cudaSuccess) {
        fprintf(stderr, "!!!! memory free error (y)\n");
        return EXIT_FAILURE;
    }

    /* Shutdown */
    status = cublasDestroy(handle);

    if (status != CUBLAS_STATUS_SUCCESS) {
        fprintf(stderr, "!!!! shutdown error (A)\n");
        return EXIT_FAILURE;
    }
    return 0;
}
