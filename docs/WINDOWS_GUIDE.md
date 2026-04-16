# Getting Started on Windows

Everything in this project works on Windows. The only difference from
Linux is how you build the C++ code and which terminal tools you use.

---

## Tools to install (all free)

| Tool | What it does | Download |
|------|-------------|----------|
| **Balena Etcher** | Flash Ubuntu image to SD card | balena.io/etcher |
| **PuTTY** | SSH + serial console to the KR260 | putty.org |
| **WinSCP** | Copy files to the board (GUI drag & drop) | winscp.net |
| **Vivado 2025.1** | FPGA synthesis + bitstream | xilinx.com/support/download |

Windows 10/11 also has `ssh` and `scp` built into PowerShell — you can use
those instead of PuTTY/WinSCP if you prefer the command line.

---

## Step 1 — Flash the SD card

1. Download the Kria Ubuntu 22.04 image: `ubuntu.com/download/amd`
2. Open Balena Etcher → Flash from file → select the `.img.xz` → select your SD card → Flash

---

## Step 2 — Connect to the board

**Serial console (first boot, before you have an IP address):**
1. Plug the USB-C cable into **J4** on the KR260 (bottom edge)
2. Open Device Manager → Ports (COM & LPT) → note the COM number (e.g. COM4)
3. Open PuTTY → Connection type: **Serial** → Serial line: `COM4` → Speed: `115200` → Open
4. Power on the board. Login: `ubuntu` / `ubuntu` (will force password change)

**SSH (once you have an IP):**
```powershell
# Built-in Windows SSH — works in PowerShell or CMD
ssh ubuntu@192.168.1.xxx

# Or use PuTTY: Hostname = 192.168.1.xxx, Port 22, Connection type SSH
```

Find the board's IP on the serial console:
```bash
ip addr show eth0
```

---

## Step 3 — Copy project files to the board

**Option A — WinSCP (GUI):**
1. Open WinSCP → New Site → SFTP → Host: `192.168.1.xxx` → User: `ubuntu`
2. Drag the `hft-kr260` folder from your PC to `/home/ubuntu/` on the board

**Option B — Built-in scp in PowerShell:**
```powershell
scp -r C:\path\to\hft-kr260 ubuntu@192.168.1.xxx:/home/ubuntu/
```

---

## Step 4 — Build the C++ code

### Option A: Build directly on the KR260 board (simplest, no extra tools needed)

```bash
# SSH into the board, then:
sudo apt install -y build-essential cmake
cd ~/hft-kr260
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j4
```

Build takes about 2–3 minutes. The binary ends up at `~/hft-kr260/build/hft_kr260_bench`.

### Option B: Cross-compile using WSL2 on Windows (faster iteration)

**Install WSL2** (one-time, 5 minutes):
```powershell
# In PowerShell as Administrator:
wsl --install
# Restart when prompted. Opens Ubuntu by default.
```

**Inside WSL2:**
```bash
sudo apt install -y cmake g++-aarch64-linux-gnu binutils-aarch64-linux-gnu

# The Windows filesystem is mounted at /mnt/c/
cd /mnt/c/path/to/hft-kr260
mkdir build_arm64 && cd build_arm64
cmake .. -DCMAKE_TOOLCHAIN_FILE=../cmake/aarch64-toolchain.cmake \
         -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

Copy the binary to the board:
```bash
# Still inside WSL2:
scp build_arm64/hft_kr260_bench ubuntu@192.168.1.xxx:~/
```

---

## Step 5 — Run the benchmark

```bash
# On the KR260 (via SSH):
sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime
```

---

## Step 6 — Build the FPGA bitstream (Vivado on Windows)

Vivado runs natively on Windows. The TCL script works without modification.

```powershell
# In PowerShell, from the hft-kr260\fpga\scripts\ directory:
vivado -mode batch -source create_kr260_project.tcl
```

Or open Vivado normally and in the Tcl Console:
```tcl
cd C:/path/to/hft-kr260/fpga/scripts
source create_kr260_project.tcl
```

Then:
1. Open the generated project: `File → Open Project → vivado_project\hft_kr260.xpr`
2. Flow → Run Synthesis
3. Flow → Run Implementation
4. Flow → Generate Bitstream

Copy the bitstream to the board:
```powershell
scp vivado_project\hft_kr260.runs\impl_1\kr260_system_wrapper.bit ubuntu@192.168.1.xxx:/home/ubuntu/
```

Program it:
```bash
# On the KR260:
sudo fpgautil -b kr260_system_wrapper.bit
sudo ./hft_kr260_bench --axi-base 0xa0000000 --realtime
```

---

## Troubleshooting on Windows

**PuTTY shows no output on serial:**
- Check COM port in Device Manager
- Settings: 115200 baud, 8 data bits, 1 stop bit, no parity, no flow control

**`scp` fails with "not recognized":**
- Make sure you're using PowerShell or CMD, not an old 32-bit terminal
- Alternative: use WinSCP

**Vivado TCL script fails with path error:**
- Run from the `fpga\scripts\` directory, not from the project root
- Use forward slashes in paths inside Vivado: `C:/Users/...` not `C:\Users\...`

**WSL2 can't see the board on the network:**
- WSL2 uses NAT by default. Either:
  - Use `scp` from PowerShell (outside WSL2) to copy files to the board
  - Or set WSL2 to bridged mode: `wsl --set-default-version 2` then configure in `.wslconfig`

**Cross-compiler not found:**
```bash
# In WSL2:
which aarch64-linux-gnu-g++   # should print a path
# If not found:
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
```
