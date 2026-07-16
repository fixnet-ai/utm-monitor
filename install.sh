#!/bin/sh
# UTM Monitor — one-click installation script
# Downloads utmm.zip from GitHub Releases, extracts to /opt/utmm/
# Creates /opt/utmm/utmm -> utmm-{arch}-{os}[.exe] symlink for the Host
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
#   VERSION=v1.0.0 curl -fsSL ... | sh
#
# Environment:
#   INSTALL_DIR   installation directory (default /opt/utmm)
#   VERSION       specific version tag, or "latest" (default)

set -e

REPO="fixnet-ai/utm-monitor"
INSTALL_DIR="${INSTALL_DIR:-/opt/utmm}"
VERSION="${VERSION:-latest}"

# Build download URL
if [ "$VERSION" = "latest" ]; then
    ZIP_URL="https://github.com/$REPO/releases/latest/download/utmm.zip"
else
    ZIP_URL="https://github.com/$REPO/releases/download/$VERSION/utmm.zip"
fi

echo "==> UTM Monitor installer"
echo "    install:  $INSTALL_DIR"
echo "    version:  $VERSION"
echo ""

# Download zip
TMP_ZIP="$(mktemp /tmp/utmm.XXXXXX.zip)"
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
echo "==> Installation complete!"
"$INSTALL_DIR/utmm" --version 2>/dev/null || true
echo ""
echo "==> To enable auto-start on boot:"
echo "    sudo utmm --host --install"
echo ""
echo "==> To start Host now:"
echo "    sudo utmm --host"
