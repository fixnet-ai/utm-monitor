#!/bin/bash
# ==============================================================================
# UTM Monitor — Release Script
# https://github.com/fixnet-ai/utm-monitor
#
# 先构建 + 测试全部通过，再 commit/tag/push/publish。
# 避免了先 tag 后构建失败导致 tag 反复删除重建的问题。
#
# Usage:
#   ./release.sh v0.15.10 "Release notes (markdown)"
#
# Pre-condition: src/ver.txt must already be bumped to the target version.
# The script auto-commits + tags + pushes if everything passes.
# ==============================================================================

set -e
cd "$(dirname "$0")"

# ═══════════════════════════════════════════════════════════════════════════════
# Environment dependencies
# ═══════════════════════════════════════════════════════════════════════════════

REQUIRED_ZIG="0.16.0"

check_deps() {
    local missing=0

    # Zig ≥ 0.16.0
    if ! command -v zig >/dev/null 2>&1; then
        echo "ERROR: zig not found in PATH. Install Zig ${REQUIRED_ZIG}."
        missing=1
    else
        local zig_ver
        zig_ver=$(zig version 2>/dev/null | head -1)
        echo "[OK] zig ${zig_ver}"
    fi

    # gh CLI (authenticated)
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found. Install: brew install gh (macOS) / apt install gh (Linux)"
        missing=1
    elif ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: gh not authenticated. Run: gh auth login"
        missing=1
    else
        echo "[OK] gh CLI authenticated"
    fi

    # zip
    if ! command -v zip >/dev/null 2>&1; then
        echo "ERROR: zip not found. Install: brew install zip (macOS) / apt install zip (Linux)"
        missing=1
    else
        echo "[OK] zip available"
    fi

    if [ $missing -ne 0 ]; then
        echo ""
        echo "Fix the issues above and re-run."
        exit 1
    fi
}

check_deps
echo ""

VERSION="${1:-}"
NOTES="${2:-}"
MODE="${3:-}"

print_help() {
    echo "Usage: ./release.sh <version> <notes> <--utmmd|--no-utmmd>"
    echo ""
    echo "Example: ./release.sh v0.18.77 \"Fix X\" --no-utmmd"
    echo ""
    echo "utmmd rebuild mode (REQUIRED — pick one):"
    echo ""
    echo "  --utmmd      Rebuild utmmd for all 8 targets and re-embed into utmm."
    echo "               REQUIRED when supervisor sources changed since utmmd was"
    echo "               last built: src/utmmd.zig, src/shm.zig, src/svc.zig."
    echo "               Deploy will then update utmmd on every node (the complex"
    echo "               path: service stop → kill → replace → restart)."
    echo ""
    echo "  --no-utmmd   Reuse the existing src/embed/*/utmmd.bin unchanged."
    echo "               Embedded utmmd hash stays identical → shouldUpdateUtmmd()"
    echo "               returns false on every node → deploy SKIPS the utmmd"
    echo "               update entirely. Preferred when only utmm sources changed."
    echo "               Fails if supervisor sources changed since the last"
    echo "               --utmmd build (src/embed/UTMMD-BUILT-FROM), or embed"
    echo "               binaries are missing (fresh clone → use --utmmd)."
    echo ""
    echo "How to decide (AI agents):"
    echo "  PROV=\$(cat src/embed/UTMMD-BUILT-FROM 2>/dev/null)"
    echo "  git diff --name-only \$PROV HEAD -- src/utmmd.zig src/shm.zig src/svc.zig"
    echo "  → empty output → --no-utmmd   (preferred; avoids fleet-wide supervisor update)"
    echo "  → any files   → --utmmd       (mandatory; stale supervisor would ship otherwise)"
    echo ""
    echo "Pre-condition: src/ver.txt must already be bumped to the target version."
}

if [ -z "$VERSION" ] || { [ "$MODE" != "--utmmd" ] && [ "$MODE" != "--no-utmmd" ]; }; then
    print_help
    exit 1
fi
UTMMD_FLAG=$([ "$MODE" = "--utmmd" ] && echo true || echo false)

# ── Verify ver.txt matches VERSION arg ──
EXPECTED_VER="${VERSION#v}"  # strip leading 'v' if present
ACTUAL_VER=$(cat src/ver.txt | tr -d '\n')
if [ "$EXPECTED_VER" != "$ACTUAL_VER" ]; then
    echo "ERROR: src/ver.txt contains '$ACTUAL_VER' but release version is '$VERSION'"
    echo "Bump src/ver.txt to $EXPECTED_VER first, then re-run."
    exit 1
fi
echo "[OK] src/ver.txt = $ACTUAL_VER"

# ── Verify working tree is clean (or only ver.txt changed) ──
if [ -n "$(git status --porcelain | grep -v 'src/ver.txt')" ]; then
    echo ""
    echo "ERROR: Working tree has uncommitted changes (beyond src/ver.txt):"
    git status --short | grep -v 'src/ver.txt'
    echo ""
    echo "Commit or stash these changes before releasing."
    exit 1
fi
echo "[OK] Working tree clean"

# ── utmmd mode guards ──
SUPERVISOR_SOURCES="src/utmmd.zig src/shm.zig src/svc.zig"
PROVENANCE="src/embed/UTMMD-BUILT-FROM"

if [ "$MODE" = "--no-utmmd" ]; then
    # Guard 1: embed binaries must exist (fresh clone has none)
    MISSING_EMBED=0
    for d in src/embed/*/; do
        if [ ! -f "$d/utmmd.bin" ]; then
            echo "ERROR: $d/utmmd.bin missing — fresh checkout needs a full --utmmd build."
            MISSING_EMBED=1
        fi
    done
    [ "$MISSING_EMBED" -ne 0 ] && exit 1

    # Guard 2: supervisor sources must be unchanged since last --utmmd build
    if [ ! -f "$PROVENANCE" ]; then
        echo "ERROR: $PROVENANCE missing — utmmd provenance unknown. Run once with --utmmd."
        exit 1
    fi
    PROV=$(cat "$PROVENANCE")
    if ! git rev-parse --verify "$PROV" >/dev/null 2>&1; then
        echo "ERROR: provenance commit $PROV not found in this repo. Run with --utmmd."
        exit 1
    fi
    DRIFTED=$(git diff --name-only "$PROV" HEAD -- $SUPERVISOR_SOURCES)
    if [ -n "$DRIFTED" ]; then
        echo "ERROR: supervisor sources changed since utmmd was last built ($PROV):"
        echo "$DRIFTED" | sed 's/^/  /'
        echo "Re-run with --utmmd — shipping a stale embedded supervisor is not allowed."
        exit 1
    fi
    echo "[OK] utmmd unchanged since $PROV — reusing existing embedded binaries"
else
    echo "[MODE] utmmd will be rebuilt + re-embedded (deploy updates supervisor fleet-wide)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: Tests
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "==> Phase 1: Running unit tests..."
zig build test 2>&1 | tail -3
echo ""

echo "==> Phase 1: Running integration tests..."
zig build test-integration 2>&1
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: Cross-compile all 8 targets (parallel via zig build cross)
# ═══════════════════════════════════════════════════════════════════════════════

echo "==> Phase 2: Building all 8 targets (ReleaseSafe, parallel)..."
rm -rf release && mkdir -p release

# Clean old deployment binaries so only current-version files are collected.
rm -f zig-out/bin/utmm-*

# Single parallel step — replaces the serial for-loop over 8 targets.
# -Dutmmd 由模式参数决定：false 时复用现有 embed（字节级不变）。
zig build cross -Doptimize=ReleaseSafe -Dutmmd=$UTMMD_FLAG
BUILD_STATUS=$?
echo ""

# Record provenance AFTER a successful --utmmd build so future --no-utmmd
# runs can verify supervisor sources did not drift.
if [ "$MODE" = "--utmmd" ] && [ "$BUILD_STATUS" -eq 0 ]; then
    git rev-parse HEAD > "$PROVENANCE"
    echo "[OK] utmmd provenance recorded: $(cat $PROVENANCE)"
fi
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "ERROR: zig build cross failed."
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3: Package
# ═══════════════════════════════════════════════════════════════════════════════

echo "==> Phase 3: Collecting deployment binaries..."
BINARY_COUNT=0
for f in zig-out/bin/utmm-*; do
    if [ -f "$f" ] && [ "$(basename "$f")" != "utmm" ]; then
        cp "$f" release/
        printf "    %8s  %s\n" "$(wc -c < "$f" | tr -d ' ')" "$(basename "$f")"
        ((BINARY_COUNT++)) || true
    fi
done

if [ "$BINARY_COUNT" -ne 8 ]; then
    echo ""
    echo "ERROR: Expected 8 binaries, found $BINARY_COUNT. Build may have failed."
    echo "Check zig build cross output above for errors."
    exit 1
fi
echo "[OK] All 8 targets collected"

echo ""
echo "==> Adding ver.txt..."
cp src/ver.txt release/
echo "  ver.txt → release/"

echo ""
echo "==> Creating utmm.zip..."
rm -f utmm.zip
cd release && zip "../utmm.zip" * && cd ..
ls -lh utmm.zip

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4: Commit, tag, push (only if everything above passed)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "==> Phase 4: Commit + tag + push..."

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "[WARN] Tag $VERSION already exists — skipping commit/tag"
    echo "  To recreate: git tag -d $VERSION && git push origin :refs/tags/$VERSION"
else
    # Auto-commit ver.txt bump if not yet committed
    if ! git diff --quiet HEAD -- src/ver.txt 2>/dev/null; then
        # ver.txt changed but not committed — stage and commit it
        echo "  Committing src/ver.txt bump to $ACTUAL_VER..."
        git add src/ver.txt
        git commit -m "v${ACTUAL_VER}: bump version"
    fi

    echo "  Tagging $VERSION..."
    git tag -a "$VERSION" -m "$VERSION: ${NOTES:-release}"

    echo "  Pushing to origin..."
    git push origin main --tags
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Publish GitHub release
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "==> Phase 5: Publishing GitHub release $VERSION..."

# Check if release already exists (tag may have been pushed earlier without release)
if gh release view "$VERSION" >/dev/null 2>&1; then
    echo "[WARN] Release $VERSION already exists on GitHub."
    echo "  To recreate: gh release delete $VERSION --yes"
    echo "  Then re-run this script."
else
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
fi

# Rebuild native target so zig-out/bin/utmm is usable for local testing
echo ""
echo "==> Rebuilding native target for local use..."
zig build -Doptimize=ReleaseSafe
echo "  zig-out/bin/utmm restored to native arch"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: macOS code-signing (Apple Silicon kills unsigned binaries with SIGKILL)
# ═══════════════════════════════════════════════════════════════════════════════

SIGN_NEEDED=0
if [ "$(uname -s)" = "Darwin" ]; then
    echo ""
    echo "==> Phase 6: macOS code-signing..."

    # 6a. Re-sign the just-built native binary (belt-and-suspenders — build.zig
    #     already signs it, but cp/scp can strip the ad-hoc signature).
    echo "  Re-signing zig-out/bin/utmm..."
    codesign --force --sign - zig-out/bin/utmm

    # 6b. If /opt/utmm/utmm exists (host is installed locally), update it and
    #     re-sign so the local host picks up the new version immediately.
    if [ -f /opt/utmm/utmm ]; then
        echo "  Updating /opt/utmm/utmm (local host binary)..."
        sudo cp zig-out/bin/utmm /opt/utmm/utmm
        sudo codesign --force --sign - /opt/utmm/utmm
        echo "  /opt/utmm/utmm updated and re-signed"
    fi

    # 6c. Re-sign cross-compiled macOS binaries in release/ so they survive
    #     scp-to-VM + cp-to-canonical-path without getting SIGKILL'd.
    for f in release/utmm-*-macos-*; do
        if [ -f "$f" ]; then
            codesign --force --sign - "$f" 2>/dev/null || true
            echo "  Re-signed: $(basename "$f")"
        fi
    done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "================================================================================"
echo "  Release $VERSION complete."
echo "  URL: https://github.com/fixnet-ai/utm-monitor/releases/tag/$VERSION"
echo ""
echo "  Next steps:"
echo "    utmm --deploy              # Deploy to local serve-dir"
echo "    utmm --upgrade <guest>     # Push upgrade to each guest"
echo "================================================================================"
