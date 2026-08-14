#!/usr/bin/env bash

set -euo pipefail

WORKDIR="$(git rev-parse --show-toplevel)"
ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
BUILD_DIR="${1:-/tmp/tessera-amd-test}"
ENABLE_VULKAN="${2:-ON}"

usage() {
    echo "Usage: $0 [BUILD_DIR] [ON|OFF]"
    echo "  BUILD_DIR   CMake build directory (default: /tmp/tessera-amd-test)"
    echo "  ON|OFF      Enable Vulkan-backed path (default: ON)"
}

if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
    usage
    exit 0
fi

: "${LD_LIBRARY_PATH:=}"

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is missing"
    echo "Install it in the container: sudo apt-get update && sudo apt-get install -y cmake"
    exit 1
fi

if [ ! -d "$ROCM_PATH" ]; then
    echo "ROCM_PATH does not exist: $ROCM_PATH"
    exit 1
fi

if [ ! -d "$ROCM_PATH/include/hip" ]; then
    echo "ROCm headers missing under $ROCM_PATH/include/hip"
    echo "Check ROCm installation inside the container"
    exit 1
fi

export PATH="${ROCM_PATH}/bin:$PATH"
export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${ROCM_PATH}/lib64:${LD_LIBRARY_PATH}"

rm -rf "$BUILD_DIR"
cmake -S "$WORKDIR" -B "$BUILD_DIR" \
    -DGGML_AMD=ON \
    -DGGML_AMD_HIP=ON \
    -DGGML_AMD_VULKAN="${ENABLE_VULKAN}" \
    -DGGML_BUILD_TESTS=ON \
    -DROCM_PATH="${ROCM_PATH}" \
    -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --parallel

echo "Built test binaries in: $BUILD_DIR"
if [ -x "$BUILD_DIR/bin/test-amd-registry" ]; then
    export GGML_AMD_DMA_HEAP_PATH="${GGML_AMD_DMA_HEAP_PATH:-/dev/dma_heap/system-uncached:/dev/dma_heap/system:/dev/dma_heap/default_cma_region:/dev/dma_heap/cma:/dev/dma_heap/reserved}"
    "$BUILD_DIR/bin/test-amd-registry"
else
    echo "test-amd-registry not built"
    exit 1
fi
