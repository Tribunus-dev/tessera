set(TARGET llama-imatrix)
add_executable(${TARGET}
    imatrix.cpp
    # offline DFlash feature-capture file format (shared with the training driver)
    ${CMAKE_CURRENT_SOURCE_DIR}/../quantize/tessera/tessera-features.cpp
    # unified spec-calib telemetry writer (v3 schema, with v1 adapter)
    telemetry-record.cpp
    # Phase imatrix-crash-safe: DuckDB-backed persistent imatrix_accum_state
    ${CMAKE_CURRENT_SOURCE_DIR}/../quantize/tessera/tessera-quantize-db.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/../quantize/tessera/tessera-db-buffer.cpp
    # DuckDB amalgamation (self-contained, no external library needed)
    ${PROJECT_SOURCE_DIR}/third-party/duckdb/duckdb.cpp
)
target_include_directories(${TARGET} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../quantize/tessera
    ${PROJECT_SOURCE_DIR}/third-party/duckdb)
target_link_libraries(${TARGET} PRIVATE llama-common llama ${CMAKE_THREAD_LIBS_INIT})
target_compile_features(${TARGET} PRIVATE cxx_std_17)

if(LLAMA_TOOLS_INSTALL)
    install(TARGETS ${TARGET} RUNTIME)
endif()

if (CMAKE_SYSTEM_NAME MATCHES "AIX")
    # AIX's flock() function comes from libbsd.a
    target_link_libraries(${TARGET} PRIVATE -lbsd)
endif()
