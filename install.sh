#!/bin/sh
# ==============================================================================
# UTM Monitor — POSIX Install/Upgrade Script
# https://github.com/fixnet-ai/utm-monitor
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/fixnet-ai/utm-monitor/main/install.sh | sudo sh
#
# Offline install:
#   1. Download utmm.zip from https://github.com/fixnet-ai/utm-monitor/releases/latest
#   2. unzip utmm.zip -d /opt/utmm/
#   3. sudo sh /opt/utmm/install.sh
#
# Manual install (no script):
#   1. Download the correct binary for your platform from the latest release
#   2. mkdir -p /opt/utmm && cp <binary> /opt/utmm/utmm && chmod +x /opt/utmm/utmm
#   3. sudo /opt/utmm/utmm --host --install              (Host)
#      sudo /opt/utmm/utmm --install --hostname mybox    (Guest)
#   Note: --install extracts the utmmd supervisor from the utmm binary and registers
#   utmmd as the system service. utmmd manages utmm's lifecycle (spawn, monitor, crash
#   recovery, upgrade).
#
# Deploy to existing Host network (v0.12.0+):
#   sudo utmm --deploy                # Build + SCP + SSH deploy to all guests
# ==============================================================================

set -e

CANONICAL_DIR="/opt/utmm"
BINARY_NAME="utmm"
DOWNLOAD_URL="https://github.com/fixnet-ai/utm-monitor/releases/latest/download/utmm.zip"
# Read version from ver.txt (bundled in release zip); fall back for curl-pipe-to-sh
if [ -f "ver.txt" ]; then
    VERSION="$(tr -d '\n\r' < ver.txt)"
else
    VERSION="latest"
fi

# ── helpers ──────────────────────────────────────────────────────────────────

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
banner() {
    echo
    bold  "========================================"
    bold  "  utmm v${VERSION}  Install / Upgrade"
    bold  "  https://github.com/fixnet-ai/utm-monitor"
    bold  "========================================"
    echo
}

die() {
    red "ERROR: $1"
    exit "${2:-1}"
}

# ── root check ───────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    die "Root privileges required. Run with: sudo sh install.sh" 1
fi

# ── banner ───────────────────────────────────────────────────────────────────

banner

# ── platform detection ───────────────────────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux)  PLATFORM_OS="linux" ;;
    Darwin) PLATFORM_OS="macos" ;;
    *)      die "Unsupported OS: $OS. Supported: Linux, macOS." 2 ;;
esac

case "$ARCH" in
    aarch64|arm64) PLATFORM_ARCH="aarch64" ;;
    x86_64|amd64)  PLATFORM_ARCH="x86_64" ;;
    i686|i386)     PLATFORM_ARCH="x86" ;;
    *)             die "Unsupported architecture: $ARCH. Supported: aarch64, x86_64, x86." 2 ;;
esac

# Look up the platform binary by wildcard pattern.
# Filenames are determined by build.zig (src/protocol.zig:deploymentFilename).
# Format: utmm-{arch}-{os}-{version}[.exe] — we wildcard the version part.
# Call after extraction so the file actually exists in $1.
resolve_binary() {
    local dir="$1"
    local pattern="utmm-${PLATFORM_ARCH}-${PLATFORM_OS}-*"
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" -print -quit 2>/dev/null
}

# Detect platform binary (may not exist yet — resolved after extraction)
ZIP_BINARY=$(resolve_binary "${CANONICAL_DIR}")
if [ -n "${ZIP_BINARY}" ]; then
    ZIP_BINARY=$(basename "${ZIP_BINARY}")
    # Re-read version from ver.txt if available in CANONICAL_DIR
    if [ -f "${CANONICAL_DIR}/ver.txt" ]; then
        VERSION="$(tr -d '\n\r' < "${CANONICAL_DIR}/ver.txt")"
    fi
fi

echo "Detected: ${PLATFORM_OS} / ${PLATFORM_ARCH}"
if [ -n "${ZIP_BINARY}" ]; then
    echo "  Binary:  ${ZIP_BINARY}"
    echo "  Version: ${VERSION}"
fi
echo

# ── interaction: hostname ────────────────────────────────────────────────────

SYSTEM_HOSTNAME="$(hostname 2>/dev/null | cut -d. -f1)"
if [ -z "${SYSTEM_HOSTNAME}" ]; then
    SYSTEM_HOSTNAME="$(cat /etc/hostname 2>/dev/null | tr -d '\n')"
fi
if [ -z "${SYSTEM_HOSTNAME}" ]; then
    SYSTEM_HOSTNAME="utmm-$(date +%s | tail -c5)"
fi

while true; do
    printf "Hostname [%s]: " "${SYSTEM_HOSTNAME}"
    read -r HOSTNAME_INPUT || die "Failed to read hostname." 1
    HOSTNAME_INPUT="${HOSTNAME_INPUT:-${SYSTEM_HOSTNAME}}"

    # Validate: 1-63 chars, starts with a-z/A-Z/0-9, only a-z0-9 _ -
    if echo "${HOSTNAME_INPUT}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,62}$'; then
        HOSTNAME="${HOSTNAME_INPUT}"
        break
    fi
    red "Invalid hostname. Use 1-63 chars: a-z, A-Z, 0-9, -, _. Must start with letter or digit."
done

# ── interaction: mode ────────────────────────────────────────────────────────

while true; do
    printf "Mode - [H]ost or [G]uest? [G]: "
    read -r MODE_INPUT || die "Failed to read mode." 1
    MODE_INPUT="${MODE_INPUT:-G}"

    case "$(echo "${MODE_INPUT}" | tr '[:lower:]' '[:upper:]')" in
        H) MODE="host"; break ;;
        G) MODE="guest"; break ;;
        *) red "Please enter H (Host) or G (Guest)." ;;
    esac
done

# ── interaction: host-ip (Guest only) ────────────────────────────────────────

HOST_IP_ARG=""
if [ "${MODE}" = "guest" ]; then
    printf "Host IP (blank = auto-detect via default gateway): "
    read -r HOST_IP_INPUT || die "Failed to read Host IP." 1
    HOST_IP_INPUT="$(echo "${HOST_IP_INPUT}" | tr -d '[:space:]')"
    if [ -n "${HOST_IP_INPUT}" ]; then
        HOST_IP_ARG="--host-ip ${HOST_IP_INPUT}"
    fi
fi

echo
echo "Summary:"
echo "  Mode:     ${MODE}"
echo "  Hostname: ${HOSTNAME}"
[ -n "${HOST_IP_ARG}" ] && echo "  Host IP:  ${HOST_IP_INPUT}"
[ -z "${HOST_IP_ARG}" ] && [ "${MODE}" = "guest" ] && echo "  Host IP:  (auto-detect)"

# ── check if already extracted (offline mode) ────────────────────────────────

mkdir -p "${CANONICAL_DIR}"

if [ -n "${ZIP_BINARY}" ] && [ -f "${CANONICAL_DIR}/${ZIP_BINARY}" ]; then
    echo
    dim "Offline mode: ${ZIP_BINARY} found in ${CANONICAL_DIR}/ - skipping download."
else
    # ── download ─────────────────────────────────────────────────────────────

    ZIP_PATH="$(mktemp /tmp/utmm.XXXXXX.zip)"
    trap "rm -f '${ZIP_PATH}'" EXIT

    echo
    echo "Downloading utmm.zip ..."

    download_file() {
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 30 --max-time 120 \
                -o "${ZIP_PATH}" "${DOWNLOAD_URL}" 2>&1
            return $?
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=30 --tries=3 \
                -O "${ZIP_PATH}" "${DOWNLOAD_URL}" 2>&1
            return $?
        else
            red "Neither curl nor wget found. Please install one of them."
            echo "Or download utmm.zip manually from: ${DOWNLOAD_URL}"
            echo "Then: unzip utmm.zip -d ${CANONICAL_DIR}/ && sudo sh ${CANONICAL_DIR}/install.sh"
            exit 3
        fi
    }

    DOWNLOAD_ATTEMPTS=3
    for i in $(seq 1 ${DOWNLOAD_ATTEMPTS}); do
        if download_file; then
            break
        fi
        if [ "${i}" -eq "${DOWNLOAD_ATTEMPTS}" ]; then
            die "Download failed after ${DOWNLOAD_ATTEMPTS} attempts. Check network or try offline install." 3
        fi
        echo "  Retry ${i}/${DOWNLOAD_ATTEMPTS} ..."
        sleep 2
    done

    echo "Download OK ($(wc -c < "${ZIP_PATH}" | tr -d ' ') bytes)"

    # ── extract ───────────────────────────────────────────────────────────────

    echo "Extracting to ${CANONICAL_DIR}/ ..."

    if ! command -v unzip >/dev/null 2>&1; then
        die "unzip not found. Install unzip first, or use offline install." 4
    fi

    if ! unzip -o -q "${ZIP_PATH}" -d "${CANONICAL_DIR}/"; then
        die "Extract failed. The zip file may be corrupted; try re-downloading." 4
    fi

    # After extraction, ver.txt is available — re-read it for accurate version display
    if [ -f "${CANONICAL_DIR}/ver.txt" ]; then
        VERSION="$(tr -d '\n\r' < "${CANONICAL_DIR}/ver.txt")"
    fi

    # Resolve platform binary from extracted files (version-independent pattern)
    ZIP_BINARY=$(resolve_binary "${CANONICAL_DIR}")
    if [ -z "${ZIP_BINARY}" ]; then
        echo "Zip contents:"
        ls -1 "${CANONICAL_DIR}/"
        die "No binary for ${PLATFORM_OS}/${PLATFORM_ARCH} found in utmm.zip. Platform not supported by this release." 5
    fi
    ZIP_BINARY=$(basename "${ZIP_BINARY}")
    echo "  Binary: ${ZIP_BINARY} (v${VERSION})"

    rm -f "${ZIP_PATH}"
    trap - EXIT
fi

# ── file placement ───────────────────────────────────────────────────────────
# The utmm binary contains both the utmmd supervisor and utmm application.
# --install extracts utmmd to /opt/utmm/utmmd and registers it as the
# system service (utmmd / com.utmmd / UTM-MonitorD).

echo "Preparing files ..."

cd "${CANONICAL_DIR}"

# Always ensure the target binary is named "utmm" (overwrite if exists)
cp -f "${ZIP_BINARY}" "${BINARY_NAME}"
chmod +x "${BINARY_NAME}"

if [ "${MODE}" = "guest" ]; then
    # Guest: only keep the current-platform binary (utmm contains both utmmd and utmm)
    echo "  Guest mode - removing other platform binaries ..."
    find "${CANONICAL_DIR}" -maxdepth 1 -type f \( -name "utmm-*" -o -name "utmm*.exe" \) ! -name "${ZIP_BINARY}" -delete 2>/dev/null || true
    dim "  Kept: ${ZIP_BINARY} (as utmm, contains utmmd supervisor)"
else
    # Host: keep all platform binaries for Host-initiated --upgrade (push model)
    echo "  Host mode - keeping all platform binaries for Guest upgrade."
    for f in "${CANONICAL_DIR}"/utmm-* "${CANONICAL_DIR}"/utmm*.exe; do
        [ -f "$f" ] && dim "  $(basename "$f")"
    done
fi

# ── install ──────────────────────────────────────────────────────────────────

echo
echo "Installing as ${MODE} ..."

INSTALL_ARGS="--install --hostname ${HOSTNAME}"
if [ "${MODE}" = "host" ]; then
    INSTALL_ARGS="--host ${INSTALL_ARGS}"
fi
if [ -n "${HOST_IP_ARG}" ]; then
    INSTALL_ARGS="${INSTALL_ARGS} ${HOST_IP_ARG}"
fi

# shellcheck disable=SC2086
if "${CANONICAL_DIR}/${BINARY_NAME}" ${INSTALL_ARGS}; then
    echo
    green "Done."
    if [ "${MODE}" = "host" ]; then
        echo "  utmmd supervisor is managing the Host service on UDP :2121"
        echo "  Status:  sudo ${CANONICAL_DIR}/${BINARY_NAME} --status"
        echo "  Deploy:  sudo ${CANONICAL_DIR}/${BINARY_NAME} --deploy [<vm>]"
    else
        echo "  utmmd supervisor installed — Guest auto-starts on boot."
        echo "  Check: run 'utmm --status' on the Host machine."
        # Remove install scripts from Guest (safe here — install is already complete)
        rm -f "${CANONICAL_DIR}/install.sh" "${CANONICAL_DIR}/install.bat" 2>/dev/null || true
    fi
else
    EXIT_CODE=$?
    red "'${BINARY_NAME} ${INSTALL_ARGS}' failed with exit code ${EXIT_CODE}."
    echo "Check service logs for details:"
    echo "  Linux:   journalctl -u utmmd -n 50"
    echo "  macOS:   cat /var/log/utmmd.log"
    exit ${EXIT_CODE}
fi
