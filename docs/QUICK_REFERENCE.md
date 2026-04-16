# KR260 Quick Reference

## Today (Track 1 — software only, ~30 min)

```
PC:    Flash SD card with Kria Ubuntu image
PC:    Insert SD, connect USB-C serial cable, power on
PC:    screen /dev/ttyUSB0 115200  →  login: ubuntu / ubuntu
Board: sudo apt install build-essential cmake git
PC:    scp -r hft-orderbook/ hft-kria/ ubuntu@<IP>:~/
Board: cd ~ && mkdir build && cd build
Board: cmake ~/hft-kria -DCMAKE_BUILD_TYPE=Release
Board: make -j4
Board: sudo ./hft_kria_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime
```

## This week (Track 2 — FPGA, ~2-4 hours)

```
PC:    Install Vivado 2022.1+ (free WebPACK)
PC:    Install KR260 board files (Tools → Vivado Store)
PC:    cd hft-kria/fpga
PC:    vivado -mode batch -source bd_tcl/create_block_design.tcl
PC:    vivado vivado_project/hft_kr260.xpr
       → Run Synthesis → Run Implementation → Generate Bitstream
PC:    scp *.bit ubuntu@<IP>:~/
Board: sudo fpgautil -b kr260_system_wrapper.bit
Board: cat /sys/class/fpga_manager/fpga0/state   # should say "operating"
Board: sudo ./hft_kria_bench --axi-base 0xa0000000 --realtime
```

## Useful commands on the board

```bash
# Check which cores are isolated
cat /sys/devices/system/cpu/isolated

# Check CNTVCT frequency
python3 -c "
import ctypes, os
# Read CNTFRQ_EL0 via sysfs alternative
with open('/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq') as f:
    print('CPU max:', f.read().strip(), 'kHz')
"

# Monitor CPU frequency during benchmark
watch -n 0.5 "cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq"

# Check if FPGA is programmed
cat /sys/class/fpga_manager/fpga0/state

# Read AXI register manually (hex at offset 0x00 = STATUS)
sudo python3 -c "
import mmap, struct
with open('/dev/mem', 'rb') as f:
    m = mmap.mmap(f.fileno(), 4096, offset=0xa0000000)
    status = struct.unpack('<I', m[0:4])[0]
    print(f'STATUS: 0x{status:08x}')
    print(f'  tob_valid:    {status & 1}')
    print(f'  crossed_book: {(status >> 1) & 1}')
    print(f'  parse_error:  {(status >> 2) & 1}')
    m.close()
"

# Kill any stuck processes eating CPU
sudo killall hft_bench hft_kria_bench 2>/dev/null; true
```

## Expected numbers

| Metric                | Expected on KR260     |
|-----------------------|-----------------------|
| Software p50          | 130–180 ns            |
| Software p99.9        | 250–400 ns            |
| AXI register read p50 | 12–25 ns              |
| FPGA pipeline latency | 40 ns (4 × 10 ns)     |
| FPGA + AXI total p50  | ~55–65 ns             |
| CNTVCT_EL0 frequency  | 100 MHz (10 ns/tick)  |

## If something breaks

| Problem                        | Fix                                          |
|-------------------------------|----------------------------------------------|
| `x86intrin.h` not found       | Building wrong CMakeLists.txt — use hft-kria/ |
| `SCHED_FIFO` permission denied | `sudo setcap cap_sys_nice+ep ./hft_kria_bench` |
| AXI read returns 0xDEADBEEF   | Wrong base address — check /proc/iomem       |
| fpgautil not found            | `sudo apt install fpga-manager-kria`         |
| Board doesn't boot            | Re-flash SD card with Balena Etcher          |
| Serial console garbage        | Wrong baud rate — use 115200                 |
