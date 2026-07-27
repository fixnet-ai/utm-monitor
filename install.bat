@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: UTM Monitor — Windows Install/Upgrade Script
:: https://github.com/fixnet-ai/utm-monitor
::
:: Usage: Run this script in an Administrator terminal.
::   curl -fsSLo %TEMP%\install.bat https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.bat && %TEMP%\install.bat
::
:: Offline install:
::   1. Download utmm.zip from https://github.com/fixnet-ai/utm-monitor/releases/latest
::   2. Extract utmm.zip to C:\opt\utmm\
::   3. Run C:\opt\utmm\install.bat as Administrator
::
:: Manual install (no script):
::   1. Download the correct .exe for your platform from the latest release
::   2. mkdir C:\opt\utmm && copy <binary>.exe C:\opt\utmm\utmm.exe
::   3. C:\opt\utmm\utmm.exe --host --install                  (Host)
::      C:\opt\utmm\utmm.exe --install --hostname mybox        (Guest)
:: =============================================================================

set "CANONICAL_DIR=C:\opt\utmm"
set "BINARY_NAME=utmm.exe"
set "DOWNLOAD_URL=https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.zip"
set "VERSION=0.11.16"

:: ── admin check ─────────────────────────────────────────────────────────────

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Administrator privileges required.
    echo Right-click on Command Prompt ^(or this .bat file^) and select "Run as Administrator".
    pause
    exit /b 1
)

:: ── banner ───────────────────────────────────────────────────────────────────

echo.
echo ========================================
echo   utmm v%VERSION%  Install / Upgrade
echo   https://github.com/fixnet-ai/utm-monitor
echo ========================================
echo.

:: ── architecture detection ───────────────────────────────────────────────────

:: On 64-bit Windows, PROCESSOR_ARCHITECTURE may be "x86" when running
:: inside a 32-bit cmd.exe (WoW64). Check PROCESSOR_ARCHITEW6432 first.
set "ARCH=%PROCESSOR_ARCHITEW6432%"
if "%ARCH%"=="" set "ARCH=%PROCESSOR_ARCHITECTURE%"

if /i "%ARCH%"=="AMD64" (
    set "PLATFORM_ARCH=x86_64"
    set "ZIP_BINARY=utmm-x86_64-windows.exe"
) else if /i "%ARCH%"=="ARM64" (
    set "PLATFORM_ARCH=aarch64"
    set "ZIP_BINARY=utmm-aarch64-windows.exe"
) else if /i "%ARCH%"=="x86" (
    set "PLATFORM_ARCH=x86"
    set "ZIP_BINARY=utmm-x86-windows.exe"
) else (
    echo ERROR: Unsupported architecture: %ARCH%
    echo Supported: AMD64, ARM64, x86
    pause
    exit /b 2
)

echo Detected: windows / %PLATFORM_ARCH%  -^>  %ZIP_BINARY%
echo.

:: ── interaction: hostname ────────────────────────────────────────────────────

:: Default hostname = COMPUTERNAME (always available on Windows)
set "DEFAULT_HOSTNAME=%COMPUTERNAME%"

:ask_hostname
set "HOSTNAME_INPUT="
set /p "HOSTNAME_INPUT=Hostname [%DEFAULT_HOSTNAME%]: "
if "!HOSTNAME_INPUT!"=="" set "HOSTNAME_INPUT=%DEFAULT_HOSTNAME%"

:: Validate: 1-63 chars, starts with letter/digit
set "HOSTNAME_TMP=!HOSTNAME_INPUT!"
:: Check length (rough: variable length)
call :strlen "!HOSTNAME_TMP!" HOSTNAME_LEN
if !HOSTNAME_LEN! lss 1 goto :bad_hostname
if !HOSTNAME_LEN! gtr 63 goto :bad_hostname

:: Check first char is alphanumeric
set "FIRST_CHAR=!HOSTNAME_TMP:~0,1!"
call :is_alnum !FIRST_CHAR! || goto :bad_hostname

:: Check all chars are valid
for /L %%i in (0,1,62) do (
    if %%i lss !HOSTNAME_LEN! (
        set "C=!HOSTNAME_TMP:~%%i,1!"
        if "!C!"=="" goto :hostname_ok
        call :is_valid_char !C! || goto :bad_hostname
    )
)

:hostname_ok
set "HOSTNAME=!HOSTNAME_TMP!"
goto :ask_mode

:bad_hostname
echo ERROR: Invalid hostname. Use 1-63 chars: a-z, A-Z, 0-9, -, _.
echo        Must start with letter or digit.
goto :ask_hostname

:: ── interaction: mode ────────────────────────────────────────────────────────

:ask_mode
set "MODE_INPUT="
set /p "MODE_INPUT=Mode - [H]ost or [G]uest? [G]: "
if "!MODE_INPUT!"=="" set "MODE_INPUT=G"

if /i "!MODE_INPUT!"=="H" (
    set "MODE=host"
    set "MODE_FLAG=--host"
    goto :ask_hostip_done
)
if /i "!MODE_INPUT!"=="G" (
    set "MODE=guest"
    set "MODE_FLAG="
    goto :ask_hostip
)
echo Please enter H (Host) or G (Guest).
goto :ask_mode

:: ── interaction: host-ip (Guest only) ────────────────────────────────────────

:ask_hostip
set "HOST_IP_INPUT="
set /p "HOST_IP_INPUT=Host IP (blank = auto-detect via default gateway): "
if not "!HOST_IP_INPUT!"=="" (
    set "HOST_IP_ARG=--host-ip !HOST_IP_INPUT!"
) else (
    set "HOST_IP_ARG="
)

:ask_hostip_done
echo.
echo Summary:
echo   Mode:     !MODE!
echo   Hostname: !HOSTNAME!
if not "!HOST_IP_ARG!"=="" echo   Host IP:  !HOST_IP_INPUT!
if "!HOST_IP_ARG!"=="" if "!MODE!"=="guest" echo   Host IP:  (auto-detect)

:: ── create canonical dir ────────────────────────────────────────────────────

if not exist "!CANONICAL_DIR!" mkdir "!CANONICAL_DIR!"

:: ── check if already extracted (offline mode) ────────────────────────────────

if exist "!CANONICAL_DIR!\!ZIP_BINARY!" (
    echo.
    echo [offline] !ZIP_BINARY! found in !CANONICAL_DIR! - skipping download.
    goto :extract_done
)

:: ── download ─────────────────────────────────────────────────────────────────

set "ZIP_PATH=%TEMP%\utmm_%RANDOM%.zip"
echo.
echo Downloading utmm.zip ...

:: Try PowerShell (Invoke-WebRequest) first - most reliable on all Windows versions
where powershell >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DOWNLOAD_URL%' -OutFile '%ZIP_PATH%' -UseBasicParsing" 2>nul
    if exist "%ZIP_PATH%" goto :download_ok
)

:: Fallback 1: curl (Win10 1803+)
where curl >nul 2>&1
if %errorlevel% equ 0 (
    curl -fsSL --connect-timeout 30 --max-time 120 -o "%ZIP_PATH%" "%DOWNLOAD_URL%" 2>nul
    if exist "%ZIP_PATH%" goto :download_ok
)

:: Fallback 2: certutil (Win7+)
where certutil >nul 2>&1
if %errorlevel% equ 0 (
    certutil -urlcache -split -f "%DOWNLOAD_URL%" "%ZIP_PATH%" >nul 2>&1
    if exist "%ZIP_PATH%" goto :download_ok
)

:: Fallback 3: bitsadmin (Win7+)
where bitsadmin >nul 2>&1
if %errorlevel% equ 0 (
    bitsadmin /transfer "utmm_dl" "%DOWNLOAD_URL%" "%ZIP_PATH%" >nul 2>&1
    if exist "%ZIP_PATH%" goto :download_ok
)

echo ERROR: Download failed. No download tool available.
echo Install curl, or download utmm.zip manually from:
echo   %DOWNLOAD_URL%
echo Then extract to %CANONICAL_DIR%\ and re-run this script.
pause
exit /b 3

:download_ok
echo Download OK

:: ── extract ──────────────────────────────────────────────────────────────────

echo Extracting to %CANONICAL_DIR%\ ...

:: Try PowerShell Expand-Archive first (most reliable, all Windows versions)
where powershell >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -Command "Expand-Archive -Path '%ZIP_PATH%' -DestinationPath '%CANONICAL_DIR%' -Force" 2>nul
    if exist "!CANONICAL_DIR!\!ZIP_BINARY!" goto :extract_ok
)

:: Try tar (Win10 1803+)
where tar >nul 2>&1
if %errorlevel% equ 0 (
    tar -xf "%ZIP_PATH%" -C "%CANONICAL_DIR%" >nul 2>&1
    if exist "!CANONICAL_DIR!\!ZIP_BINARY!" goto :extract_ok
)

:: Fallback: COM Shell.Application (Win7/8 without PowerShell)
echo Using COM shell for extraction ...
set "VBS_PATH=%TEMP%\utmm_unzip.vbs"
echo Set sa = CreateObject("Shell.Application")> "%VBS_PATH%"
echo Set zip = sa.NameSpace("%ZIP_PATH%")>> "%VBS_PATH%"
echo Set dest = sa.NameSpace("%CANONICAL_DIR%")>> "%VBS_PATH%"
echo dest.CopyHere zip.Items(), 16>> "%VBS_PATH%"
cscript //nologo "%VBS_PATH%" >nul 2>&1
del "%VBS_PATH%" 2>nul
if exist "!CANONICAL_DIR!\!ZIP_BINARY!" goto :extract_ok

echo ERROR: Extract failed.
echo Zip contents in %CANONICAL_DIR%\:
dir /b "%CANONICAL_DIR%"
echo.
echo Expected binary: %ZIP_BINARY% not found.
echo The zip may be corrupted; try re-downloading.
del "%ZIP_PATH%" 2>nul
pause
exit /b 4

:extract_ok
echo Extract OK

:: Clean up zip
del "%ZIP_PATH%" 2>nul

:extract_done

:: ── file placement ───────────────────────────────────────────────────────────

echo Preparing files ...

cd /d "%CANONICAL_DIR%"

:: Always ensure the target binary is named utmm.exe
copy /y "%ZIP_BINARY%" "%BINARY_NAME%" >nul

if /i "%MODE%"=="guest" (
    :: Guest: only keep the current-platform binary
    echo   Guest mode - removing other platform binaries ...
    for %%f in (utmm-* utmm*.exe) do (
        if /i not "%%f"=="%ZIP_BINARY%" del /q "%%f" 2>nul
    )
    :: Also remove install scripts from Guest
    del /q install.sh install.bat 2>nul
    echo   Kept: %ZIP_BINARY% (as utmm.exe)
) else (
    :: Host: keep all platform binaries for Guest auto-upgrade
    echo   Host mode - keeping all platform binaries for Guest auto-upgrade:
    for %%f in (utmm-* utmm*.exe) do (
        if exist "%%f" echo     %%f
    )
)

:: ── install ──────────────────────────────────────────────────────────────────

echo.
echo Installing as %MODE% ...

set "INSTALL_ARGS=--install --hostname %HOSTNAME% %MODE_FLAG% %HOST_IP_ARG%"

"%CANONICAL_DIR%\%BINARY_NAME%" %INSTALL_ARGS%
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Installation failed (exit code %errorlevel%).
    echo Check service logs: type C:\opt\utmm\utmm-%MODE%-err.log
    pause
    exit /b %errorlevel%
)

echo.
echo Done.
if /i "%MODE%"=="host" (
    echo   Host service is running on UDP :2121
    echo   Check: %CANONICAL_DIR%\%BINARY_NAME% --status
) else (
    echo   Guest service is running - auto-starts on boot.
    echo   Check: run 'utmm --status' on the Host machine.
)
goto :eof

:: ── subroutines ──────────────────────────────────────────────────────────────

:strlen  str  result
    set "s=%~1"
    set "len=0"
    for /l %%a in (12,-1,0) do (
        set /a "len|=1<<%%a"
        for %%b in (!len!) do if "!s:~%%b,1!"=="" set /a "len&=~1<<%%a"
    )
    set "%~2=!len!"
    goto :eof

:is_alnum  char
    set "ch=%~1"
    if "%ch%" geq "a" if "%ch%" leq "z" exit /b 0
    if "%ch%" geq "A" if "%ch%" leq "Z" exit /b 0
    if "%ch%" geq "0" if "%ch%" leq "9" exit /b 0
    exit /b 1

:is_valid_char  char
    set "ch=%~1"
    if "%ch%" geq "a" if "%ch%" leq "z" exit /b 0
    if "%ch%" geq "A" if "%ch%" leq "Z" exit /b 0
    if "%ch%" geq "0" if "%ch%" leq "9" exit /b 0
    if "%ch%"=="-" exit /b 0
    if "%ch%"=="_" exit /b 0
    exit /b 1
