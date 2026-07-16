#!/bin/sh
# UTM Monitor — one-click installation script
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sh
#   curl -fsSL ... | sh -s -- --with-guests /opt/utm-monitor
#
# Options:
#   --with-guests DIR    Also download all Guest binaries into DIR (for Host /update endpoint)
#
# Specify a version:
#   VERSION=v1.1.1 curl -fsSL https://raw.githubusercontent.com/.../install.sh | sh

set -e

REPO="fixnet-ai/utm-monitor"
BIN="/usr/local/bin/utm-monitor"
VERSION="${VERSION:-latest}"
WITH_GUESTS=""
GUEST_DIR=""

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --with-guests)
            WITH_GUESTS=1
            GUEST_DIR="${2:-/opt/utm-monitor}"
            shift 2 2>/dev/null || shift
            ;;
        *) shift ;;
    esac
done

# Detect architecture (Host runs on macOS only for now)
ARCH=$(uname -m)
case "$ARCH" in
    arm64)  TARGET="aarch64-macos" ;;
    x86_64) TARGET="x86_64-macos" ;;
    *)      echo "Error: unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "==> UTM Monitor installer"
echo "    arch:     $ARCH ($TARGET)"
echo "    version:  $VERSION"
echo "    dest:     $BIN"
if [ -n "$WITH_GUESTS" ]; then
    echo "    guests:   $GUEST_DIR"
fi
echo ""

# Build download URL
if [ "$VERSION" = "latest" ]; then
    BASE_URL="https://github.com/$REPO/releases/latest/download"
else
    BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
fi

# Download Host binary
URL="$BASE_URL/utm-monitor-$TARGET"
echo "==> Downloading $URL ..."
if sudo curl -fsSL --progress-bar "$URL" -o "$BIN"; then
    sudo chmod +x "$BIN"
    echo ""
    echo "==> Installed: $BIN"
    "$BIN" --version
else
    echo ""
    echo "==> Download failed — no GitHub Release found for $VERSION."
    echo "    Build from source instead:"
    echo "      git clone https://github.com/$REPO.git"
    echo "      cd utm-monitor"
    echo "      zig build -Doptimize=ReleaseSafe"
    echo "      sudo cp zig-out/bin/utm-monitor $BIN"
    exit 1
fi

# Optionally download Guest binaries for /update auto-deploy
if [ -n "$WITH_GUESTS" ]; then
    sudo mkdir -p "$GUEST_DIR"
    GUEST_TARGETS="aarch64-linux x86_64-linux aarch64-macos x86_64-macos aarch64-windows x86_64-windows"
    echo ""
    echo "==> Downloading Guest binaries to $GUEST_DIR ..."
    for t in $GUEST_TARGETS; do
        ext=""
        case "$t" in
            *windows*) ext=".exe" ;;
        esac
        gurl="$BASE_URL/utm-monitor-$t$ext"
        gdest="$GUEST_DIR/utm-monitor-$t$ext"
        echo "    $gurl"
        if sudo curl -fsSL --progress-bar "$gurl" -o "$gdest"; then
            sudo chmod +x "$gdest"
        else
            echo "    WARNING: failed to download $t (may not exist for this release)"
        fi
    done
    echo "==> Guest binaries ready, Host can serve /update from: $GUEST_DIR"
fi

echo ""
echo "==> To enable auto-start on boot:"
echo "    sudo utm-monitor --install"
echo ""
echo "==> To start Host now:"
if [ -n "$WITH_GUESTS" ]; then
    echo "    sudo utm-monitor --host --serve-dir $GUEST_DIR"
else
    echo "    sudo utm-monitor --host"
fi
