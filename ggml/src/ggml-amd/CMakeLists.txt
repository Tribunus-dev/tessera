include(CheckLanguage)

if (NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "GGML_AMD requires Linux dma-buf support")
endif()

# The HIP provider is the only AMD provider that can execute graph regions at
# present. Do not build a registry-only AMD backend that cannot compute.
if (NOT GGML_AMD_HIP)
    message(FATAL_ERROR "GGML_AMD requires GGML_AMD_HIP=ON. The Vulkan, ZenDNN, and XDNA adapters are experimental and cannot be used as the sole compute provider.")
endif()

if (NOT DEFINED ROCM_PATH OR ROCM_PATH STREQUAL "")
    if (DEFINED ENV{ROCM_PATH} AND EXISTS "$ENV{ROCM_PATH}")
        set(ROCM_PATH "$ENV{ROCM_PATH}")
    elseif (EXISTS "/opt/rocm")
        set(ROCM_PATH "/opt/rocm")
    else()
        set(ROCM_PATH "/usr")
    endif()
endif()

list(APPEND CMAKE_PREFIX_PATH "${ROCM_PATH}" "${ROCM_PATH}/lib64/cmake")

string(REGEX MATCH "hipcc(\\.bat)?$" GGML_AMD_CXX_IS_HIPCC "${CMAKE_CXX_COMPILER}")

if (GGML_AMD_CXX_IS_HIPCC)
    message(WARNING "Using hipcc as the C++ compiler is legacy behavior. Prefer CMAKE_HIP_COMPILER or ROCM_PATH.")
else()
    if (AMDGPU_TARGETS AND NOT GPU_TARGETS)
        set(GPU_TARGETS ${AMDGPU_TARGETS})
    endif()
    if (GPU_TARGETS AND NOT CMAKE_HIP_ARCHITECTURES)
        set(CMAKE_HIP_ARCHITECTURES ${GPU_TARGETS})
    endif()

    get_filename_component(GGML_AMD_HIP_COMPILER_NAME "${CMAKE_HIP_COMPILER}" NAME)
    if ((NOT CMAKE_HIP_COMPILER OR GGML_AMD_HIP_COMPILER_NAME MATCHES "^hipcc(\\.bat)?$") AND EXISTS "${ROCM_PATH}/llvm/bin/clang++")
        set(CMAKE_HIP_COMPILER "${ROCM_PATH}/llvm/bin/clang++" CACHE FILEPATH "HIP compiler" FORCE)
    endif()

    check_language(HIP)
    if (NOT CMAKE_HIP_COMPILER)
        message(FATAL_ERROR "GGML_AMD_HIP=ON requires a ROCm HIP compiler. Set ROCM_PATH or CMAKE_HIP_COMPILER, then reconfigure.")
    endif()
    enable_language(HIP)
endif()

find_package(hip REQUIRED)
find_package(rocblas REQUIRED)
find_package(hipblas REQUIRED)

if (${hip_VERSION} VERSION_LESS 6.1)
    message(FATAL_ERROR "GGML_AMD_HIP requires ROCm/HIP 6.1 or newer")
endif()

set(SOURCES
    ggml-amd.cpp
    ggml-amd-registry.cpp
    ggml-amd-device.cpp
    ggml-amd-probe.cpp
    ggml-amd-config.cpp
    ggml-amd-buffer.cpp
    ggml-amd-dmabuf.cpp
    ggml-amd-fence.cpp
    ggml-amd-region.cpp
    ggml-amd-scheduler.cpp
    ggml-amd-sched-integration.cpp
    ggml-amd-cost-model.cpp
    ggml-amd-cache.cpp
    ggml-amd-residency.cpp
    ggml-amd-metrics.cpp
    ggml-amd-tiered-memory.cpp
)

set(GGML_AMD_HIP_SOURCES
    providers/ggml-amd-hip.cpp
    tile/ggml-amd-tile-hip.cu
    tile/ggml-amd-tile-dump-dequant.cpp
    tile/ggml-amd-tile-ref.cpp
)
list(APPEND SOURCES ${GGML_AMD_HIP_SOURCES})

if (GGML_AMD_VULKAN)
    list(APPEND SOURCES providers/ggml-amd-vulkan.cpp)
endif()

if (GGML_AMD_ZENDNN)
    if (NOT ZENDNN_ROOT)
        set(ZENDNN_ROOT "$ENV{ZENDNN_ROOT}")
    endif()
    find_path(GGML_AMD_ZENDNN_INCLUDE_DIR zendnnl.hpp
        HINTS "${ZENDNN_ROOT}/zendnnl/include")
    find_library(GGML_AMD_ZENDNN_LIBRARY zendnnl
        HINTS "${ZENDNN_ROOT}/zendnnl/lib")
    if (NOT GGML_AMD_ZENDNN_INCLUDE_DIR OR NOT GGML_AMD_ZENDNN_LIBRARY)
        message(FATAL_ERROR "GGML_AMD_ZENDNN=ON requires ZENDNN_ROOT with zendnnl headers and library")
    endif()
    list(APPEND SOURCES providers/ggml-amd-zendnn.cpp)
endif()

if (GGML_AMD_XDNA)
    find_path(GGML_AMD_XRT_INCLUDE_DIR xrt/xrt_device.h)
    find_library(GGML_AMD_XRT_LIBRARY NAMES xrt_coreutil xrt_core)
    if (NOT GGML_AMD_XRT_INCLUDE_DIR OR NOT GGML_AMD_XRT_LIBRARY)
        message(FATAL_ERROR "GGML_AMD_XDNA=ON requires XRT headers and xrt_coreutil or xrt_core")
    endif()
    list(APPEND SOURCES
        providers/ggml-amd-xdna.cpp
        xdna/ggml-amd-xdna-translate.cpp
        xdna/ggml-amd-xdna-op-table.cpp
        xdna/ggml-amd-xdna-compile.cpp
        xdna/ggml-amd-xdna-cache.cpp
    )
endif()

ggml_add_backend_library(ggml-amd ${SOURCES})

target_include_directories(ggml-amd PRIVATE .)
target_include_directories(ggml-amd PRIVATE ${CMAKE_SOURCE_DIR}/ggml/include)

target_compile_definitions(ggml-amd PRIVATE GGML_AMD_BUILD=1)

target_compile_definitions(ggml-amd PRIVATE GGML_AMD_HIP=1)
target_link_libraries(ggml-amd PRIVATE hip::host roc::rocblas roc::hipblas)

if (GGML_AMD_CXX_IS_HIPCC)
    set_source_files_properties(${GGML_AMD_HIP_SOURCES} PROPERTIES LANGUAGE CXX)
    target_link_libraries(ggml-amd PRIVATE hip::device)
else()
    set_source_files_properties(${GGML_AMD_HIP_SOURCES} PROPERTIES LANGUAGE HIP)
    set_property(TARGET ggml-amd PROPERTY HIP_STANDARD 17)
    set_property(TARGET ggml-amd PROPERTY HIP_STANDARD_REQUIRED ON)
endif()
target_compile_options(ggml-amd PRIVATE "$<$<COMPILE_LANGUAGE:HIP>:-funsafe-math-optimizations>")

# Tessera Layer 1 instrumentation: tile/ggml-amd-tile-dump-dequant.cpp
# includes tessera-debug.h to write the dequant sidecar. The header
# lives in common/tessera-debug/ and is exposed as a public include
# dir on the llama-tessera-debug target. Guarded so the first caller wins.
if (NOT TARGET llama-tessera-debug)
    add_subdirectory(${CMAKE_SOURCE_DIR}/common/tessera-debug ${CMAKE_BINARY_DIR}/_deps/llama-tessera-debug)
endif()
target_link_libraries(ggml-amd PUBLIC llama-tessera-debug)

if (GGML_AMD_VULKAN)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_VULKAN=1)
    find_package(Vulkan REQUIRED)
    target_link_libraries(ggml-amd PRIVATE Vulkan::Vulkan)
endif()

if (GGML_AMD_ZENDNN)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_ZENDNN=1)
    target_include_directories(ggml-amd PRIVATE ${GGML_AMD_ZENDNN_INCLUDE_DIR})
endif()

if (GGML_AMD_XDNA)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_XDNA=1)
    # The adapter does not call XRT yet, so do not add a link dependency until
    # it owns real XRT objects and symbols.
    target_include_directories(ggml-amd PRIVATE ${GGML_AMD_XRT_INCLUDE_DIR})
endif()

if (GGML_AMD_METRICS)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_METRICS=1)
endif()
