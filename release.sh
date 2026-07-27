#!/bin/bash
# Release helper — build all 8 targets, create utmm.zip, publish GitHub release.
# Prerequisites: gh CLI authenticated, Zig 0.16.0, clean working tree.
#
# Usage:
#   ./release.sh v0.11.11 "Release notes (markdown)"
#
# The version must match the tag already pushed (git tag + git push --tags
# should be done before running this script).

set -e
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version> [notes]"
    echo "Example: ./release.sh v0.11.11 \"Bug fixes and performance improvements\""
    exit 1
fi

echo "==> Running tests..."
zig build test --summary all

echo ""
echo "==> Building all 8 targets..."
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
build_target x86-windows-gnu      utmm-x86-windows.exe
build_target x86_64-macos         utmm-x86_64-macos
build_target aarch64-macos        utmm-aarch64-macos
build_target x86-linux-musl       utmm-x86-linux
build_target x86_64-linux-musl    utmm-x86_64-linux
build_target aarch64-linux-musl   utmm-aarch64-linux

echo ""
echo "==> Adding install scripts..."
cp install.sh install.bat release/
echo "  install.sh → release/"
echo "  install.bat → release/"

echo ""
echo "==> Creating utmm.zip..."
rm -f utmm.zip
cd release && zip "../utmm.zip" * && cd ..
ls -lh utmm.zip

echo ""
echo "==> Creating GitHub release $VERSION..."
if [ -n "$NOTES" ]; then
    gh release create "$VERSION" \
        --title "$VERSION" \
        --notes "$NOTES" \
        utmm.zip
else
    gh release create "$VERSION" \
        --title "$VERSION" \
        utmm.zip
fi

echo ""
echo "==> Release $VERSION published."

# Rebuild native target so zig-out/bin/utmm is usable for local testing
echo ""
echo "==> Rebuilding native target for local use..."
zig build -Doptimize=ReleaseSafe
echo "  zig-out/bin/utmm restored to native arch"
