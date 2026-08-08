cmake_minimum_required(VERSION 3.22)
project(tessera-android)
add_library(tessera-core SHARED native-lib.cpp)
find_library(log-lib log)
target_link_libraries(tessera-core ${log-lib})
# Shared C++ core: reuse tessera-studio-linux/src/core + ffi/ctessera as static lib
# For now minimal JNI bridge; full core linked via add_subdirectory when ndk toolchain ready
