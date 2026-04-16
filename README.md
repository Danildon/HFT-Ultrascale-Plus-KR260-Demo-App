# hft-kr260

Low-latency HFT order book for the **AMD Kria KR260** evaluation board.
Pipelined FPGA market data processing (SystemVerilog) + software benchmark
on the on-chip Cortex-A53 (C++20).

Works on **Windows and Linux** — pick your OS below.

---

## Architecture

```
  Binary market data frames (ITCH-inspired)
           │
           │  AXI4-Stream
           ▼
  ┌──────────────────────────────────────────┐
  │           Programmable Logic (PL)        │
  │                                          │
  │  market_data_parser.sv   3-stage pipe    │
  │           │  4 cycles = 40 ns @ 200 MHz  │
  │  order_book_engine.sv    register file   │
  │           │                              │
  │  tob_axi_lite.sv         AXI4-Lite regs  │
  └──────────────────────────────────────────┘
           │
           │  AXI4-Lite reads  (~15–25 ns)
           ▼
  ┌──────────────────────────────────────────┐
  │     Processing System (PS) Cortex-A53   │
  │                                          │
  │  kria_benchmark.cpp                      │
  │  reads FPGA TOB via /dev/mem mmap        │
  └──────────────────────────────────────────┘

  FPGA + AXI total: market data → A53 sees price ≈ 55–65 ns
```

---

## Project layout

```
hft-kr260/
├── CMakeLists.txt                    ← unified build (Linux + WSL2)
├── cmake/
│   └── aarch64-toolchain.cmake       ← cross-compile toolchain file
├── cpp/
│   ├── include/
│   │   ├── latency_timer_arm64.hpp   CNTVCT_EL0 timer (ARM64 equivalent of RDTSC)
│   │   ├── cpu_utils_arm64.hpp       Thread pinning, mlockall, DSB/ISB
│   │   ├── tob_axi_driver.hpp        /dev/mem AXI4-Lite register driver
│   │   ├── ring_buffer.hpp           SPSC lock-free ring buffer
│   │   ├── order_book.hpp            Array-indexed price book + seqlock
│   │   └── feed_handler.hpp          Binary market data decoder
│   └── src/
│       └── kria_benchmark.cpp        Benchmark: software path + AXI read latency
├── fpga/
│   ├── rtl/
│   │   ├── market_data_parser.sv     3-stage pipelined binary frame decoder
│   │   ├── order_book_engine.sv      1-cycle register-file order book
│   │   ├── tob_axi_lite.sv           AXI4-Lite slave: TOB register file
│   │   └── kr260_top.sv              Board top: PS clocks, CDC, AXI wiring
│   ├── tb/
│   │   └── tb_top.sv                 Self-checking testbench
│   ├── constraints/
│   │   └── kr260.xdc                 Timing constraints
│   └── scripts/
│       └── create_kr260_project.tcl  Vivado 2025.1 block design (Windows + Linux)
├── scripts/
│   ├── build.sh                      Build + deploy (Linux / WSL2)
│   └── build.ps1                     Build + deploy (Windows PowerShell)
└── docs/
    ├── WINDOWS_GUIDE.md              Step-by-step for Windows
    ├── LINUX_GUIDE.md                Step-by-step for Linux
    └── QUICK_REFERENCE.md            Commands cheat sheet
```

---

## Quick start — choose your OS

### Windows

**Tools needed:** [Vivado 2025.1](https://www.xilinx.com/support/download.html) · [Balena Etcher](https://balena.io/etcher) · [PuTTY](https://putty.org) · [WinSCP](https://winscp.net) · WSL2 (for C++ build)

```powershell
# 1. Flash SD card with Balena Etcher, boot board, connect via PuTTY serial (115200 baud)
# 2. Copy project to board with WinSCP, or:
scp -r hft-kr260 ubuntu@<board-ip>:~/

# 3. Build and deploy (uses WSL2 cross-compiler):
.\scripts\build.ps1 -BoardIP 192.168.1.xxx -Run

# OR: build directly on the board (no WSL2 needed):
.\scripts\build.ps1 -BoardIP 192.168.1.xxx -BuildOnBoard -Run

# 4. FPGA — in PowerShell from fpga\scripts\ directory:
cd fpga\scripts
vivado -mode batch -source create_kr260_project.tcl
# Then open project in Vivado GUI, run synthesis + implementation + generate bitstream
scp vivado_project\hft_kr260.runs\impl_1\kr260_system_wrapper.bit ubuntu@<board-ip>:~/
```

→ See `docs/WINDOWS_GUIDE.md` for the full walkthrough.

### Linux (or WSL2)

**Tools needed:** GCC AArch64 cross-compiler · CMake · Vivado 2025.1

```bash
# 1. Flash SD card
xz -d iot-limerick-*.img.xz
sudo dd if=*.img of=/dev/sdX bs=4M status=progress && sync

# 2. Build and deploy (auto-detects cross-compile vs native):
chmod +x scripts/build.sh
./scripts/build.sh --board-ip 192.168.1.xxx --run

# 3. FPGA — from fpga/scripts/ directory:
cd fpga/scripts
vivado -mode batch -source create_kr260_project.tcl
scp vivado_project/hft_kr260.runs/impl_1/kr260_system_wrapper.bit ubuntu@<board-ip>:~/
```

→ See `docs/LINUX_GUIDE.md` for the full walkthrough.

---

## Running the benchmark on the board

```bash
# Software path only (no FPGA needed):
sudo ./hft_kr260_bench \
    --core-feed 1 \
    --core-reader 2 \
    --messages 500000 \
    --realtime \
    --lock-mem

# With FPGA programmed (adds AXI register read latency test):
sudo ./hft_kr260_bench \
    --core-feed 1 \
    --core-reader 2 \
    --messages 500000 \
    --realtime \
    --axi-base 0xa0000000
```

Expected numbers:

| Metric | Expected |
|--------|---------|
| Software feed update p50 | ~145 ns |
| Software feed update p99.9 | ~310 ns |
| AXI TOB register read p50 | ~15–25 ns |
| FPGA pipeline latency | 40 ns (4 × 10 ns @ 200 MHz) |
| Combined (FPGA + AXI) p50 | ~55–65 ns |

---

## AXI4-Lite register map (base: `0xA000_0000`)

| Offset | Register | Notes |
|--------|----------|-------|
| `0x00` | STATUS | `[0]` tob_valid · `[1]` crossed · `[2]` parse_err (w1c) |
| `0x04` | TOB_CHANGED | Reads 1 if TOB updated since last read; clears on read |
| `0x08/0x0C` | MSG_COUNT | Total messages processed (64-bit) |
| `0x10/0x14` | BID_PRICE | Best bid price ticks (signed 64-bit) |
| `0x18` | BID_QTY | Best bid quantity |
| `0x1C/0x20` | ASK_PRICE | Best ask price ticks (signed 64-bit) |
| `0x24` | ASK_QTY | Best ask quantity |
| `0x28/0x2C` | SPREAD | Ask − bid in ticks (64-bit) |

Quick check from the board shell:
```bash
sudo python3 -c "
import mmap, struct
with open('/dev/mem','r+b') as f:
    m = mmap.mmap(f.fileno(), 4096, offset=0xa0000000)
    status = struct.unpack('<I', m[0:4])[0]
    bid = (struct.unpack('<q', m[0x10:0x18])[0]) * 0.01
    ask = (struct.unpack('<q', m[0x1c:0x24])[0]) * 0.01
    print(f'valid={status&1}  bid=\${bid:.2f}  ask=\${ask:.2f}')
    m.close()
"
```
