@echo off
setlocal enabledelayedexpansion

:: ═══════════════════════════════════════════════════════════════════════
:: UTM Monitor — Windows Guest installer (batch)
:: Downloads the correct binary from Host HTTP, installs service, starts Guest
:: ═══════════════════════════════════════════════════════════════════════
::
:: ─── Prerequisites ────────────────────────────────────────────────────
::
::   Required tools (all built-in, no extra installs needed):
::     - bitsadmin                 — bundled with Windows 7 / Server 2008 R2+;
::                                   used as primary HTTP downloader
::     - curl                      — bundled with Windows 10 build 17063+;
::                                   used as automatic fallback if bitsadmin
::                                   is unavailable or fails
::     - Administrator privileges  — required for sc.exe service creation,
::                                    writing to C:\opt\utmm\, and
::                                    taskkill process management
::
::   Required permissions:
::     - Must run as Administrator  — right-click "Run as Administrator",
::       or from an elevated command prompt. Non-admin will fail at
::       mkdir C:\opt\utmm\ and sc create.
::
::   Network requirements:
::     - HTTP to Host at gateway:2121 — the Guest must be able to reach
::       the UTM Host machine (typically the VM bridge gateway).
::       No internet access required.
::
::   Supported Windows editions:
::     - Windows 7  / Server 2008 R2  (x86, x86_64)
::     - Windows 8  / 8.1 / Server 2012 / 2012 R2 (x86, x86_64)
::     - Windows 10 / 11 / Server 2016 / 2019 / 2022 (x86_64, aarch64)
::     - XP / Server 2003 — NOT supported (no bitsadmin by default,
::       no curl; requires manual binary deployment)
::
::   Supported CPU architectures:
::     - x86_64  / AMD64    (Intel/AMD 64-bit)
::     - aarch64 / ARM64    (ARM 64-bit — Windows on ARM, Win10+ only)
::     - x86                (Intel/AMD 32-bit)
::
:: ─── What this script does ────────────────────────────────────────────
::
::   1. Detect CPU architecture (PROCESSOR_ARCHITECTURE)
::   2. Auto-discover Host gateway IP (route print + UTM bridge fallback)
::   3. Download correct utmm-{arch}-windows.exe from Host HTTP /bin/
::      (bitsadmin primary, curl fallback — covers Win7 through Win11)
::   4. Stop existing utmm.exe process (taskkill)
::   5. Move binary to C:\opt\utmm\utmm.exe
::   6. Install Windows service (sc create) via utmm.exe --install
::      Service name: UTM-Monitor-Guest, auto-start on boot
::   7. Start service immediately
::
:: ─── Usage ────────────────────────────────────────────────────────────
::
::   Remote install from Host HTTP, as Administrator:
::
::     Win7+ (bitsadmin):  bitsadmin /transfer get_install /download /priority foreground "http://<gateway>:2121/bin/install.bat" "%TEMP%\install.bat" && call "%TEMP%\install.bat" --guest --hostname windowsvm
::
::     Win10+ (curl):      curl -fsSL http://<gateway>:2121/bin/install.bat -o install.bat && install.bat --guest --hostname windowsvm
::
::   Local install (binary already on disk):
::     install.bat --guest --hostname windowsvm
::
:: ─── Parameters ───────────────────────────────────────────────────────
::
::   --guest           Guest mode (required)
::   --hostname NAME   Guest hostname (required in guest mode)
::                     Used for mesh identity and /etc/hosts sync on Host.
::                     Must be unique across all Guests.
::   --port PORT       Host HTTP port (default: 2121)
::
:: ─── Post-Install ─────────────────────────────────────────────────────
::
::   Verify on Host:   utmm --host --status
::   Service control:  sc query UTM-Monitor-Guest
::                     sc stop  UTM-Monitor-Guest
::                     sc start UTM-Monitor-Guest
::   Logs:             C:\opt\utmm\utmm.log
::
::   Auto-upgrade (v0.11.14+): Guest detects Host version change via
::   mesh LSA and upgrades itself — no manual redeployment needed after
::   the initial install. Host never pushes upgrades.
::
:: ─── Troubleshooting ──────────────────────────────────────────────────
::
::   "Access denied"        → Not running as Administrator. Re-run from
::                            an elevated command prompt.
::   "Could not detect Host gateway"
::                          → Host service not running on gateway VM.
::                            Start it: sudo utmm --host
::   "Download failed"      → Host HTTP not reachable. Check network,
::                            firewall, and that the Host serve-dir
::                            contains the target binary.
::   Service won't start    → Check retry limit: sc failure
::                            Reinstall: install.bat --guest --hostname ...
:: ═══════════════════════════════════════════════════════════════════════

set "MODE="
set "HOSTNAME="
set "PORT=2121"

:parse_args
if "%~1"=="" goto end_args
if "%~1"=="--guest"   (set "MODE=guest"   & shift & goto parse_args)
if "%~1"=="-g"        (set "MODE=guest"   & shift & goto parse_args)
if "%~1"=="--hostname" (set "HOSTNAME=%~2" & shift & shift & goto parse_args)
if "%~1"=="-h"         (set "HOSTNAME=%~2" & shift & shift & goto parse_args)
if "%~1"=="--port"    (set "PORT=%~2"     & shift & shift & goto parse_args)
if "%~1"=="-p"        (set "PORT=%~2"     & shift & shift & goto parse_args)
shift & goto parse_args
:end_args

if not "%MODE%"=="guest" (
    echo UTM Monitor installer
    echo.
    echo For Host installation, run install.sh on macOS/Linux:
    echo   curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh ^| sh
    echo.
    echo For Guest installation on Windows:
    echo   install.bat --guest --hostname windowsvm
    echo.
    echo   Or via remote download:
    echo   Win7+:  bitsadmin /transfer get_install /download /priority foreground
    echo           "http://[gateway]:2121/bin/install.bat" "%%TEMP%%\install.bat"
    echo           ^&^& call "%%TEMP%%\install.bat" --guest --hostname windowsvm
    echo.
    echo   Win10+: curl -fsSL http://[gateway]:2121/bin/install.bat -o install.bat
    echo           ^&^& install.bat --guest --hostname windowsvm
    exit /b 1
)

if "%HOSTNAME%"=="" (
    echo Error: --hostname is required in guest mode
    echo Usage: install.bat --guest --hostname NAME [--port PORT]
    exit /b 1
)

set "INSTALL_DIR=C:\opt\utmm"

echo ==^> UTM Monitor installer ^(Guest - Windows^)
echo     install:  %INSTALL_DIR%
echo     hostname: %HOSTNAME%
echo     port:     %PORT%
echo.

:: ─── 1. Detect CPU architecture ──────────────────────────────────────────
set "CPU_ARCH=%PROCESSOR_ARCHITECTURE%"
if "%CPU_ARCH%"=="AMD64" (set "ARCH=x86_64"   & goto arch_done)
if "%CPU_ARCH%"=="ARM64" (set "ARCH=aarch64"  & goto arch_done)
:: x86, IA64, or unknown — default to x86
set "ARCH=x86"
:arch_done
echo     arch:     %ARCH% ^(PROCESSOR_ARCHITECTURE=%CPU_ARCH%^)

:: ─── 2. OS ───────────────────────────────────────────────────────────────
set "OS=windows"
echo     os:       %OS%

:: ─── 3. Find default gateway ─────────────────────────────────────────────
echo     detecting gateway...

set "GW="

:: Method 1: Parse route print for 0.0.0.0 default gateway
:: Output columns: Network Netmask Gateway Interface Metric
:: We want column 3 (Gateway)
for /f "tokens=3" %%a in ('route print 0.0.0.0 ^| findstr /r "0\.0\.0\.0.*[0-9]\.[0-9]"') do (
    if "!GW!"=="" set "GW=%%a"
)

:: Method 2: Fallback — probe known UTM bridge IPs via bitsadmin
:: bitsadmin is the most compatible HTTP client (Win7+).
:: We check whether the downloaded temp file is non-empty.
if "%GW%"=="" (
    set "FALLBACKS=192.168.64.1 192.168.65.1 192.168.66.1 192.168.67.1"
    for %%i in (!FALLBACKS!) do (
        if "!GW!"=="" (
            set "PROBE_URL=http://%%i:%PORT%/version"
            set "PROBE_OUT=%TEMP%\utmm_probe_%%i.txt"
            bitsadmin /transfer utmm_probe /download /priority foreground "!PROBE_URL!" "!PROBE_OUT!" >nul 2>&1
            if exist "!PROBE_OUT!" (
                for %%f in ("!PROBE_OUT!") do if %%~zf gtr 0 set "GW=%%i"
                del "!PROBE_OUT!" 2>nul
            )
        )
    )
)

if "%GW%"=="" (
    echo.
    echo Error: Could not detect Host gateway.
    echo   Is the Host machine running 'sudo utmm --host'?
    echo   The Guest must be able to reach the Host at gateway:%PORT%
    echo.
    echo   Manual fallback:
    echo     install.bat --guest --hostname myvm
    echo     Then manually start with: utmm --hostname myvm --gw [gateway IP]
    exit /b 1
)

echo     gateway:  %GW%

:: ─── 4. Construct download URL ───────────────────────────────────────────
set "BIN=utmm-%ARCH%-%OS%.exe"
set "URL=http://%GW%:%PORT%/bin/%BIN%"
echo     binary:   %BIN%
echo     download: %URL%
echo.

:: ─── 5. Create install directory ─────────────────────────────────────────
echo ==^> Creating %INSTALL_DIR% ...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

:: ─── 6. Download binary ──────────────────────────────────────────────────
:: Primary: bitsadmin (Win7+, most compatible — covers all supported editions)
:: Fallback: curl     (Win10 17063+, used if bitsadmin is unavailable/fails)
echo ==^> Downloading %URL% ...
set "TMP_BIN=%TEMP%\utmm-new.exe"

:: Remove stale temp file from previous run
if exist "%TMP_BIN%" del /f "%TMP_BIN%" 2>nul

:: Try bitsadmin first — available on all supported Windows editions (7+)
set "DL_OK=0"
bitsadmin /transfer utmm_dl /download /priority foreground "%URL%" "%TMP_BIN%" >nul 2>&1
if exist "%TMP_BIN%" (
    for %%f in ("%TMP_BIN%") do if %%~zf gtr 0 set "DL_OK=1"
)

:: Fallback to curl if bitsadmin failed (e.g. disabled by policy, or Win10+)
if "!DL_OK!"=="0" (
    echo     bitsadmin unavailable or failed, trying curl...
    if exist "%TMP_BIN%" del /f "%TMP_BIN%" 2>nul
    curl -fSL -m 60 -o "%TMP_BIN%" "%URL%" >nul 2>&1
    if exist "%TMP_BIN%" (
        for %%f in ("%TMP_BIN%") do if %%~zf gtr 0 set "DL_OK=1"
    )
)

if "!DL_OK!"=="0" (
    echo.
    echo Error: Download failed ^(both bitsadmin and curl unavailable or failed^)
    echo   Verify the Host is running: sudo utmm --host
    echo   Verify the binary exists on Host at %BIN%
    echo   Verify network: ping %GW%
    if exist "%TMP_BIN%" del /f "%TMP_BIN%" 2>nul
    exit /b 1
)

for %%f in ("%TMP_BIN%") do echo ==^> Downloaded: %%~zf bytes

:: ─── 7. Stop existing process, replace binary ────────────────────────────
echo ==^> Stopping existing utmm process...
taskkill /f /im utmm.exe >nul 2>&1
timeout /t 2 /nobreak >nul

:: Move new binary to install dir
echo ==^> Installing binary...
move /y "%TMP_BIN%" "%INSTALL_DIR%\utmm.exe" >nul
if %errorlevel% neq 0 (
    echo Error: Failed to move binary to %INSTALL_DIR%\utmm.exe
    exit /b 1
)

:: ─── 8. Install as system service ────────────────────────────────────────
echo ==^> Installing auto-start service...
"%INSTALL_DIR%\utmm.exe" --install --hostname "%HOSTNAME%"
if %errorlevel% neq 0 (
    echo Warning: utmm.exe --install exited with code %errorlevel%
)

timeout /t 1 /nobreak >nul
echo.
echo ==^> Guest installation complete!
echo.
echo ==^> Verify on Host: utmm --host --status
"%INSTALL_DIR%\utmm.exe" --version 2>nul

exit /b 0
