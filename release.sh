#!/bin/bash
# ==============================================================================
# UTM Monitor — Release Script (thin / CI 接管版, v0.18.80+)
# https://github.com/fixnet-ai/utm-monitor
#
# 本地只做: 校验 ver.txt → 校验 clean tree → commit → annotated tag → push。
# 测试 / 8 目标构建 / SignPath 签名 / GitHub Release 全部由 CI 完成
# (.github/workflows/release.yml, tag push 触发)。
#
# Usage:
#   ./release.sh v0.18.80 "Release notes"
#
# Pre-condition: src/ver.txt must already be bumped to the target version.
#
# CI 链路: tag push → unit + integration tests → zig build cross (8 targets,
# -Dutmmd=true 从源码重建 supervisor——utmmd 模式判定已退役) → SignPath
# Windows 签名 (若 SIGNPATH_ENABLED) → GitHub Release 发布 utmm.zip。
# CI 失败时: 到 Actions 页查看失败原因, 修复后 re-run run 或删 tag 重打:
#   git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z
#   ./release.sh vX.Y.Z "notes"
# ==============================================================================

set -e
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"

print_help() {
    echo "Usage: ./release.sh <version> <notes>"
    echo ""
    echo "Example: ./release.sh v0.18.80 \"Fix X\""
    echo ""
    echo "Local steps: verify src/ver.txt → verify clean tree → commit →"
    echo "             annotated tag (notes) → push (tag triggers CI release)."
    echo ""
    echo "Tests / cross-build / SignPath signing / GitHub Release: CI only."
}

if [ -z "$VERSION" ] || [ -z "$NOTES" ]; then
    print_help
    exit 1
fi

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

# ── Commit + tag + push ──

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "[WARN] Tag $VERSION already exists — skipping commit/tag"
    echo "  To recreate: git tag -d $VERSION && git push origin :refs/tags/$VERSION"
else
    # Auto-commit ver.txt bump if not yet committed
    if ! git diff --quiet HEAD -- src/ver.txt 2>/dev/null; then
        echo "  Committing src/ver.txt bump to $ACTUAL_VER..."
        git add src/ver.txt
        git commit -m "v${ACTUAL_VER}: bump version"
    fi

    echo "  Tagging $VERSION..."
    git tag -a "$VERSION" -m "$VERSION: ${NOTES}"

    echo "  Pushing to origin..."
    git push origin main --tags
fi

echo ""
echo "================================================================================"
echo "  Tag $VERSION pushed. CI release pipeline started:"
echo "  https://github.com/fixnet-ai/utm-monitor/actions/workflows/release.yml"
echo ""
echo "  Next steps (after CI turns green):"
echo "    utmm --deploy              # Deploy to local serve-dir"
echo "    utmm --upgrade <guest>     # Push upgrade to each guest"
echo "================================================================================"
