# =============================================================================
# scripts/build.ps1
# Build the project and optionally deploy to the KR260 board.
# Runs on Windows PowerShell. Requires WSL2 for cross-compilation.
#
# USAGE:
#   # Build only (using WSL2 cross-compiler):
#   .\scripts\build.ps1
#
#   # Build and deploy to the board:
#   .\scripts\build.ps1 -BoardIP 192.168.1.xxx
#
#   # Build, deploy, and run the benchmark:
#   .\scripts\build.ps1 -BoardIP 192.168.1.xxx -Run
#
#   # Use an SSH key instead of password:
#   .\scripts\build.ps1 -BoardIP 192.168.1.xxx -SSHKey C:\Users\you\.ssh\id_rsa
#
#   # Build on the board itself (no local cross-compilation):
#   .\scripts\build.ps1 -BoardIP 192.168.1.xxx -BuildOnBoard
# =============================================================================

param(
    [string]$BoardIP       = "",
    [string]$SSHKey        = "",
    [switch]$Run           = $false,
    [switch]$BuildOnBoard  = $false,
    [string]$BoardUser     = "ubuntu",
    [string]$BuildDir      = "build_arm64"
)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)   # run from project root

function Write-Info  { param($m) Write-Host "  [INFO]  $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "  [FAIL]  $m" -ForegroundColor Red; exit 1 }

$SSHArgs = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5")
if ($SSHKey) { $SSHArgs += @("-i", $SSHKey) }
$BoardTarget = "${BoardUser}@${BoardIP}"

Write-Host ""
Write-Host "  HFT KR260 — Build Script (Windows)" -ForegroundColor White
Write-Host "  Mode: $(if ($BuildOnBoard) {'build on board'} else {'WSL2 cross-compile'})" -ForegroundColor White
if ($BoardIP) { Write-Host "  Board: $BoardTarget" -ForegroundColor White }
Write-Host ""

# =============================================================================
# Mode A — Build directly on the KR260 board over SSH
# =============================================================================
if ($BuildOnBoard) {
    if (-not $BoardIP) { Write-Fail "-BuildOnBoard requires -BoardIP" }

    # Check SSH connectivity
    Write-Info "Testing SSH connection to $BoardTarget..."
    $test = ssh @SSHArgs $BoardTarget "echo connected" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Fail "Cannot SSH to $BoardTarget. Check IP and board is booted." }
    Write-Ok "SSH OK."

    # Install build tools on board if needed
    Write-Info "Ensuring build tools are installed on board..."
    ssh @SSHArgs $BoardTarget "command -v cmake g++ >/dev/null 2>&1 || sudo apt-get install -y build-essential cmake" | Out-Null

    # Copy source to board
    Write-Info "Copying project source to board..."
    $projectDir = (Get-Location).Path
    scp @SSHArgs -r $projectDir "${BoardTarget}:/home/${BoardUser}/hft-kr260"
    if ($LASTEXITCODE -ne 0) { Write-Fail "scp failed." }
    Write-Ok "Source copied."

    # Build on board
    Write-Info "Building on board (takes ~2-3 min)..."
    $buildCmd = "cd ~/hft-kr260 && mkdir -p build && cd build && " +
                "cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -3 && " +
                "make -j4 2>&1 | tail -5"
    ssh @SSHArgs $BoardTarget $buildCmd
    if ($LASTEXITCODE -ne 0) { Write-Fail "Build failed on board." }
    Write-Ok "Build complete. Binary at: ~/hft-kr260/build/hft_kr260_bench"

    if ($Run) {
        Write-Info "Running benchmark on board..."
        ssh @SSHArgs $BoardTarget "sudo ~/hft-kr260/build/hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime"
    }
    exit 0
}

# =============================================================================
# Mode B — Cross-compile using WSL2
# =============================================================================

# Check WSL2 is available
Write-Info "Checking WSL2..."
$wslList = wsl --list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Fail @"
WSL2 is not installed. To install:
  1. Open PowerShell as Administrator
  2. Run: wsl --install
  3. Restart your PC
  4. Re-run this script
"@
}
Write-Ok "WSL2 available."

# Convert Windows project path to WSL2 path
$winPath = (Get-Location).Path
$wslPath = wsl wslpath -u $winPath
$wslPath = $wslPath.Trim()
Write-Info "WSL2 project path: $wslPath"

# Install cross-compiler in WSL2 if needed
Write-Info "Checking cross-compiler in WSL2..."
$compilerCheck = wsl bash -c "command -v aarch64-linux-gnu-g++ 2>/dev/null" 2>&1
if (-not $compilerCheck) {
    Write-Info "Installing AArch64 cross-compiler in WSL2..."
    wsl bash -c "sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu" | Select-String -NotMatch "^Get:|^Fetched"
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to install cross-compiler." }
}
$compilerVer = (wsl bash -c "aarch64-linux-gnu-g++ --version | head -1").Trim()
Write-Ok "Cross-compiler: $compilerVer"

# CMake configure (inside WSL2)
Write-Info "Configuring build..."
$configCmd = "cd '$wslPath' && cmake -B $BuildDir -DCMAKE_BUILD_TYPE=Release " +
             "-DCMAKE_TOOLCHAIN_FILE=cmake/aarch64-toolchain.cmake 2>&1 | grep -E '^--|CMake' || true"
wsl bash -c $configCmd
if ($LASTEXITCODE -ne 0) { Write-Fail "CMake configure failed." }

# Build (inside WSL2)
$jobs = [Environment]::ProcessorCount
Write-Info "Building with $jobs jobs..."
$buildCmd = "cd '$wslPath' && cmake --build $BuildDir -j$jobs 2>&1 | tail -8"
wsl bash -c $buildCmd
if ($LASTEXITCODE -ne 0) { Write-Fail "Build failed." }

$binaryWin = Join-Path (Get-Location) "$BuildDir\hft_kr260_bench"
Write-Ok "Binary: $BuildDir\hft_kr260_bench"

# Deploy to board (optional)
if (-not $BoardIP) {
    Write-Host ""
    Write-Info "No -BoardIP given. To deploy manually:"
    Write-Host "  scp $BuildDir\hft_kr260_bench ubuntu@<board-ip>:~/" -ForegroundColor Gray
    Write-Host "  ssh ubuntu@<board-ip> 'sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --realtime'" -ForegroundColor Gray
    exit 0
}

# Test SSH
Write-Info "Testing SSH connection to $BoardTarget..."
$test = ssh @SSHArgs $BoardTarget "echo connected" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Fail "Cannot SSH to $BoardTarget." }
Write-Ok "SSH OK."

Write-Info "Deploying binary to board..."
scp @SSHArgs $binaryWin "${BoardTarget}:/home/${BoardUser}/"
if ($LASTEXITCODE -ne 0) { Write-Fail "scp failed." }
Write-Ok "Binary deployed."

if ($Run) {
    Write-Info "Running benchmark on board..."
    ssh @SSHArgs $BoardTarget "sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime"
} else {
    Write-Host ""
    Write-Ok "Done. To run on the board:"
    Write-Host "  ssh $BoardTarget" -ForegroundColor Gray
    Write-Host "  sudo ./hft_kr260_bench --core-feed 1 --core-reader 2 --messages 500000 --realtime" -ForegroundColor Gray
    Write-Host "  sudo ./hft_kr260_bench --axi-base 0xa0000000 --realtime  # after FPGA programmed" -ForegroundColor DarkGray
}
