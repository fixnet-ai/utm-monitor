# UTM Monitor — Windows Guest installation script
# Downloads the correct binary from Host HTTP, installs service, starts Guest
#
# Usage (PowerShell as Administrator):
#   irm https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.ps1 | iex
#   # Then call: Install-UtmmGuest -Hostname windowsvm
#
#   Or download and run directly:
#   .\install.ps1 -Guest -Hostname windowsvm
#
# Parameters:
#   -Guest           Enable Guest mode (required)
#   -Hostname NAME   Guest hostname (e.g., windowsvm)

param(
    [switch]$Guest,
    [string]$Hostname = "",
    [int]$Port = 2121
)

function Install-UtmmGuest {
    param(
        [string]$Hostname,
        [int]$Port = 2121
    )

    $ErrorActionPreference = "Stop"
    $installDir = "C:\opt\utmm"

    Write-Host "==> UTM Monitor installer (Guest - Windows)"
    Write-Host "    install:  $installDir"
    Write-Host ""

    # 1. Detect CPU architecture
    $cpu = Get-CimInstance Win32_Processor
    $cpuArch = $cpu.Architecture
    switch ($cpuArch) {
        12 { $arch = "aarch64" }   # ARM64
         9 { $arch = "x86_64" }    # AMD64 / Intel 64-bit
         0 { $arch = "x86" }       # Intel 32-bit
         5 { $arch = "x86" }       # ARM 32-bit (use x86 binary as fallback)
        default {
            Write-Host "Warning: Unknown CPU architecture code $cpuArch, defaulting to x86_64"
            $arch = "x86_64"
        }
    }
    Write-Host "    arch:     $arch (code $cpuArch)"

    # 2. Detect OS
    $os = "windows"
    Write-Host "    os:       $os"

    # 3. Find default gateway
    Write-Host "    detecting gateway..."
    $gw = $null
    try {
        $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0").NextHop | Select-Object -First 1
    } catch {
        # Get-NetRoute failed, try fallback
    }

    # Fallback: probe known UTM bridge IPs
    if (-not $gw) {
        $fallbacks = @("192.168.64.1", "192.168.65.1", "192.168.66.1", "192.168.67.1")
        foreach ($ip in $fallbacks) {
            try {
                $null = Invoke-WebRequest -Uri "http://${ip}:${Port}/version" -TimeoutSec 2
                $gw = $ip
                break
            } catch {}
        }
    }

    if (-not $gw) {
        Write-Host ""
        Write-Host "Error: Could not detect Host gateway."
        Write-Host "  Is the Host machine running 'sudo utmm --host'?"
        Write-Host "  The Guest must be able to reach the Host at gateway:$Port"
        Write-Host ""
        Write-Host "  Manual fallback:"
        Write-Host "    .\install.ps1 -Guest -Hostname myvm  # and set gateway via env"
        exit 1
    }

    Write-Host "    gateway:  $gw"

    # 4. Construct download URL
    $bin = "utmm-${arch}-${os}.exe"
    $url = "http://${gw}:${Port}/bin/$bin"
    Write-Host "    binary:   $bin"
    Write-Host "    download: $url"
    Write-Host ""

    # 5. Create install directory
    Write-Host "==> Creating $installDir ..."
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null

    # 6. Download binary (to temp file first, then move — avoids file-locking issues)
    Write-Host "==> Downloading $url ..."
    $tmpFile = "$env:TEMP\utmm-new.exe"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmpFile -TimeoutSec 60
    } catch {
        Write-Host ""
        Write-Host "Error: Download failed: $_"
        Write-Host "  Verify the Host is running: sudo utmm --host"
        Write-Host "  Verify the binary exists on Host: dir C:\opt\utmm\$bin  (from Host)"
        exit 1
    }

    Write-Host "==> Downloaded: $((Get-Item $tmpFile).Length) bytes"

    # Stop any existing utmm process before replacing binary
    try {
        Stop-Process -Name utmm -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    } catch {}

    # Move temp file to install dir
    Move-Item -Force $tmpFile "$installDir\utmm.exe"

    # 7. Install as system service
    Write-Host "==> Installing auto-start service..."
    try {
        & "$installDir\utmm.exe" --install
    } catch {
        Write-Host "Warning: Service installation failed: $_"
        Write-Host "  Guest will still run but won't auto-start on boot."
    }

    # 8. Start Guest
    Write-Host "==> Starting Guest..."
    $args = @()
    if ($Hostname) {
        $args = @("--hostname", $Hostname)
        Write-Host "    hostname: $Hostname"
    } else {
        Write-Host "    (using OS hostname)"
    }

    Start-Process -NoNewWindow -FilePath "$installDir\utmm.exe" -ArgumentList $args

    Start-Sleep -Seconds 1
    Write-Host ""
    Write-Host "==> Guest installation complete!"
    try {
        & "$installDir\utmm.exe" --version
    } catch {}
    Write-Host ""
    Write-Host "==> Verify on Host: utmm --host --status"
}

# ─── Main ───────────────────────────────────────────────────────────

if (-not $Guest) {
    Write-Host "UTM Monitor installer"
    Write-Host ""
    Write-Host "For Host installation, run install.sh on macOS/Linux:"
    Write-Host "  curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh"
    Write-Host ""
    Write-Host "For Guest installation on Windows:"
    Write-Host "  .\install.ps1 -Guest -Hostname windowsvm"
    Write-Host ""
    Write-Host "  Or via remote execution:"
    Write-Host "  irm https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.ps1 | iex"
    Write-Host "  Install-UtmmGuest -Hostname windowsvm"
    exit 1
}

Install-UtmmGuest -Hostname $Hostname -Port $Port
