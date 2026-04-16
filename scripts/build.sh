#!/usr/bin/env bash
# =============================================================================
# scripts/build.sh
# Build the project and optionally deploy to the KR260 board.
# Works on: Linux (native AArch64 on the board), Linux x86 host, WSL2 on Windows.
#
# USAGE:
#   # Build only (auto-detects whether to cross-compile or build natively):
#   ./scripts/build.sh
#
#   # Build and deploy to the board:
#   ./scripts/build.sh --board-ip 192.168.1.xxx
#
#   # Build and deploy, with SSH key:
#   ./scripts/build.sh --board-ip 192.168.1.xxx --ssh-key ~/.ssh/id_rsa
#
#   # Run the benchmark after deploying:
#   ./scripts/build.sh --board-ip 192.168.1.xxx --run
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."     # always run from project root

# ---- colours ----------------------------------------------------------------
RED='\033[0;31m' GRN='\033[0;32m' YEL='\033[1;33m' CYN='\033[0;36m' NC='\033[0m'
info()  { echo -e "${CYN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GRN}[OK]${NC}    $*"; }
warn()  { echo -e "${YEL}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ---- defaults ---------------------------------------------------------------
BOARD_IP=""
SSH_KEY=""
DO_RUN=false
BUILD_DIR=""

# ---- parse arguments --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --board-ip)   BOARD_IP="$2";  shift 2 ;;
        --ssh-key)    SSH_KEY="$2";   shift 2 ;;
        --run)        DO_RUN=true;    shift   ;;
        --build-dir)  BUILD_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# USAGE/,/^# ===/p' "$0" | head -20
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

SSH_ARGS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5)
[[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")

# =============================================================================
# Step 1 — Detect build mode
# =============================================================================
ARCH=$(uname -m)
info "Host architecture: $ARCH"

if [[ "$ARCH" == "aarch64" ]]; then
    # Running ON the KR260 board — native build
    MODE="native"
    [[ -z "$BUILD_DIR" ]] && BUILD_DIR="build"
    info "Mode: native build on AArch64 (KR260 board)"
else
    # Cross-compiling from x86 Linux or WSL2
    MODE="cross"
    [[ -z "$BUILD_DIR" ]] && BUILD_DIR="build_arm64"
    info "Mode: cross-compile AArch64 from $ARCH"

    # Check the cross-compiler is installed
    if ! command -v aarch64-linux-gnu-g++ &>/dev/null; then
        warn "Cross-compiler not found. Installing..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
                binutils-aarch64-linux-gnu >/dev/null
        else
            die "Cannot install cross-compiler automatically. Run:\n  sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
        fi
    fi
    ok "Cross-compiler: $(aarch64-linux-gnu-g++ --version | head -1)"
fi

# =============================================================================
# Step 2 — CMake configure
# =============================================================================
info "Configuring (build dir: $BUILD_DIR)..."

CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release)
if [[ "$MODE" == "cross" ]]; then
    CMAKE_ARGS+=(-DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake)
fi

cmake -B "$BUILD_DIR" "${CMAKE_ARGS[@]}" 2>&1 | grep -E "^--|CMake|--" || true

# =============================================================================
# Step 3 — Build
# =============================================================================
JOBS=$(nproc 2>/dev/null || echo 4)
info "Building with $JOBS parallel jobs..."
cmake --build "$BUILD_DIR" -j"$JOBS"
ok "Binary: $BUILD_DIR/hft_kr260_bench"

# =============================================================================
# Step 4 — Deploy to board (optional)
# =============================================================================
if [[ -z "$BOARD_IP" ]]; then
    echo ""
    info "No --board-ip given. To deploy:"
    echo "    scp $BUILD_DIR/hft_kr260_bench ubuntu@<board-ip>:~/"
    echo "    ssh ubuntu@<board-ip> 'sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --realtime'"
    exit 0
fi

BOARD_USER="ubuntu"
BOARD_TARGET="${BOARD_USER}@${BOARD_IP}"

info "Deploying to $BOARD_TARGET..."
scp "${SSH_ARGS[@]}" "$BUILD_DIR/hft_kr260_bench" "${BOARD_TARGET}:~/"
ok "Binary deployed."

# =============================================================================
# Step 5 — Run (optional)
# =============================================================================
if $DO_RUN; then
    info "Running benchmark on board..."
    ssh "${SSH_ARGS[@]}" "$BOARD_TARGET" \
        "sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime"
else
    echo ""
    ok "Done. To run on the board:"
    echo "    ssh $BOARD_TARGET"
    echo "    sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime"
    echo "    sudo ./hft_kr260_bench --axi-base 0xa0000000 --realtime  # after FPGA programmed"
fi
