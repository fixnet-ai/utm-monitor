#!/bin/sh
# UTM Monitor — one-click installation script
# Supports both Host and Guest deployment modes
#
# Host mode (default):
#   curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
#   → Downloads utmm.zip from GitHub Releases, extracts to /opt/utmm/, creates symlinks
#
# Guest mode (no internet needed — everything from Host HTTP at gateway IP):
#   curl http://<gateway>:2121/bin/install.sh | sh -s -- --guest --hostname myvm
#   → Auto-detects arch/OS, downloads correct binary from Host HTTP (gateway:2121),
#     creates symlinks, installs service, starts Guest
#
# Environment:
#   INSTALL_DIR   installation directory (default /opt/utmm)
#   HTTP_PORT     Host HTTP port (default 2121)

set -e

REPO="fixnet-ai/utm-monitor"
INSTALL_DIR="${INSTALL_DIR:-/opt/utmm}"
HTTP_PORT="${HTTP_PORT:-2121}"

# ─── Argument routing ───────────────────────────────────────────────

MODE="host"
HOSTNAME_OVERRIDE=""

print_help() {
    echo "Usage: install.sh [--guest [--hostname NAME] [--port PORT]] [--help]"
    echo ""
    echo "  (no args)    Install Host — download utmm.zip from GitHub Releases,"
    echo "               extract all 8 platform binaries to /opt/utmm/, create symlinks"
    echo ""
    echo "  --guest      Install Guest — auto-detect arch/OS, download the correct"
    echo "               binary from Host HTTP at gateway:$HTTP_PORT, install service,"
    echo "               and start the Guest process"
    echo "    --hostname NAME   Guest hostname (e.g., linuxvm, macvm, windowsvm)"
    echo "    --port PORT       Host HTTP port (default 2121)"
    echo ""
    echo "  --help       Show this help"
    exit 0
}

case "${1:-}" in
    --help|-h)
        print_help
        ;;
    --guest)
        MODE="guest"
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
                --port)     HTTP_PORT="$2";        shift 2 ;;
                *)          shift ;;
            esac
        done
        ;;
    "")
        MODE="host"  # default
        ;;
    *)
        echo "Unknown option: $1"
        echo "Usage: install.sh [--guest [--hostname NAME]] [--help]"
        exit 1
        ;;
esac

# ─── Host mode ──────────────────────────────────────────────────────

if [ "$MODE" = "host" ]; then
    ZIP_URL="https://github.com/$REPO/releases/latest/download/utmm.zip"

    echo "==> UTM Monitor installer (Host)"
    echo "    install:  $INSTALL_DIR"
    echo ""

    # Download zip
    TMP_ZIP="$(mktemp "/tmp/utmm.XXXXXX.zip")"
    echo "==> Downloading $ZIP_URL ..."
    if ! curl -fsSL --progress-bar "$ZIP_URL" -o "$TMP_ZIP"; then
        echo ""
        echo "==> Download failed. Build from source:"
        echo "      git clone https://github.com/$REPO.git"
        echo "      cd utm-monitor"
        echo "      zig build -Doptimize=ReleaseSafe"
        rm -f "$TMP_ZIP"
        exit 1
    fi

    # Extract
    echo "==> Extracting to $INSTALL_DIR ..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo unzip -o "$TMP_ZIP" -d "$INSTALL_DIR"
    rm -f "$TMP_ZIP"
    sudo chmod +x "$INSTALL_DIR"/utmm-* 2>/dev/null || true

    # Detect Host architecture (normalize uname -m -> our arch names)
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        arm64|aarch64) HOST_ARCH="aarch64" ;;
        x86_64|amd64)  HOST_ARCH="x86_64" ;;
        i386|i486|i586|i686) HOST_ARCH="x86" ;;
        *) echo "Error: unsupported architecture: $HOST_ARCH"; exit 1 ;;
    esac

    HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$HOST_OS" in
        darwin) HOST_OS="macos" ;;
        linux)  HOST_OS="linux" ;;
        mingw*|msys*|cygwin*) HOST_OS="windows" ;;
        *) echo "Error: unsupported OS: $HOST_OS"; exit 1 ;;
    esac

    HOST_BIN="utmm-${HOST_ARCH}-${HOST_OS}"
    if [ "$HOST_OS" = "windows" ]; then
        HOST_BIN="${HOST_BIN}.exe"
    fi

    # Create symlink: /opt/utmm/utmm -> utmm-{arch}-{os}
    echo "==> Creating symlink: $INSTALL_DIR/utmm -> $INSTALL_DIR/$HOST_BIN"
    sudo ln -sf "$INSTALL_DIR/$HOST_BIN" "$INSTALL_DIR/utmm"
    if [ "$HOST_OS" = "windows" ]; then
        sudo ln -sf "$INSTALL_DIR/$HOST_BIN" "$INSTALL_DIR/utmm.exe"
    fi

    # Convenience symlink to /usr/local/bin (macOS/Linux only)
    if [ "$HOST_OS" != "windows" ]; then
        sudo mkdir -p /usr/local/bin
        sudo ln -sf "$INSTALL_DIR/utmm" /usr/local/bin/utmm
        echo "==> Symlink: /usr/local/bin/utmm -> $INSTALL_DIR/utmm"
    fi

    echo ""
    echo "==> Host installation complete!"
    "$INSTALL_DIR/utmm" --version 2>/dev/null || true
    echo ""
    echo "==> To enable auto-start on boot:"
    echo "    sudo utmm --host --install"
    echo ""
    echo "==> To start Host now:"
    echo "    sudo utmm --host"

    exit 0
fi

# ─── Guest mode ─────────────────────────────────────────────────────

echo "==> UTM Monitor installer (Guest)"
echo "    install:  $INSTALL_DIR"
echo ""

# 1. Detect CPU architecture
GUEST_ARCH="$(uname -m)"
case "$GUEST_ARCH" in
    arm64|aarch64) GUEST_ARCH="aarch64" ;;
    x86_64|amd64)  GUEST_ARCH="x86_64" ;;
    i386|i486|i586|i686) GUEST_ARCH="x86" ;;
    *)
        echo "Error: unsupported architecture: $GUEST_ARCH"
        echo "Supported: aarch64 (ARM 64-bit), x86_64 (Intel/AMD 64-bit), x86 (32-bit)"
        exit 1
        ;;
esac
echo "    arch:     $GUEST_ARCH"

# 2. Detect OS
GUEST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$GUEST_OS" in
    darwin) GUEST_OS="macos" ;;
    linux)  GUEST_OS="linux" ;;
    mingw*|msys*|cygwin*) GUEST_OS="windows" ;;
    *)
        echo "Error: unsupported OS: $GUEST_OS"
        echo "Supported: linux, macos"
        exit 1
        ;;
esac
echo "    os:       $GUEST_OS"

# 3. Find default gateway (Host's bridge IP where HTTP server runs)
echo "    detecting gateway..."

GATEWAY=""

# Linux: ip route
if [ "$GUEST_OS" = "linux" ]; then
    GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    if [ -z "$GATEWAY" ] && [ -f /proc/net/route ]; then
        GATEWAY=$(awk '$2 == "00000000" {
            printf "%d.%d.%d.%d",
            strtonum("0x"substr($3,7,2)),
            strtonum("0x"substr($3,5,2)),
            strtonum("0x"substr($3,3,2)),
            strtonum("0x"substr($3,1,2))
        }' /proc/net/route 2>/dev/null)
    fi
fi

# macOS: route -n get default
if [ "$GUEST_OS" = "macos" ]; then
    GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
fi

# Fallback: probe known UTM bridge IPs
if [ -z "$GATEWAY" ]; then
    for gw in 192.168.64.1 192.168.65.1 192.168.66.1 192.168.67.1; do
        if curl -fsSL --connect-timeout 2 "http://$gw:$HTTP_PORT/version" >/dev/null 2>&1; then
            GATEWAY="$gw"
            break
        fi
    done
fi

if [ -z "$GATEWAY" ]; then
    echo ""
    echo "Error: Could not detect Host gateway."
    echo "  Is the Host machine running 'sudo utmm --host'?"
    echo "  The Guest must be able to reach the Host at gateway:$HTTP_PORT"
    echo ""
    echo "  Manual fallback — specify the Host IP directly:"
    echo "    GATEWAY=<host-ip> curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --guest --hostname myvm"
    exit 1
fi

echo "    gateway:  $GATEWAY"

# 4. Construct binary name and download URL
GUEST_BIN="utmm-${GUEST_ARCH}-${GUEST_OS}"
DOWNLOAD_URL="http://${GATEWAY}:${HTTP_PORT}/bin/${GUEST_BIN}"

echo "    binary:   $GUEST_BIN"
echo "    download: $DOWNLOAD_URL"
echo ""

# 5. Create install directory
echo "==> Creating $INSTALL_DIR ..."
sudo mkdir -p "$INSTALL_DIR"

# 6. Download binary
echo "==> Downloading $DOWNLOAD_URL ..."
TMP_BIN="$(mktemp "/tmp/utmm.XXXXXX")"
trap 'rm -f "$TMP_BIN"' EXIT

if curl -fsSL --connect-timeout 10 --max-time 60 "$DOWNLOAD_URL" -o "$TMP_BIN"; then
    :
elif command -v wget >/dev/null 2>&1; then
    if ! wget -q --timeout=10 "$DOWNLOAD_URL" -O "$TMP_BIN"; then
        echo ""
        echo "Error: Download failed (wget returned error)."
        echo "  Verify the Host is running: sudo utmm --host"
        echo "  Verify the binary exists on Host: ls $INSTALL_DIR/$GUEST_BIN"
        exit 1
    fi
else
    echo "Error: No curl or wget available for download."
    exit 1
fi

# 7. Install binary (keep it with the deployment name, create utmm symlink)
echo "==> Installing binary..."
sudo mv "$TMP_BIN" "$INSTALL_DIR/$GUEST_BIN"
sudo chmod +x "$INSTALL_DIR/$GUEST_BIN"

# 8. Create symlinks
echo "==> Creating symlink: $INSTALL_DIR/utmm -> $INSTALL_DIR/$GUEST_BIN"
sudo ln -sf "$INSTALL_DIR/$GUEST_BIN" "$INSTALL_DIR/utmm"

# Convenience symlink (Unix only)
sudo mkdir -p /usr/local/bin
sudo ln -sf "$INSTALL_DIR/utmm" /usr/local/bin/utmm
echo "==> Symlink: /usr/local/bin/utmm -> $INSTALL_DIR/utmm"

# 9. Install as system service (auto-start on boot)
#    --install also starts the service immediately, so no separate start needed
echo "==> Installing auto-start service..."
if [ -n "$HOSTNAME_OVERRIDE" ]; then
    if ! sudo "$INSTALL_DIR/utmm" --install --hostname "$HOSTNAME_OVERRIDE"; then
        echo "Warning: Service installation failed. Trying manual start..."
        sudo nohup "$INSTALL_DIR/utmm" --hostname "$HOSTNAME_OVERRIDE" > /var/log/utmm.log 2>&1 &
        echo "    hostname: $HOSTNAME_OVERRIDE (manual)"
    fi
else
    if ! sudo "$INSTALL_DIR/utmm" --install; then
        echo "Warning: Service installation failed. Trying manual start..."
        sudo nohup "$INSTALL_DIR/utmm" > /var/log/utmm.log 2>&1 &
        echo "    (using OS hostname, manual)"
    fi
fi

echo ""
echo "==> Guest installation complete!"
sleep 1
"$INSTALL_DIR/utmm" --version 2>/dev/null || true
echo ""
echo "==> Verify on Host: utmm --host --status"
