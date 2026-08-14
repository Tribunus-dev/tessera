include(CheckLanguage)

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

if (GGML_AMD_HIP)
    check_language(HIP)
    if (CMAKE_HIP_COMPILER)
        enable_language(HIP)
        list(APPEND SOURCES
            providers/ggml-amd-hip.cpp
            tile/ggml-amd-tile-hip.cu
            tile/ggml-amd-tile-dump-dequant.cpp
            tile/ggml-amd-tile-ref.cpp
        )
    else()
        message(WARNING "HIP compiler not found, disabling GGML_AMD_HIP")
        set(GGML_AMD_HIP OFF)
    endif()
endif()

if (GGML_AMD_VULKAN)
    list(APPEND SOURCES providers/ggml-amd-vulkan.cpp)
endif()

if (GGML_AMD_ZENDNN)
    list(APPEND SOURCES providers/ggml-amd-zendnn.cpp)
endif()

if (GGML_AMD_XDNA)
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

if (GGML_AMD_HIP)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_HIP=1)
    find_package(hip REQUIRED)
    find_package(rocblas REQUIRED)
    find_package(hipblas REQUIRED)
    target_link_libraries(ggml-amd PRIVATE hip::host roc::rocblas roc::hipblas)

    # Tessera Layer 1 instrumentation: tile/ggml-amd-tile-dump-dequant.cpp
    # includes tessera-debug.h to write the dequant sidecar. The header
    # lives in common/tessera-debug/ and is exposed as a public include
    # dir on the llama-tessera-debug target. Guarded so the first caller wins.
    if (NOT TARGET llama-tessera-debug)
        add_subdirectory(${CMAKE_SOURCE_DIR}/common/tessera-debug ${CMAKE_BINARY_DIR}/_deps/llama-tessera-debug)
    endif()
    target_link_libraries(ggml-amd PUBLIC llama-tessera-debug)
endif()

if (GGML_AMD_VULKAN)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_VULKAN=1)
    find_package(Vulkan REQUIRED)
    target_link_libraries(ggml-amd PRIVATE Vulkan::Vulkan)
endif()

if (GGML_AMD_ZENDNN)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_ZENDNN=1)
endif()

if (GGML_AMD_XDNA)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_XDNA=1)
endif()

if (GGML_AMD_METRICS)
    target_compile_definitions(ggml-amd PRIVATE GGML_AMD_METRICS=1)
endif()
