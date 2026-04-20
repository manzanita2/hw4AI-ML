#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#if defined(__HIPCC__)
#include <hip/hip_runtime.h>
#define cudaError_t hipError_t
#define cudaSuccess hipSuccess
#define cudaMalloc hipMalloc
#define cudaMemcpy hipMemcpy
#define cudaMemcpyHostToDevice hipMemcpyHostToDevice
#define cudaMemcpyDeviceToHost hipMemcpyDeviceToHost
#define cudaGetLastError hipGetLastError
#define cudaDeviceSynchronize hipDeviceSynchronize
#define cudaFree hipFree
#define cudaGetErrorString hipGetErrorString
#else
#include <cuda_runtime.h>
#endif

namespace {
constexpr int N = 1024;
constexpr int TILE = 8;

inline void checkCuda(cudaError_t err, const char* file, int line) {
  if (err != cudaSuccess) {
    std::fprintf(stderr, "CUDA/HIP error at %s:%d: %s\n", file, line, cudaGetErrorString(err));
    std::exit(EXIT_FAILURE);
  }
}

#define CHECK_CUDA(call) checkCuda((call), __FILE__, __LINE__)

__global__ void gemm_tiled_kernel(const float* A, const float* B, float* C) {
  __shared__ float As[TILE][TILE];
  __shared__ float Bs[TILE][TILE];

  const int row = blockIdx.y * TILE + threadIdx.y;
  const int col = blockIdx.x * TILE + threadIdx.x;
  float acc = 0.0f;

  for (int tileIdx = 0; tileIdx < N / TILE; ++tileIdx) {
    const int aCol = tileIdx * TILE + threadIdx.x;
    const int bRow = tileIdx * TILE + threadIdx.y;

    As[threadIdx.y][threadIdx.x] = (row < N && aCol < N) ? A[row * N + aCol] : 0.0f;
    Bs[threadIdx.y][threadIdx.x] = (bRow < N && col < N) ? B[bRow * N + col] : 0.0f;
    __syncthreads();

    for (int k = 0; k < TILE; ++k) {
      acc += As[threadIdx.y][k] * Bs[k][threadIdx.x];
    }
    __syncthreads();
  }

  if (row < N && col < N) {
    C[row * N + col] = acc;
  }
}

float cpuDotAt(const std::vector<float>& A, const std::vector<float>& B, int row, int col) {
  float acc = 0.0f;
  for (int k = 0; k < N; ++k) {
    acc += A[row * N + k] * B[k * N + col];
  }
  return acc;
}
}  // namespace

int main() {
  const size_t bytes = static_cast<size_t>(N) * N * sizeof(float);
  std::vector<float> hA(N * N), hB(N * N), hC(N * N, 0.0f);

  for (int i = 0; i < N; ++i) {
    for (int j = 0; j < N; ++j) {
      hA[i * N + j] = static_cast<float>((i + j) % 17) * 0.1f;
      hB[i * N + j] = static_cast<float>((i * 3 + j * 5) % 19) * 0.05f;
    }
  }

  float *dA = nullptr, *dB = nullptr, *dC = nullptr;
  CHECK_CUDA(cudaMalloc(&dA, bytes));
  CHECK_CUDA(cudaMalloc(&dB, bytes));
  CHECK_CUDA(cudaMalloc(&dC, bytes));

  CHECK_CUDA(cudaMemcpy(dA, hA.data(), bytes, cudaMemcpyHostToDevice));
  CHECK_CUDA(cudaMemcpy(dB, hB.data(), bytes, cudaMemcpyHostToDevice));

  const dim3 block(TILE, TILE);
  const dim3 grid((N + TILE - 1) / TILE, (N + TILE - 1) / TILE);
  gemm_tiled_kernel<<<grid, block>>>(dA, dB, dC);
  CHECK_CUDA(cudaGetLastError());
  CHECK_CUDA(cudaDeviceSynchronize());

  CHECK_CUDA(cudaMemcpy(hC.data(), dC, bytes, cudaMemcpyDeviceToHost));

  const int probes[4] = {0, 1, 511, 1023};
  float maxAbsErr = 0.0f;
  for (int r : probes) {
    for (int c : probes) {
      const float ref = cpuDotAt(hA, hB, r, c);
      const float err = std::fabs(hC[r * N + c] - ref);
      if (err > maxAbsErr) {
        maxAbsErr = err;
      }
    }
  }

  std::printf("gemm_tiled: N=%d tile=%d max_abs_err=%.6e\n", N, TILE, static_cast<double>(maxAbsErr));

  CHECK_CUDA(cudaFree(dA));
  CHECK_CUDA(cudaFree(dB));
  CHECK_CUDA(cudaFree(dC));
  return 0;
}
