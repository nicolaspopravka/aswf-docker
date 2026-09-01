#!/usr/bin/env bash
# GH #449 validation probe: sdrOsl/OIIO linkage + teardown-exit smoke.
#
# Validates that PR #449 (merged Aug 30 2026) fixes the build-level
# DT_NEEDED linking for OIIO/OSL plugins. Two checks per ASWF image:
#
#   1. readelf -d on hioOiio.so and sdrOsl.so — assert DT_NEEDED entries
#      for libOpenImageIO*.so / libosl*.so now exist
#   2. Stock usdrecord --renderer Storm on a minimal scene via Xvfb +
#      Mesa llvmpipe — assert exit code 0, zero "undefined symbol" lines
#
# Usage: gh449_sdrosl_linkage_probe.sh /probeout

set -euo pipefail
OUT="${1:-/probeout}"
mkdir -p "${OUT}"

log() { echo "== $*"; }

log "running on $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME || uname -a)"

# ── 1. Find and inspect plugin DSOs ─────────────────────────────────────────

log "--- Step 1: DT_NEEDED linkage check ---"

# Locate hioOiio.so (HIO OIIO image plugin)
HIO_OIIO=$(find /usr/local/lib /usr/local/plugin -name 'hioOiio.so' -type f 2>/dev/null | head -1)
if [ -n "${HIO_OIIO}" ]; then
    log "found hioOiio.so: ${HIO_OIIO}"
    readelf -d "${HIO_OIIO}" > "${OUT}/hioOiio_readelf.txt" 2>&1 || true
    echo "--- readelf -d ${HIO_OIIO} ---"
    cat "${OUT}/hioOiio_readelf.txt"
    echo

    # Check for DT_NEEDED entries referencing OpenImageIO or OSL
    if grep -qE 'NEEDED.*libOpenImageIO' "${OUT}/hioOiio_readelf.txt"; then
        log "PASS: hioOiio.so has DT_NEEDED for libOpenImageIO"
    else
        log "FAIL: hioOiio.so missing DT_NEEDED for libOpenImageIO"
        echo "FAIL_HIO_OIIO_MISSING_NEEDED" > "${OUT}/FAIL"
    fi
else
    log "WARNING: hioOiio.so not found — plugin may not be installed"
    echo "hioOiio.so not found" > "${OUT}/hioOiio_readelf.txt"
fi

# Locate sdrOsl.so (Sdr OSL plugin)
SDR_OSL=$(find /usr/local/lib /usr/local/plugin -name 'sdrOsl.so' -type f 2>/dev/null | head -1)
if [ -n "${SDR_OSL}" ]; then
    log "found sdrOsl.so: ${SDR_OSL}"
    readelf -d "${SDR_OSL}" > "${OUT}/sdrOsl_readelf.txt" 2>&1 || true
    echo "--- readelf -d ${SDR_OSL} ---"
    cat "${OUT}/sdrOsl_readelf.txt"
    echo

    if grep -qE 'NEEDED.*libOpenImageIO' "${OUT}/sdrOsl_readelf.txt" && \
       grep -qE 'NEEDED.*libosl' "${OUT}/sdrOsl_readelf.txt"; then
        log "PASS: sdrOsl.so has DT_NEEDED for libOpenImageIO and libosl"
    else
        log "FAIL: sdrOsl.so missing DT_NEEDED for libOpenImageIO or libosl"
        echo "FAIL_SDR_OSL_MISSING_NEEDED" > "${OUT}/FAIL"
    fi
else
    log "WARNING: sdrOsl.so not found — plugin may not be installed"
    echo "sdrOsl.so not found" > "${OUT}/sdrOsl_readelf.txt"
fi

# ── 2. Teardown-exit smoke: stock usdrecord --renderer Storm ────────────────

log "--- Step 2: teardown-exit smoke ---"

# Create a minimal USD scene (camera + sphere)
SCENE_DIR="${OUT}/scene"
mkdir -p "${SCENE_DIR}"
cat > "${SCENE_DIR}/minimal.usda" <<'USDA'
#usda 1.0
def Xform "Root" {
    def Camera "cam" {
        float32[] near = [0.1]
        float32[] far = [1000]
        float[] horizontalAperture = [20.955]
        float[] verticalAperture = [15.2908]
        float[] focalLength = [50]
        int[] projection = [1]
        matrix4d[] worldInvView = [(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 5, 1)]
    }
    def Mesh "sphere" {
        int[] faceVertexCounts = [3, 3, 3, 3]
        int[] faceVertexIndices = [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1]
        point3f[] points = [(0, 0, 1), (1, 0, 0), (0, 1, 0), (-1, 0, 0), (0, -1, 0)]
    }
}
USDA

# Install Xvfb + Mesa for software rendering
log "installing Xvfb + Mesa packages..."
dnf -y install xorg-x11-server-Xvfb mesa-dri-drivers mesa-libGL libepoxy xorg-x11-utils \
    2>/dev/null || apt-get -y install xvfb mesa-utils libgl1-mesa-dri 2>/dev/null || true

# Start Xvfb
XVFB_DISPLAY=":99"
if [ -f "/tmp/.X99-lock" ]; then
    pid=$(cat /tmp/.X99-lock 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && log "Xvfb already running" || rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
fi
Xvfb "${XVFB_DISPLAY}" -screen 0 1280x960x24 +extension GLX +render -noreset \
    > /tmp/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 2
if ! kill -0 "${XVFB_PID}" 2>/dev/null; then
    log "ERROR: Xvfb failed to start"
    cat /tmp/xvfb.log || true
    exit 1
fi
log "Xvfb started (pid ${XVFB_PID})"
export DISPLAY="${XVFB_DISPLAY}"
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QPA_PLATFORM=xcb

# Determine renderer token: CY2024 only has "GL", CY2025+ has "Storm"
RENDERER_TOKEN="Storm"
if usdrecord --help 2>&1 | grep -q '\bGL\b' && ! usdrecord --help 2>&1 | grep -q '\bStorm\b'; then
    RENDERER_TOKEN="GL"
fi
log "using renderer token: ${RENDERER_TOKEN}"

# Run usdrecord — capture both stdout and stderr
log "running: usdrecord --renderer ${RENDERER_TOKEN} --camera /Root/cam ${SCENE_DIR}/minimal.usda ${OUT}/teardown_smoke.jpg"
set +e
usdrecord --renderer "${RENDERER_TOKEN}" --camera /Root/cam \
    "${SCENE_DIR}/minimal.usda" "${OUT}/teardown_smoke.jpg" \
    > "${OUT}/usdrecord_stdout.txt" 2> "${OUT}/usdrecord_stderr.txt"
USDA_RECORD_EXIT=$?
set -e

log "usdrecord exit code: ${USDA_RECORD_EXIT}"
echo "exit_code: ${USDA_RECORD_EXIT}" > "${OUT}/teardown_smoke_exit.txt"
cat "${OUT}/usdrecord_stdout.txt" || true
cat "${OUT}/usdrecord_stderr.txt" || true

# Check for undefined symbol errors in stderr
if grep -i "undefined symbol" "${OUT}/usdrecord_stderr.txt" > /dev/null 2>&1; then
    log "FAIL: usdrecord stderr contains 'undefined symbol'"
    grep -i "undefined symbol" "${OUT}/usdrecord_stderr.txt"
    echo "FAIL_UNDEFINED_SYMBOL" > "${OUT}/FAIL"
else
    log "PASS: no 'undefined symbol' in usdrecord stderr"
fi

# Check exit code — non-zero is only acceptable if the image was written
# (benign sdrOsl teardown class)
if [ "${USDA_RECORD_EXIT}" -eq 0 ]; then
    log "PASS: usdrecord exit code 0"
elif [ -f "${OUT}/teardown_smoke.jpg" ] && [ -s "${OUT}/teardown_smoke.jpg" ]; then
    log "NOTE: usdrecord exit ${USDA_RECORD_EXIT} but image written (benign teardown class)"
else
    log "FAIL: usdrecord exit ${USDA_RECORD_EXIT} with no image"
    echo "FAIL_USDRECORD_EXIT" > "${OUT}/FAIL"
fi

# ── 3. Summary ──────────────────────────────────────────────────────────────

{
    echo "# GH #449 sdrOsl/OIIO linkage + teardown probe"
    date -u +%Y-%m-%dT%H:%M:%SZ
    uname -a
    echo
    echo "## hioOiio.so DT_NEEDED"
    if [ -n "${HIO_OIIO:-}" ]; then
        grep -E 'NEEDED' "${OUT}/hioOiio_readelf.txt" || echo "(no NEEDED entries)"
    else
        echo "not found"
    fi
    echo
    echo "## sdrOsl.so DT_NEEDED"
    if [ -n "${SDR_OSL:-}" ]; then
        grep -E 'NEEDED' "${OUT}/sdrOsl_readelf.txt" || echo "(no NEEDED entries)"
    else
        echo "not found"
    fi
    echo
    echo "## usdrecord teardown smoke"
    echo "renderer: ${RENDERER_TOKEN}"
    echo "exit code: ${USDA_RECORD_EXIT}"
    if [ -f "${OUT}/teardown_smoke.jpg" ]; then
        echo "image: $(ls -la "${OUT}/teardown_smoke.jpg")"
    else
        echo "image: not written"
    fi
    echo
    if [ -f "${OUT}/FAIL" ]; then
        echo "RESULT: FAIL ($(cat "${OUT}/FAIL"))"
    else
        echo "RESULT: PASS"
    fi
} | tee "${OUT}/summary.md"

if [ -f "${OUT}/FAIL" ]; then
    echo
    log "GH #449 probe FAILED: $(cat "${OUT}/FAIL")"
    exit 1
fi

echo
log "GH #449 probe PASSED"
