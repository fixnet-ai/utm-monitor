@echo off
setlocal enabledelayedexpansion

:: ═══════════════════════════════════════════════════════════════════════
:: UTM Monitor — Windows Guest installer (batch)
:: Downloads the correct binary from Host HTTP, installs service, starts Guest
::
:: Usage (as Administrator):
::   curl -fsSL http://<gateway>:2121/bin/install.bat -o install.bat && install.bat --guest --hostname windowsvm
::
::   Or local:
::   install.bat --guest --hostname windowsvm
::
:: Parameters:
::   --guest           Guest mode (required)
::   --hostname NAME   Guest hostname (required in guest mode)
::   --port PORT       HTTP port (default: 2121)
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
    echo   curl -fsSL http://[gateway]:2121/bin/install.bat -o install.bat ^&^& install.bat --guest --hostname windowsvm
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

:: Method 2: Fallback — probe known UTM bridge IPs
if "%GW%"=="" (
    set "FALLBACKS=192.168.64.1 192.168.65.1 192.168.66.1 192.168.67.1"
    for %%i in (!FALLBACKS!) do (
        if "!GW!"=="" (
            curl -s -m 2 "http://%%i:%PORT%/version" >nul 2>&1
            if !errorlevel! equ 0 set "GW=%%i"
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
echo ==^> Downloading %URL% ...
set "TMP_BIN=%TEMP%\utmm-new.exe"
curl -fSL --progress-bar -m 60 -o "%TMP_BIN%" "%URL%"
if %errorlevel% neq 0 (
    echo.
    echo Error: Download failed ^(curl exit code %errorlevel%^)
    echo   Verify the Host is running: sudo utmm --host
    echo   Verify the binary exists on Host at %BIN%
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
