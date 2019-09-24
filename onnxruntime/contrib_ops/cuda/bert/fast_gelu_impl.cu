
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "core/providers/cuda/cuda_common.h"
#include "core/providers/cuda/cu_inc/common.cuh"
#include "core/providers/cuda/shared_inc/cuda_call.h"
#include <cuda_fp16.h>
#include <cublas_v2.h>
#include "fast_gelu_impl.h"

using namespace onnxruntime::cuda;

namespace onnxruntime {
namespace contrib {
namespace cuda {

/*
 The implementation of this file is based on gelu plugin in TensorRT demo:
 https://github.com/NVIDIA/TensorRT/tree/release/5.1/demo/BERT/
 It uses FP16 functions, which are only supported on arch >= 5.3
*/
#ifdef USE_CUDA_FP16


// constants for approximating the normal cdf
constexpr float A = 0.5;

constexpr float B = 0.7978845608028654;  // sqrt(2.0/M_PI)

constexpr float C = 0.035677408136300125;  // 0.044715 * sqrt(2.0/M_PI)

__device__ inline float tanh(const float& x) {
  return tanhf(x);
}

__device__ inline half tanh(const half& x) {
  const float tmp = tanhf(__half2float(x));
  return __float2half(tmp);
}

__device__ inline half2 tanh(const half2& x) {
  // at the moment, there is no half2 tanh builtin
  float2 tmp = (__half22float2(x));
  tmp.x = tanhf(tmp.x);
  tmp.y = tanhf(tmp.y);
  return __float22half2_rn(tmp);
}

template <typename T, unsigned TPB>
__global__ void geluKernel(const T a, const T b, const T c, int n, const T* input, T* output) {
  const int idx = blockIdx.x * TPB + threadIdx.x;

  if (idx < n) {
    const T in = input[idx];
    const T cdf = a + a * tanh(in * (c * in * in + b));
    output[idx] = in * cdf;
  }
}

int computeGelu(cudaStream_t stream, int n, const float* input, float* output) {
  constexpr int blockSize = 256;
  const int gridSize = (n + blockSize - 1) / blockSize;
  geluKernel<float, blockSize><<<gridSize, blockSize, 0, stream>>>(A, B, C, n, input, output);

  CUDA_CALL(cudaPeekAtLastError());
  return 0;
}

int computeGelu(cudaStream_t stream, int n, const half* input, half* output) {
  const int blockSize = 256;

  if (0 == (n & 1)) {
    const int n2 = n / 2;

    const int gridSize = (n2 + blockSize - 1) / blockSize;
    const half2 A2 = __floats2half2_rn(A, A);
    const half2 B2 = __floats2half2_rn(B, B);
    const half2 C2 = __floats2half2_rn(C, C);
    const half2* input2 = reinterpret_cast<const half2*>(input);
    half2* output2 = reinterpret_cast<half2*>(output);
    geluKernel<half2, blockSize><<<gridSize, blockSize, 0, stream>>>(A2, B2, C2, n2, input2, output2);
  } else {
    const int gridSize = (n + blockSize - 1) / blockSize;
    geluKernel<half, blockSize><<<gridSize, blockSize, 0, stream>>>(A, B, C, n, input, output);
  }

  CUDA_CALL(cudaPeekAtLastError());
  return 0;
}

void launchGeluKernel(
    const void* input,
    void* output,
    const int element_count,
    const size_t element_size) {
  // use default stream
  const cudaStream_t stream = nullptr;

  if (element_size == 2) {
    computeGelu(stream, element_count, reinterpret_cast<const half*>(input), reinterpret_cast<half*>(output));
  } else {
    computeGelu(stream, element_count, reinterpret_cast<const float*>(input), reinterpret_cast<float*>(output));
  }
}
#endif

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime