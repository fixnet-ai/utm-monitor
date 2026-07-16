#!/bin/bash
# =============================================================================
# UTM Monitor — Comprehensive Cross-Platform Test Suite (v0.1.0+)
# =============================================================================
# Covers: build (5 targets), unit tests, --deploy, --status, --exec,
#         --upload/--download, HTTP API, Host/serve-dir, /etc/hosts,
#         --install/--uninstall (SSH), --gen-init, --mcp, musl verify.
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_FILE="$PROJECT_DIR/test_report.txt"
ZIG_OUT="$PROJECT_DIR/zig-out/bin"
HOST_BIN="$ZIG_OUT/utmm"
SERVE_DIR="/opt/utmm"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
VMS="linuxvm macvm windowsvm"

PASS=0; FAIL=0; SKIP=0

# ── Auto-detect version from src/ver.zig ──
VERSION=$(awk '/pub const VERSION/ { gsub(/"/,"",$4); print $4 }' "$PROJECT_DIR/src/ver.zig" 2>/dev/null || echo "0.0.0")

# ── Build targets + deployment filenames ──
#    Format: "zig-target:output-filename"
BUILD_TARGETS=(
    "x86-windows:utmm.exe"
    "x86_64-macos:utmm.macos"
    "aarch64-macos:utmm_arm64.macos"
    "x86_64-linux-musl:utmm"
    "aarch64-linux-musl:utmm_arm64"
)

# ── VM config (still needed for SCP bootstrap + install/uninstall via SSH) ──
vm_ip()   { case $1 in linuxvm) echo "192.168.64.2";; macvm) echo "192.168.64.4";; windowsvm) echo "192.168.65.2";; esac; }
vm_user() { case $1 in linuxvm|macvm) echo "root";; windowsvm) echo "Administrator";; esac; }
vm_pass() { echo "111"; }
vm_path() { case $1 in linuxvm|macvm) echo "/opt/utmm/utmm";; windowsvm) echo "C:\\opt\\utmm\\utmm.exe";; esac; }

# ── Helpers ──
report() { echo "$@" | tee -a "$REPORT_FILE"; }
pass()   { PASS=$((PASS+1)); report "  ✅ PASS: $1"; }
fail()   { FAIL=$((FAIL+1)); report "  ❌ FAIL: $1 — $2"; }
skip()   { SKIP=$((SKIP+1)); report "  ⏭  SKIP: $1 — $2"; }

ssh_vm() {
    local vm="$1" cmd="$2" user ip pass
    user=$(vm_user "$vm"); ip=$(vm_ip "$vm"); pass=$(vm_pass "$vm")
    if [ "$vm" = "windowsvm" ]; then
        sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$user@$ip" "$cmd" 2>&1
    else
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$user@$ip" "$cmd" 2>&1
    fi
}

http_get()     { curl -s --connect-timeout 3 "$1" 2>/dev/null; }
http_post()    { curl -s --connect-timeout 3 -X POST -H "Content-Type: application/json" -d "$2" "$1" 2>/dev/null; }
is_cmd()       { command -v "$1" >/dev/null 2>&1; }
file_size()    { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "0"; }

# ── Init report ──
: > "$REPORT_FILE"
report "=============================================="
report "  UTM Monitor — Comprehensive Test Report"
report "  Date:    $TIMESTAMP"
report "  Version: $VERSION"
report "  Project: $PROJECT_DIR"
report "=============================================="
report ""

# =============================================================================
# PHASE 1: CLEAN + UNIT TESTS
# =============================================================================
report "━━━ PHASE 1: Unit Tests ━━━"
report ""

cd "$PROJECT_DIR"
rm -rf .zig-cache zig-out 2>/dev/null || true

report "1.1 Running zig build test..."
if zig build test --summary all 2>&1 | tee -a "$REPORT_FILE"; then
    pass "Unit tests pass"
else
    fail "Unit tests" "some tests failed"
fi
report ""

# =============================================================================
# PHASE 2: CROSS-COMPILE ALL 5 TARGETS
# =============================================================================
report "━━━ PHASE 2: Cross-Compilation (5 targets) ━━━"
report ""

FAILED_TARGETS=""

for entry in "${BUILD_TARGETS[@]}"; do
    target="${entry%%:*}"
    outfile="${entry##*:}"

    report "    Building $target → $outfile ..."
    zig build -Dtarget="$target" -Doptimize=ReleaseSafe 2>&1 | tail -1

    BIN="$ZIG_OUT/$outfile"
    if [ -f "$BIN" ]; then
        sz=$(file_size "$BIN")
        pass "Build $target → $outfile ($sz bytes)"

        # Musl static check for Linux targets
        if echo "$target" | grep -q "linux"; then
            if file "$BIN" 2>/dev/null | grep -q "statically linked"; then
                pass "  └─ musl static link verified"
            else
                fail "  └─ musl static link" "not statically linked"
            fi
        fi
    else
        fail "Build $target" "binary $outfile not found"
        FAILED_TARGETS="$FAILED_TARGETS $target"
    fi
done

# Native fallback for Host commands
zig build -Doptimize=ReleaseSafe 2>&1 | tail -1
if [ -f "$HOST_BIN" ]; then
    pass "Native build → utmm ($(file_size "$HOST_BIN") bytes)"
else
    fail "Native build" "utmm not found"
fi
report ""

# =============================================================================
# PHASE 3: VERSION
# =============================================================================
report "━━━ PHASE 3: Version Verification ━━━"
report ""

BIN_VER=$("$HOST_BIN" --version 2>&1 | awk '{print $2}' | tr -d 'v' || echo "unknown")
report "    Binary version: $BIN_VER"
if [ "$BIN_VER" = "$VERSION" ]; then
    pass "Version matches src/ver.zig ($VERSION)"
else
    fail "Version mismatch" "binary=$BIN_VER, source=$VERSION"
fi

# Verify ver.zig is the single source of truth
if grep -q "pub const VERSION" "$PROJECT_DIR/src/ver.zig"; then
    pass "ver.zig is single version source"
else
    fail "ver.zig" "missing VERSION constant"
fi
report ""

# =============================================================================
# PHASE 4: SERVE-DIR SETUP + HOST START
# =============================================================================
report "━━━ PHASE 4: Host Startup + Serve-Dir ━━━"
report ""

sudo mkdir -p "$SERVE_DIR"

for entry in "${BUILD_TARGETS[@]}"; do
    outfile="${entry##*:}"
    if [ -f "$ZIG_OUT/$outfile" ]; then
        sudo cp "$ZIG_OUT/$outfile" "$SERVE_DIR/"
    fi
done
sudo chmod +x "$SERVE_DIR"/* 2>/dev/null || true
report "    Serve-dir populated: $(ls "$SERVE_DIR" | tr '\n' ' ')"

# Kill previous host
sudo pkill -9 utmm 2>/dev/null || true
sleep 1

# Start host
sudo nohup "$HOST_BIN" --host --serve-dir "$SERVE_DIR" > /tmp/utmm-host.log 2>&1 &
HOST_PID=$!
report "    Host started (PID: $HOST_PID, serve-dir: $SERVE_DIR)"

report "    Waiting 8s for VM discovery..."
sleep 8

if ps -p "$HOST_PID" > /dev/null 2>&1; then
    pass "Host process running"
else
    fail "Host process" "not running — check /tmp/utmm-host.log"
fi
report ""

# =============================================================================
# PHASE 5: --status DISCOVERY
# =============================================================================
report "━━━ PHASE 5: VM Discovery (--status) ━━━"
report ""

STATUS_OUT=$("$HOST_BIN" --host --status 2>&1 || true)
report "$(echo "$STATUS_OUT" | head -20)"

ONLINE_VMS=""
for vm in $VMS; do
    if echo "$STATUS_OUT" | grep -qi "$vm"; then
        pass "--status: $vm visible"
        ONLINE_VMS="$ONLINE_VMS $vm"
    else
        skip "--status: $vm" "VM not online or build failed for its target"
    fi
done
report ""

# =============================================================================
# PHASE 6: /etc/hosts SYNC
# =============================================================================
report "━━━ PHASE 6: /etc/hosts Sync ━━━"
report ""

if grep -q "UTM-MONITOR-BEGIN" /etc/hosts 2>/dev/null; then
    pass "/etc/hosts has UTM-MONITOR marker block"
    report "$(grep -A 20 "UTM-MONITOR-BEGIN" /etc/hosts | sed 's/^/    /')"
else
    fail "/etc/hosts sync" "no UTM-MONITOR marker found"
fi
report ""

# =============================================================================
# PHASE 7: --exec REMOTE COMMANDS
# =============================================================================
report "━━━ PHASE 7: Remote Command Execution (--exec) ━━━"
report ""

for vm in $ONLINE_VMS; do
    case $vm in
        linuxvm|macvm) cmd="uname -a" ;;
        windowsvm)     cmd="ver" ;;
    esac

    EXEC_OUT=$("$HOST_BIN" --host --exec "$vm" "$cmd" 2>&1 || true)
    if echo "$EXEC_OUT" | grep -qi "GuestNotFound\|exec failed\|refused"; then
        fail "--exec $vm" "$(echo "$EXEC_OUT" | head -1)"
    else
        pass "--exec $vm ($cmd)"
        report "        → $(echo "$EXEC_OUT" | tail -1)"
    fi
done
report ""

# =============================================================================
# PHASE 8: --upload / --download (CLI)
# =============================================================================
report "━━━ PHASE 8: File Upload & Download (--upload / --download CLI) ━━━"
report ""

TEST_DATA="UTM test suite — $TIMESTAMP"
TEST_FILE="/tmp/utm-test-upload.txt"
echo "$TEST_DATA" > "$TEST_FILE"

for vm in $ONLINE_VMS; do
    # Upload via built-in --upload (no curl needed)
    if "$HOST_BIN" --host --upload "$TEST_FILE" "$vm" 2>&1 | grep -qi "OK"; then
        # Download via built-in --download
        DL_FILE="/tmp/utm-test-download-$vm.txt"
        if "$HOST_BIN" --host --download "$vm" "test_upload.txt" "$DL_FILE" 2>&1 | grep -qi "OK"; then
            if grep -q "UTM test suite" "$DL_FILE" 2>/dev/null; then
                pass "--upload + --download $vm"
            else
                fail "--download $vm" "content mismatch"
            fi
            rm -f "$DL_FILE"
        else
            fail "--download $vm" "download command failed"
        fi
    else
        fail "--upload $vm" "upload command failed"
    fi
done
rm -f "$TEST_FILE"
report ""

# =============================================================================
# PHASE 9: HTTP API TESTS
# =============================================================================
report "━━━ PHASE 9: Guest HTTP API ━━━"
report ""

for vm in $ONLINE_VMS; do
    ip=$(vm_ip "$vm")

    # /health
    HEALTH=$(http_get "http://$ip:2121/health" || echo "FAILED")
    if [ "$HEALTH" = "OK" ]; then
        pass "HTTP /health $vm"
    else
        fail "HTTP /health $vm" "got: $HEALTH"
    fi

    # /version
    VER=$(http_get "http://$ip:2121/version" | tr -d ' \n\r' || echo "FAILED")
    if [ "$VER" = "$VERSION" ]; then
        pass "HTTP /version $vm ($VER)"
    else
        fail "HTTP /version $vm" "expected $VERSION, got: $VER"
    fi
done
report ""

# --- HTTP /exec ---
report "9.1 HTTP POST /exec"
for vm in $ONLINE_VMS; do
    ip=$(vm_ip "$vm")
    case $vm in
        linuxvm|macvm) cmd='{"cmd":"uname -m"}' ;;
        windowsvm)     cmd='{"cmd":"echo ok"}' ;;
    esac

    EXEC=$(http_post "http://$ip:2121/exec" "$cmd" || echo "FAILED")
    if [ "$EXEC" != "FAILED" ] && [ -n "$EXEC" ]; then
        pass "HTTP /exec $vm"
    else
        fail "HTTP /exec $vm" "no response"
    fi
done
report ""

# --- Host HTTP ---
report "9.2 Host HTTP file server"
HOST_IP=$(ifconfig en0 2>/dev/null | awk '/inet /{print $2}' || echo "127.0.0.1")
HOST_VER=$(http_get "http://$HOST_IP:2121/version" | tr -d ' \n\r' || echo "FAILED")
if [ "$HOST_VER" = "$VERSION" ]; then
    pass "Host HTTP /version ($HOST_VER)"
else
    fail "Host HTTP /version" "expected $VERSION, got: $HOST_VER"
fi

# Host /bin/:filename download
HOST_DL_SZ=$(http_get "http://$HOST_IP:2121/bin/utmm_arm64" 2>/dev/null | wc -c | tr -d ' ')
if [ "${HOST_DL_SZ:-0}" -gt 100000 ]; then
    pass "Host HTTP /bin/utmm_arm64 (${HOST_DL_SZ} bytes)"
else
    fail "Host HTTP /bin/:file" "download too small (${HOST_DL_SZ:-0} bytes)"
fi
report ""

# =============================================================================
# PHASE 10: --deploy (if VMs online)
# =============================================================================
report "━━━ PHASE 10: One-Click Deploy (--deploy) ━━━"
report ""

if [ -n "$ONLINE_VMS" ]; then
    DEPLOY_OUT=$("$HOST_BIN" --host --deploy 2>&1 || true)
    report "$(echo "$DEPLOY_OUT" | head -20)"
    if echo "$DEPLOY_OUT" | grep -qi "complete"; then
        pass "--deploy (all online VMs)"
    else
        fail "--deploy" "deploy did not complete"
    fi
else
    skip "--deploy" "no VMs online"
fi
report ""

# =============================================================================
# PHASE 11: --gen-init
# =============================================================================
report "━━━ PHASE 11: Init Script Generation (--gen-init) ━━━"
report ""

for plat in linux macos windows; do
    INIT=$("$HOST_BIN" --host --gen-init "$plat" 2>&1 || true)
    case $plat in
        linux)
            echo "$INIT" | grep -q "multi-user.target" \
                && pass "--gen-init linux (boot-time: multi-user.target)" \
                || fail "--gen-init linux" "missing multi-user.target"
            ;;
        macos)
            echo "$INIT" | grep -q "LaunchDaemons" \
                && pass "--gen-init macos (boot-time: LaunchDaemons)" \
                || fail "--gen-init macos" "missing LaunchDaemons"
            ;;
        windows)
            echo "$INIT" | grep -qi "onstart" \
                && pass "--gen-init windows (boot-time: /sc onstart)" \
                || fail "--gen-init windows" "missing /sc onstart"
            ;;
    esac
done
report ""

# =============================================================================
# PHASE 12: MCP JSON-RPC (smoke test)
# =============================================================================
report "━━━ PHASE 12: MCP JSON-RPC (stdio) ━━━"
report ""

# Build initialize request with LSP-style framing
INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
INIT_BODY=$(printf 'Content-Length: %d\r\n\r\n%s\n' "${#INIT_REQ}" "$INIT_REQ")

MCP_RESP=$("$HOST_BIN" --mcp 2>/dev/null <<< "$INIT_BODY" || echo "MCP_FAILED")

if echo "$MCP_RESP" | grep -q "serverInfo"; then
    pass "MCP initialize response"
    if echo "$MCP_RESP" | grep -q "$VERSION"; then
        pass "MCP reports version $VERSION"
    else
        fail "MCP version" "version not in response"
    fi
else
    fail "MCP initialize" "no serverInfo in response"
fi

# tools/list
TL_REQ='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
TL_BODY=$(printf 'Content-Length: %d\r\n\r\n%s\n' "${#TL_REQ}" "$TL_REQ")
TL_RESP=$("$HOST_BIN" --mcp 2>/dev/null <<< "$TL_BODY" || echo "MCP_FAILED")
if echo "$TL_RESP" | grep -q "vm_status"; then
    pass "MCP tools/list (has vm_status)"
else
    fail "MCP tools/list" "vm_status not found"
fi
report ""

# =============================================================================
# PHASE 13: MUSL STATIC LINKING (Linux targets)
# =============================================================================
report "━━━ PHASE 13: Musl Static Linking ━━━"
report ""

for entry in "${BUILD_TARGETS[@]}"; do
    target="${entry%%:*}"
    outfile="${entry##*:}"
    case "$target" in
        *linux*)
            if [ -f "$ZIG_OUT/$outfile" ]; then
                if file "$ZIG_OUT/$outfile" 2>/dev/null | grep -q "statically linked"; then
                    pass "$outfile: musl static-linked ✓"
                else
                    fail "$outfile: musl" "not statically linked"
                fi
            fi
            ;;
    esac
done
report ""

# =============================================================================
# PHASE 14: SSH-BASED GUEST TESTS (soft — skip if VMs unreachable)
# =============================================================================
report "━━━ PHASE 14: Guest Install/Uninstall (SSH required) ━━━"
report ""

if is_cmd sshpass && is_cmd ssh; then
    for vm in $VMS; do
        ip=$(vm_ip "$vm")

        # Quick connectivity check
        if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$(vm_user "$vm")@$ip" "echo ok" >/dev/null 2>&1; then
            if ! sshpass -p "$(vm_pass "$vm")" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 "$(vm_user "$vm")@$ip" "echo ok" >/dev/null 2>&1; then
                skip "SSH $vm" "$ip unreachable"
                continue
            fi
        fi

        # --- Install ---
        report "14.x --install $vm..."
        INSTALL_OUT=$(ssh_vm "$vm" "$(vm_path "$vm") --install" 2>&1 || echo "INSTALL_FAILED")
        if echo "$INSTALL_OUT" | grep -qi "installation complete\|complete\|onstart\|/sc"; then
            pass "--install $vm"
        else
            fail "--install $vm" "$(echo "$INSTALL_OUT" | head -1)"
        fi

        # --- Uninstall ---
        report "14.x --uninstall $vm..."
        UNINSTALL_OUT=$(ssh_vm "$vm" "$(vm_path "$vm") --uninstall" 2>&1 || echo "UNINSTALL_FAILED")
        if echo "$UNINSTALL_OUT" | grep -qi "uninstall complete\|removed"; then
            pass "--uninstall $vm"
        else
            fail "--uninstall $vm" "$(echo "$UNINSTALL_OUT" | head -1)"
        fi
        report ""
    done

    # Host install/uninstall (macOS only)
    if [ "$(uname -s)" = "Darwin" ]; then
        report "14.x Host --install..."
        sudo "$HOST_BIN" --host --install 2>&1 || true
        if [ -f /Library/LaunchDaemons/com.utmm.plist ]; then
            pass "Host --install (LaunchDaemons plist)"
        else
            fail "Host --install" "plist not created"
        fi

        report "14.x Host --uninstall..."
        sudo "$HOST_BIN" --host --uninstall 2>&1 || true
        if [ ! -f /Library/LaunchDaemons/com.utmm.plist ]; then
            pass "Host --uninstall (plist removed)"
        else
            fail "Host --uninstall" "plist still present"
        fi
    fi
else
    skip "SSH tests" "sshpass not installed (brew install sshpass)"
fi
report ""

# =============================================================================
# FINAL REPORT
# =============================================================================
report "=============================================="
report "  FINAL REPORT"
report "=============================================="
report ""
report "  Version:    $VERSION"
report "  ✅ Passed:  $PASS"
report "  ❌ Failed:  $FAIL"
report "  ⏭  Skipped: $SKIP"
TOTAL=$((PASS + FAIL))
if [ "$TOTAL" -gt 0 ]; then
    PASS_RATE=$((PASS * 100 / TOTAL))
    report "  📊 Rate:    $PASS_RATE% ($PASS/$TOTAL)"
fi
report ""
report "  Build targets: ${BUILD_TARGETS[*]}"
report "  Online VMs:   ${ONLINE_VMS:-none}"
report "  Serve-dir:    $SERVE_DIR"
report "  Host:         $(uname -a | cut -c1-60)"
report "  Timestamp:    $TIMESTAMP"
report "  Report file:  $REPORT_FILE"
report ""
report "=============================================="

# Cleanup
sudo pkill -9 utmm 2>/dev/null || true
rm -f /tmp/utmm-host.log

echo ""
echo "Test report → $REPORT_FILE"
exit "$FAIL"
