# cmake/aarch64-toolchain.cmake
# Cross-compilation toolchain for AArch64 (Cortex-A53 / Kria K26)
#
# USAGE:
#   cmake -DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake \
#         -DCMAKE_BUILD_TYPE=Release \
#         -B build_aarch64
#   cmake --build build_aarch64 -j$(nproc)
#
# Then copy the binary to the Kria board:
#   scp build_aarch64/hft_bench ubuntu@kria.local:~/
#   scp build_aarch64/hft_kria_bench ubuntu@kria.local:~/
#
# PREREQUISITES (Ubuntu/Debian x86 host):
#   sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu
#
# Alternatively, build natively ON the Kria board:
#   sudo apt install cmake g++ build-essential   # on the board
#   cmake -DCMAKE_BUILD_TYPE=Release .
#   make -j4

set(CMAKE_SYSTEM_NAME      Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Toolchain prefix — adjust if your cross-compiler has a different prefix
set(CROSS_PREFIX aarch64-linux-gnu-)

find_program(CMAKE_C_COMPILER   NAMES ${CROSS_PREFIX}gcc   REQUIRED)
find_program(CMAKE_CXX_COMPILER NAMES ${CROSS_PREFIX}g++   REQUIRED)
find_program(CMAKE_AR           NAMES ${CROSS_PREFIX}ar    REQUIRED)
find_program(CMAKE_STRIP        NAMES ${CROSS_PREFIX}strip REQUIRED)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
