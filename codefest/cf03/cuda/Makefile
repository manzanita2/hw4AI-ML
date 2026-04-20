SHELL := /bin/bash

NVCC ?= nvcc
HIPCC ?= hipcc
ROCPROF ?= rocprofv3

# Extra flags for thread-trace / UI output (rocprof-compute-viewer). Radeon (gfx10+):
# often needs e.g. --att-simd-select 0x0 — see ROCm "using thread trace" docs.
ROCPROF_UI_EXTRA ?=

ROCPROF_LIB_PATH ?= /home/hx3d/opt/rocm-systems/projects/rocprof-trace-decoder/build/lib

CXXFLAGS ?= -O3
NVFLAGS ?= -O3

NAIVE_SRC := gemm_naive.cu
TILED_SRC := gemm_tiled.cu

NV_NAIVE_BIN := gemm_naive_nvcc
NV_TILED_BIN := gemm_tiled_nvcc
HIP_NAIVE_BIN := gemm_naive_hip
HIP_TILED_BIN := gemm_tiled_hip

.PHONY: all help check-nvcc nvcc-build hip-build run-hip profile-hip profile-hip-ui profile-hip-all clean

all: hip-build

help:
	@echo "Targets:"
	@echo "  check-nvcc   - alias for nvcc-build"
	@echo "  nvcc-build   - compile both .cu files with nvcc"
	@echo "  hip-build    - compile both .cu files with hipcc"
	@echo "  run-hip      - run HIP binaries"
	@echo "  profile-hip  - kernel trace + stats CSV (rocprofv3)"
	@echo "  profile-hip-ui - thread trace (--att) -> ui_output_* for rocprof-compute-viewer"
	@echo "  profile-hip-all - profile-hip then profile-hip-ui"
	@echo "  clean        - remove generated binaries and profiles"

check-nvcc:
	@$(MAKE) nvcc-build

nvcc-build: $(NV_NAIVE_BIN) $(NV_TILED_BIN)

$(NV_NAIVE_BIN): $(NAIVE_SRC)
	$(NVCC) $(NVFLAGS) $< -o $@

$(NV_TILED_BIN): $(TILED_SRC)
	$(NVCC) $(NVFLAGS) $< -o $@

hip-build: $(HIP_NAIVE_BIN) $(HIP_TILED_BIN)

$(HIP_NAIVE_BIN): $(NAIVE_SRC)
	$(HIPCC) $(CXXFLAGS) $< -o $@

$(HIP_TILED_BIN): $(TILED_SRC)
	$(HIPCC) $(CXXFLAGS) $< -o $@

run-hip: hip-build
	./$(HIP_NAIVE_BIN)
	./$(HIP_TILED_BIN)

profile-hip: hip-build
	@command -v $(ROCPROF) >/dev/null 2>&1 || { \
		echo "rocprofv3 not found. Install ROCm profiler tools or set ROCPROF=/path/to/rocprofv3"; \
		exit 1; \
	}
	@mkdir -p profiling
	$(ROCPROF) --kernel-trace --stats -f csv -o profiling/gemm_naive_rocprofv3 -- ./$(HIP_NAIVE_BIN)
	$(ROCPROF) --kernel-trace --stats -f csv -o profiling/gemm_tiled_rocprofv3 -- ./$(HIP_TILED_BIN)
	@echo "Profiles written to profiling/"

# Advanced thread trace: produces stats_*.csv, ui_output_agent_*_dispatch_*/ (JSON) for ROCprof Compute Viewer.
# Open in viewer: Menu -> Import -> rocprofv3 UI, or point at directory containing ui_output_*.
profile-hip-ui: hip-build
	@command -v $(ROCPROF) >/dev/null 2>&1 || { \
		echo "rocprofv3 not found. Install ROCm profiler tools or set ROCPROF=/path/to/rocprofv3"; \
		exit 1; \
	}
	@mkdir -p profiling
	$(ROCPROF) --att --att-library-path $(ROCPROF_LIB_PATH) --stats -d profiling/ui_naive $(ROCPROF_UI_EXTRA) -- ./$(HIP_NAIVE_BIN)
	$(ROCPROF) --att --att-library-path $(ROCPROF_LIB_PATH) --stats -d profiling/ui_tiled $(ROCPROF_UI_EXTRA) -- ./$(HIP_TILED_BIN)
	@echo "Thread-trace + UI artifacts under profiling/ui_naive/ and profiling/ui_tiled/ (see ui_output_* dirs)"

profile-hip-all: profile-hip profile-hip-ui
	@echo "Done: CSV kernel trace + thread-trace UI outputs in profiling/"

clean:
	rm -f $(NV_NAIVE_BIN) $(NV_TILED_BIN) $(HIP_NAIVE_BIN) $(HIP_TILED_BIN)
	rm -rf profiling
