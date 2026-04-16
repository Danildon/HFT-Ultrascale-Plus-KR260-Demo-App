cmake_minimum_required(VERSION 3.20)
project(hft_kr260 CXX)
 
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
 
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
 
# =============================================================================
# Platform detection
# =============================================================================
#
# Scenario A — Native build on the KR260 board (AArch64 Linux):
#   cmake -B build && cmake --build build -j4
#
# Scenario B — Cross-compile on a Linux x86 host or WSL2 (Windows):
#   cmake -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake -B build_arm64
#   cmake --build build_arm64 -j$(nproc)
#   scp build_arm64/hft_kr260_bench ubuntu@<board-ip>:~/
#
# Scenario C — Cross-compile using the helper scripts:
#   Linux/WSL2 : ./scripts/build.sh    [--board-ip 192.168.1.x]
#   Windows PS : .\scripts\build.ps1  -BoardIP 192.168.1.x
# =============================================================================
 
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(BUILDING_FOR_ARM64 TRUE)
    message(STATUS "Platform: AArch64 (native build on KR260 or cross-compilation target)")
elseif(CMAKE_CROSSCOMPILING AND CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(BUILDING_FOR_ARM64 TRUE)
    message(STATUS "Platform: AArch64 (cross-compiling)")
else()
    set(BUILDING_FOR_ARM64 FALSE)
    message(STATUS "Platform: ${CMAKE_SYSTEM_PROCESSOR}")
    message(STATUS "")
    message(STATUS "  NOTE: This project targets the KR260 (AArch64).")
    message(STATUS "  To cross-compile:")
    message(STATUS "    cmake -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake -B build_arm64")
    message(STATUS "  Or build directly on the KR260 board:")
    message(STATUS "    scp the source files to the board, then run cmake there.")
    message(STATUS "")
endif()
 
# =============================================================================
# Compiler flags
# =============================================================================
if(BUILDING_FOR_ARM64)
    add_compile_options(
        -mcpu=cortex-a53+crypto+crc+simd
        -mlittle-endian
    )
    add_compile_definitions(HFT_PLATFORM_ARM64)
endif()
 
add_compile_options(
    -O3
    -funroll-loops
    -fno-omit-frame-pointer
    -ffast-math
    -Wall -Wextra -Wno-conversion -Wno-unused-parameter
)
 
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    # LTO — available on GCC and Clang, skip if linker doesn't support it
    include(CheckIPOSupported)
    check_ipo_supported(RESULT ipo_ok OUTPUT ipo_msg)
    if(ipo_ok)
        set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
    else()
        message(STATUS "LTO not supported: ${ipo_msg}")
    endif()
endif()
 
# =============================================================================
# Build target
# =============================================================================
include_directories(${CMAKE_SOURCE_DIR}/cpp/include)
 
add_executable(hft_kr260_bench cpp/src/kria_benchmark.cpp)
target_link_libraries(hft_kr260_bench PRIVATE pthread rt)
 
# =============================================================================
# Install target (optional)
# =============================================================================
install(TARGETS hft_kr260_bench DESTINATION bin)
 
# =============================================================================
# Summary
# =============================================================================
message(STATUS "")
message(STATUS "  Build type : ${CMAKE_BUILD_TYPE}")
message(STATUS "  Compiler   : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "  Target     : hft_kr260_bench")
if(BUILDING_FOR_ARM64)
    message(STATUS "")
    message(STATUS "  To run on the KR260 board:")
    message(STATUS "    sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --realtime")
    message(STATUS "    sudo ./hft_kr260_bench --axi-base 0xa0000000 --realtime  (after FPGA programmed)")
endif()
message(STATUS "")