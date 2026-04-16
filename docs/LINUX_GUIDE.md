# Linux Guide

## Step 1 — Flash the SD card

```bash
# Download Kria Ubuntu image from https://ubuntu.com/download/amd
xz -d iot-limerick-kria-*.img.xz

# Flash (replace /dev/sdX with your SD card — check with lsblk first!)
sudo dd if=iot-limerick-kria-*.img of=/dev/sdX bs=4M status=progress
sync
```

## Step 2 — Connect to the board

Serial console (first boot):
```bash
# Find the port
ls /dev/ttyUSB*
sudo usermod -a -G dialout $USER   # add yourself to dialout group (then log out/in)

# Connect at 115200 baud
screen /dev/ttyUSB0 115200
# Or: picocom -b 115200 /dev/ttyUSB0
```

Login: `ubuntu` / `ubuntu` — it forces a password change immediately.

SSH (once you have an IP from `ip addr show eth0`):
```bash
ssh ubuntu@<board-ip>
```

## Step 3 — Build and deploy

```bash
# From the project root on your Linux machine:
chmod +x scripts/build.sh

# Build only (cross-compile, no deploy):
./scripts/build.sh

# Build and deploy to board:
./scripts/build.sh --board-ip 192.168.1.xxx

# Build, deploy, and run immediately:
./scripts/build.sh --board-ip 192.168.1.xxx --run
```

The script auto-installs `aarch64-linux-gnu-g++` if it's not already present.

**If you're already on the KR260 board** (native build):
```bash
sudo apt install -y build-essential cmake
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j4
```

## Step 4 — FPGA bitstream (requires Vivado)

```bash
# Install KR260 board files in Vivado first:
# Vivado GUI → Tools → Vivado Store → Boards → search KR260 → Install

cd fpga/scripts
vivado -mode batch -source create_kr260_project.tcl

# Then in Vivado GUI, open the project and:
#   Flow → Run Synthesis
#   Flow → Run Implementation
#   Flow → Generate Bitstream

# Copy bitstream to board:
scp vivado_project/hft_kr260.runs/impl_1/kr260_system_wrapper.bit ubuntu@<board-ip>:~/

# Program FPGA on the board:
ssh ubuntu@<board-ip> 'sudo fpgautil -b kr260_system_wrapper.bit'
```

## Step 5 — Run

```bash
ssh ubuntu@<board-ip>

# Software benchmark (no FPGA needed):
sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime

# With FPGA:
sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --axi-base 0xa0000000 --realtime
```

## Optional: isolate CPU cores for cleaner latency numbers

```bash
sudo nano /etc/default/grub
# Change:
GRUB_CMDLINE_LINUX=""
# To:
GRUB_CMDLINE_LINUX="isolcpus=1,2 nohz_full=1,2 rcu_nocbs=1,2"

sudo update-grub && sudo reboot
```

## Troubleshooting

```bash
# Cross-compiler not found:
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

# Permission denied on serial port:
sudo usermod -a -G dialout $USER
# Log out and back in

# FPGA manager not found on board:
sudo apt install fpga-manager-kria

# AXI address wrong (registers read 0xDEADBEEF):
cat /proc/iomem | grep a000
# Pass the correct address: --axi-base 0xYOURADDRESS
```
