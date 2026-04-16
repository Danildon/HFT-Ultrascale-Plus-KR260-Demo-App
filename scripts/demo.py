#!/usr/bin/env python3
"""
demo.py — Live HFT Order Book Demo
Streams binary market data through AXI DMA into the FPGA parser.
Reads TOB result via AXI4-Lite registers.

Run on the KR260 board:
    sudo python3 scripts/demo.py           # default: 1,000 messages
    sudo python3 scripts/demo.py --n 10000 # 10,000 messages
    sudo python3 scripts/demo.py --single  # single-message interactive mode

Prerequisites (one-time setup):
    sudo apt install git build-essential linux-headers-$(uname -r)
    git clone https://github.com/ikwzm/udmabuf /tmp/udmabuf
    cd /tmp/udmabuf && make && sudo make install
    sudo modprobe udmabuf udmabuf0=8388608
"""

import argparse
import mmap
import os
import struct
import sys
import time
import random

# =============================================================================
# Physical addresses (must match Vivado Address Editor)
# =============================================================================
# Addresses assigned by Vivado auto-assign (check the TCL output map to confirm).
# Vivado 2025.1 places DMA first, TOB second:
#   axi_dma_0 S_AXI_LITE  → 0xA000_0000  (DMA control registers)
#   kr260_top s_axi        → 0xA001_0000  (TOB registers)
# If your Vivado assigned them differently, update these two lines to match
# the "Use these in demo.py" box printed at the end of the TCL script.
DMA_BASE  = 0xA000_0000   # axi_dma control registers
TOB_BASE  = 0xA001_0000   # tob_axi_lite registers
DMA_SIZE  = 0x1000        # 4 KB register space
TOB_SIZE  = 0x1000        # 4 KB register space

# =============================================================================
# AXI DMA MM2S register offsets (Xilinx PG021)
# =============================================================================
DMA_MM2S_CR     = 0x00   # Control register
DMA_MM2S_SR     = 0x04   # Status register
DMA_MM2S_SA     = 0x18   # Source address (bits 31:0)
DMA_MM2S_SA_MSB = 0x1C   # Source address (bits 63:32)
DMA_MM2S_LEN    = 0x28   # Transfer length (writing triggers the transfer)

# DMA control register bits
DMA_CR_RS       = 0x0001  # Run/Stop
DMA_CR_RESET    = 0x0004  # Soft reset
DMA_CR_IOC_IRQ  = 0x1000  # Interrupt on complete enable

# DMA status register bits
DMA_SR_HALTED   = 0x0001
DMA_SR_IDLE     = 0x0002
DMA_SR_IOC_IRQ  = 0x1000  # interrupt on complete flag

# =============================================================================
# TOB register offsets (tob_axi_lite.v)
# =============================================================================
TOB_STATUS       = 0x00
TOB_TOB_CHANGED  = 0x04
TOB_MSG_CNT_LO   = 0x08
TOB_MSG_CNT_HI   = 0x0C
TOB_BID_PRICE_LO = 0x10
TOB_BID_PRICE_HI = 0x14
TOB_BID_QTY      = 0x18
TOB_ASK_PRICE_LO = 0x1C
TOB_ASK_PRICE_HI = 0x20
TOB_ASK_QTY      = 0x24
TOB_SPREAD_LO    = 0x28
TOB_SPREAD_HI    = 0x2C

TICK = 0.01   # $0.01 per tick

# =============================================================================
# Register helpers
# =============================================================================

def read32(m, offset):
    return struct.unpack_from('<I', m, offset)[0]

def write32(m, offset, value):
    struct.pack_into('<I', m, offset, value & 0xFFFF_FFFF)

def read64(m, offset_lo, offset_hi):
    lo = read32(m, offset_lo)
    hi = read32(m, offset_hi)
    return (hi << 32) | lo

# =============================================================================
# Message builders — binary ITCH-inspired wire format (big-endian)
# =============================================================================
# All messages:  type(1) + timestamp(8) + order_ref(8) + side(1) + qty(4) + price(8)
# Add Order:     30 bytes, type 'A' (0x41)
# Delete Order:  17 bytes, type 'D' (0x44): type+ts+ref only (no side/qty/price)
# Order Update:  21 bytes, type 'U' (0x55): type+ts+ref+new_qty
# Execute:       21 bytes, type 'E' (0x45): type+ts+ref+exec_qty

def build_add(ts, ref, side, qty, price_ticks):
    """30-byte Add Order message"""
    side_b = 0x42 if side == 'B' else 0x53  # 'B' or 'S'
    return (bytes([0x41]) +
            struct.pack('>Q', ts) +
            struct.pack('>Q', ref) +
            bytes([side_b]) +
            struct.pack('>I', qty) +
            struct.pack('>q', price_ticks))

def build_delete(ts, ref):
    """17-byte Delete Order message"""
    return (bytes([0x44]) +
            struct.pack('>Q', ts) +
            struct.pack('>Q', ref))

def build_execute(ts, ref, exec_qty):
    """21-byte Execute message"""
    return (bytes([0x45]) +
            struct.pack('>Q', ts) +
            struct.pack('>Q', ref) +
            struct.pack('>I', exec_qty))

# =============================================================================
# AXI DMA driver
# =============================================================================

class AxiDma:
    def __init__(self, dma_map):
        self.m = dma_map
        self._reset()

    def _reset(self):
        """Soft reset + re-enable the DMA engine"""
        write32(self.m, DMA_MM2S_CR, DMA_CR_RESET)
        for _ in range(1000):
            if not (read32(self.m, DMA_MM2S_CR) & DMA_CR_RESET):
                break
        write32(self.m, DMA_MM2S_CR, DMA_CR_RS)

    def transfer(self, phys_addr, length, timeout_ms=5000):
        """
        Start a DMA transfer from physical address, wait for completion.
        Returns elapsed time in microseconds.
        """
        # Ensure DMA is idle
        sr = read32(self.m, DMA_MM2S_SR)
        if sr & DMA_SR_HALTED:
            self._reset()

        # Clear any pending interrupt
        write32(self.m, DMA_MM2S_SR, DMA_SR_IOC_IRQ)

        # Set source address
        write32(self.m, DMA_MM2S_SA,     phys_addr & 0xFFFF_FFFF)
        write32(self.m, DMA_MM2S_SA_MSB, phys_addr >> 32)

        # Writing the length triggers the transfer
        t_start = time.perf_counter_ns()
        write32(self.m, DMA_MM2S_LEN, length)

        # Poll until idle (bit 1 of status register)
        deadline = time.perf_counter_ns() + timeout_ms * 1_000_000
        while True:
            sr = read32(self.m, DMA_MM2S_SR)
            if sr & DMA_SR_IDLE:
                break
            if time.perf_counter_ns() > deadline:
                raise TimeoutError(f"DMA transfer timed out (SR=0x{sr:08x})")

        t_end = time.perf_counter_ns()

        # Check for errors
        if sr & 0x70:  # DMAIntErr | DMASlvErr | DMADecErr
            raise RuntimeError(f"DMA error (SR=0x{sr:08x})")

        return (t_end - t_start) // 1000  # return µs

# =============================================================================
# TOB reader
# =============================================================================

def read_tob(tob_map):
    status  = read32(tob_map, TOB_STATUS)
    msg_cnt = read64(tob_map, TOB_MSG_CNT_LO, TOB_MSG_CNT_HI)
    bid     = read64(tob_map, TOB_BID_PRICE_LO, TOB_BID_PRICE_HI)
    bid_qty = read32(tob_map, TOB_BID_QTY)
    ask     = read64(tob_map, TOB_ASK_PRICE_LO, TOB_ASK_PRICE_HI)
    ask_qty = read32(tob_map, TOB_ASK_QTY)
    spread  = read64(tob_map, TOB_SPREAD_LO, TOB_SPREAD_HI)
    return {
        'valid':     bool(status & 1),
        'crossed':   bool((status >> 1) & 1),
        'error':     bool((status >> 2) & 1),
        'msg_count': msg_cnt,
        'bid':       bid * TICK,
        'bid_qty':   bid_qty,
        'ask':       ask * TICK,
        'ask_qty':   ask_qty,
        'spread':    spread * TICK,
    }

def print_tob(tob, label=""):
    if label:
        print(f"  {label}")
    if not tob['valid']:
        print("  Book: empty (need at least one bid and one ask)")
        return
    print(f"  Best bid:  ${tob['bid']:.2f}   qty={tob['bid_qty']}")
    print(f"  Best ask:  ${tob['ask']:.2f}   qty={tob['ask_qty']}")
    print(f"  Spread:    ${tob['spread']:.2f}")
    print(f"  FPGA msg count: {tob['msg_count']:,}")
    if tob['crossed']:
        print("  WARNING: crossed book (bid >= ask)")

# =============================================================================
# Message buffer generator
# =============================================================================

def generate_burst(n_messages, seed=42):
    """
    Generate n_messages synthetic ITCH-style market data messages.
    Simulates a realistic order book with bids and asks around $100.
    Returns a bytearray of back-to-back binary messages.
    """
    rng = random.Random(seed)
    buf = bytearray()

    ts  = 34_200_000_000_000   # 09:30:00 in nanoseconds
    active_refs = {}           # ref → (side, price_ticks)
    ref_counter = 1

    for i in range(n_messages):
        ts += rng.randint(100, 10_000)   # realistic inter-message gap

        # Decide message type
        if len(active_refs) < 20 or rng.random() < 0.6:
            # Add a new order
            side = 'B' if rng.random() < 0.5 else 'S'
            base = 10_000   # $100.00
            if side == 'B':
                price = base - rng.randint(0, 20)   # bid below $100
            else:
                price = base + rng.randint(1, 20)   # ask above $100
            qty = rng.choice([100, 200, 300, 500])
            ref = ref_counter
            ref_counter += 1

            active_refs[ref] = (side, price)
            buf += build_add(ts, ref, side, qty, price)

        elif rng.random() < 0.5 and active_refs:
            # Execute part of an existing order
            ref = rng.choice(list(active_refs.keys()))
            exec_qty = rng.choice([100, 200])
            buf += build_execute(ts, ref, exec_qty)

        elif active_refs:
            # Delete an existing order
            ref = rng.choice(list(active_refs.keys()))
            del active_refs[ref]
            buf += build_delete(ts, ref)

    return buf

# =============================================================================
# Demo modes
# =============================================================================

def demo_single_message(tob_map, dma, dma_buf, phys_addr):
    """Interactive mode: inject one message at a time, show TOB"""
    print("\nInteractive mode — inject messages one at a time")
    print("Press Enter after each step.\n")

    ts  = 34_200_000_000_000
    ref = 1

    steps = [
        ("Add bid:  100 shares @ $99.98",
         build_add(ts,         1, 'B', 100, 9998)),
        ("Add bid:  200 shares @ $99.99",
         build_add(ts+1000,    2, 'B', 200, 9999)),
        ("Add ask:   50 shares @ $100.02",
         build_add(ts+2000,    3, 'S',  50, 10002)),
        ("Add ask:  150 shares @ $100.01",
         build_add(ts+3000,    4, 'S', 150, 10001)),
        ("Execute bid @ $99.99 (100 shares) — spread tightens",
         build_execute(ts+4000, 2, 100)),
        ("Delete ask @ $100.02 — only $100.01 ask remains",
         build_delete(ts+5000,  3)),
    ]

    for label, msg in steps:
        input(f"  [{len(msg)} bytes]  {label}  →  press Enter")
        n = len(msg)
        dma_buf[:n] = msg
        elapsed = dma.transfer(phys_addr, n)
        time.sleep(0.001)
        tob = read_tob(tob_map)
        print(f"  DMA transfer: {elapsed} µs")
        print_tob(tob)
        print()

    print("Done.")

def demo_burst(tob_map, dma, dma_buf, phys_addr, n_messages):
    """Burst mode: stream N messages in one DMA transfer"""
    print(f"\nBurst mode — {n_messages:,} messages in one DMA transfer")
    print("─" * 52)

    # Build message buffer
    sys.stdout.write("  Building message buffer ... ")
    sys.stdout.flush()
    t0 = time.perf_counter()
    buf = generate_burst(n_messages)
    t_build = (time.perf_counter() - t0) * 1000

    n_bytes = len(buf)
    print(f"{n_bytes:,} bytes ({n_bytes/1024:.1f} KB) in {t_build:.1f} ms")

    if n_bytes > len(dma_buf):
        raise ValueError(f"Buffer too small: need {n_bytes} bytes, have {len(dma_buf)}")

    # Copy to DMA buffer
    dma_buf[:n_bytes] = buf

    # Trigger DMA
    sys.stdout.write("  Streaming to FPGA via AXI DMA ... ")
    sys.stdout.flush()
    elapsed_us = dma.transfer(phys_addr, n_bytes)
    print(f"done in {elapsed_us:,} µs  ({n_bytes/elapsed_us*1e3:.0f} MB/s)")

    # Small wait for FPGA pipeline to drain (4 cycles × 5 ns = 20 ns per message,
    # already negligible, but add margin for CDC latency)
    time.sleep(0.001)

    # Read TOB
    tob = read_tob(tob_map)

    print()
    print("  FPGA result")
    print("  " + "─" * 48)
    print_tob(tob)

    if tob['error']:
        print("  WARN: parse error flag set — check message format")

    print()
    print("  Performance summary")
    print("  " + "─" * 48)
    dma_ns_per_msg  = (elapsed_us * 1000) / n_messages
    fpga_ns_per_msg = 20.0   # 4 cycles × 5 ns @ 200 MHz
    sw_ns_per_msg   = 1460.0 # measured benchmark p50
    print(f"  Messages:         {n_messages:>10,}")
    print(f"  Buffer size:      {n_bytes:>10,} bytes")
    print(f"  DMA transfer:     {elapsed_us:>10,} µs total")
    print(f"  DMA per message:  {dma_ns_per_msg:>10.0f} ns")
    print(f"  FPGA pipeline:    {fpga_ns_per_msg:>10.0f} ns  (4 cycles @ 200 MHz)")
    print(f"  Software (bench): {sw_ns_per_msg:>10.0f} ns  (measured p50)")
    print(f"  FPGA speedup:     {sw_ns_per_msg/fpga_ns_per_msg:>9.0f}×")
    print()

# =============================================================================
# Main
# =============================================================================

def check_udmabuf():
    if not os.path.exists('/dev/udmabuf0'):
        print("ERROR: /dev/udmabuf0 not found.")
        print()
        print("Run the setup script first:")
        print("  chmod +x ~/hft-kr260/scripts/setup_dma.sh")
        print("  ~/hft-kr260/scripts/setup_dma.sh")
        print()
        print("Or manually:")
        print("  sudo apt install git build-essential linux-headers-$(uname -r)")
        print("  git clone --depth 1 https://github.com/ikwzm/udmabuf /tmp/udmabuf")
        print("  cd /tmp/udmabuf && make -j4")
        print("  sudo insmod /tmp/udmabuf/u-dma-buf.ko udmabuf0=8388608")
        print()
        print("To make persistent:")
        print("  sudo cp /tmp/udmabuf/u-dma-buf.ko /lib/modules/$(uname -r)/kernel/drivers/")
        print("  sudo depmod -a")
        print("  echo 'u-dma-buf' | sudo tee /etc/modules-load.d/u-dma-buf.conf")
        print("  echo 'options u-dma-buf udmabuf0=8388608' | sudo tee /etc/modprobe.d/u-dma-buf.conf")
        sys.exit(1)

def get_phys_addr():
    path = '/sys/class/u-dma-buf/udmabuf0/phys_addr'
    with open(path) as f:
        return int(f.read().strip(), 16)

def get_buf_size():
    path = '/sys/class/u-dma-buf/udmabuf0/size'
    with open(path) as f:
        return int(f.read().strip())

def main():
    parser = argparse.ArgumentParser(description='HFT FPGA Order Book Demo')
    parser.add_argument('--n',      type=int,  default=1000,
                        help='Number of messages for burst mode (default: 1000)')
    parser.add_argument('--single', action='store_true',
                        help='Interactive single-message mode')
    args = parser.parse_args()

    print()
    print("  HFT Order Book — Live FPGA Demo")
    print("  KR260 · AXI DMA · FPGA parser at 200 MHz")
    print()

    check_udmabuf()

    phys_addr = get_phys_addr()
    buf_size  = get_buf_size()
    print(f"  DMA buffer:  0x{phys_addr:08x}  ({buf_size//1024} KB)")
    print(f"  TOB regs:    0x{TOB_BASE:08x}")
    print(f"  DMA ctrl:    0x{DMA_BASE:08x}")
    print()

    # Open /dev/mem and map regions
    mem_fd = open('/dev/mem', 'r+b')
    tob_map = mmap.mmap(mem_fd.fileno(), TOB_SIZE, offset=TOB_BASE)
    dma_map = mmap.mmap(mem_fd.fileno(), DMA_SIZE, offset=DMA_BASE)

    # Map the DMA buffer
    dma_fd  = open('/dev/udmabuf0', 'r+b')
    dma_buf = mmap.mmap(dma_fd.fileno(), buf_size)

    dma = AxiDma(dma_map)

    try:
        if args.single:
            demo_single_message(tob_map, dma, dma_buf, phys_addr)
        else:
            demo_burst(tob_map, dma, dma_buf, phys_addr, args.n)
    finally:
        dma_buf.close()
        dma_fd.close()
        tob_map.close()
        dma_map.close()
        mem_fd.close()

if __name__ == '__main__':
    main()
