#!/usr/bin/env bash
# setup_dma.sh
# One-time setup on the KR260 board to install the u-dma-buf kernel module.
# This provides physically contiguous DMA-accessible memory for the AXI DMA.
# https://github.com/ikwzm/udmabuf
#
# Note: the module is called "u-dma-buf", NOT "udmabuf".
# The kernel has a built-in "udmabuf" for GPU display — that is the wrong one.

set -euo pipefail

BUF_SIZE=8388608   # 8 MB — enough for ~280,000 messages
KO_PATH="/tmp/udmabuf/u-dma-buf.ko"

info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()  { echo -e "\033[0;31m[FAIL]\033[0m  $*" >&2; exit 1; }

# Already loaded?
if [ -e /dev/udmabuf0 ] && lsmod | grep -q "u.dma.buf"; then
    ok "u-dma-buf already loaded."
    PHYS=$(cat /sys/class/u-dma-buf/udmabuf0/phys_addr 2>/dev/null || echo "unknown")
    SIZE=$(cat /sys/class/u-dma-buf/udmabuf0/size      2>/dev/null || echo "unknown")
    ok "Buffer: 0x${PHYS}  size: ${SIZE} bytes"
    exit 0
fi

# Unload the wrong built-in udmabuf if it got loaded
if lsmod | grep -q "^udmabuf "; then
    warn "Removing built-in 'udmabuf' (wrong module) ..."
    sudo rmmod udmabuf 2>/dev/null || true
fi

# Install build dependencies
info "Installing build dependencies ..."
sudo apt-get install -y git build-essential \
    "linux-headers-$(uname -r)" 2>&1 | tail -3

# Clone and build
if [ ! -f "$KO_PATH" ]; then
    info "Cloning u-dma-buf ..."
    rm -rf /tmp/udmabuf
    git clone --depth 1 https://github.com/ikwzm/udmabuf /tmp/udmabuf

    info "Building ..."
    cd /tmp/udmabuf
    make -j4
fi

# Load with insmod (no make install needed)
info "Loading u-dma-buf.ko with buffer size ${BUF_SIZE} bytes ..."
sudo insmod "$KO_PATH" udmabuf0=${BUF_SIZE}

# Verify
if [ ! -e /dev/udmabuf0 ]; then
    die "/dev/udmabuf0 not created. Run: dmesg | tail -20"
fi

PHYS=$(cat /sys/class/u-dma-buf/udmabuf0/phys_addr)
SIZE=$(cat /sys/class/u-dma-buf/udmabuf0/size)
ok "/dev/udmabuf0 ready"
ok "Physical address: 0x${PHYS}"
ok "Buffer size:      ${SIZE} bytes ($(( SIZE / 1024 / 1024 )) MB)"

# Make persistent
info "Making persistent across reboots ..."
sudo cp "$KO_PATH" /lib/modules/$(uname -r)/kernel/drivers/
sudo depmod -a
echo 'u-dma-buf' | sudo tee /etc/modules-load.d/u-dma-buf.conf > /dev/null
printf 'options u-dma-buf udmabuf0=%d\n' $BUF_SIZE \
    | sudo tee /etc/modprobe.d/u-dma-buf.conf > /dev/null

ok "Done. u-dma-buf will load automatically on next boot."
echo ""
echo "  Next steps:"
echo "    1. sudo fpgautil -b ~/kr260_system_wrapper.bit"
echo "    2. sudo python3 ~/hft-kr260/scripts/demo.py --single"
echo "    3. sudo python3 ~/hft-kr260/scripts/demo.py --n 10000"
