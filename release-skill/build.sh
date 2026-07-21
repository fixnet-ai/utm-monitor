#!/bin/bash
# Release helper — build all 7 targets and create utmm.zip
# Called by the release skill, or run standalone:
#   ./release-skill/build.sh

set -e
cd "$(dirname "$0")/.."

echo "==> Running tests..."
zig build test --summary all

echo ""
echo "==> Building all 7 targets..."
rm -rf release && mkdir -p release

build_target() {
    local target=$1 bin=$2
    echo "  $target → $bin"
    zig build -Dtarget=$target -Doptimize=ReleaseSafe
    cp "zig-out/bin/$bin" "release/"
    printf "    %s  %s\n" "$(wc -c < release/$bin | tr -d ' ')" "$bin"
}

build_target x86_64-windows       utmm-x86_64-windows.exe
build_target aarch64-windows      utmm-aarch64-windows.exe
build_target x86_64-macos         utmm-x86_64-macos
build_target aarch64-macos        utmm-aarch64-macos
build_target x86-linux-musl       utmm-x86-linux
build_target x86_64-linux-musl    utmm-x86_64-linux
build_target aarch64-linux-musl   utmm-aarch64-linux

echo ""
echo "==> Copying install scripts..."
cp install.sh release/
cp install.bat release/

echo ""
echo "==> Creating utmm.zip..."
rm -f utmm.zip
cd release && zip "../utmm.zip" * && cd ..
ls -lh utmm.zip

echo ""
echo "==> Done. utmm.zip ready."
