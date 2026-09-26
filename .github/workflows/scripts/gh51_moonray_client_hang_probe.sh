#!/usr/bin/env bash
# GH #51 probe: does the MoonRay (Arras) Hydra client exit when its render
# worker dies?
#
# Symptom under investigation (CY2024.3 run, 2026-09-22): the Arras render
# worker (mcrt) was killed while rendering Moana Island. Arras reported
#     Error: Arras session stopped, compExited: mcrt exited due to signal 9
# but the usdrecord client stayed alive, so the harness blocked until its
# whole-run deadline and the cells after that one never ran.
#
# This probe reproduces the *client liveness* question with a real MoonRay
# render and a synthetic worker kill, so it needs no OOM and no paid compute:
#   1. start a real `usdrecord --renderer Moonray` cell (the same command the
#      harness runs, from the run branch's Rez environment)
#   2. wait for the Arras render worker to appear, let it shade a little
#   3. SIGKILL the worker -- indistinguishable from the pod's OOM killer as
#      far as the client is concerned
#   4. watch the client: does it exit, and with what status?
#
# Expected outcomes:
#   CLIENT EXITED code=N     the delegate propagates the failure (fixed behavior)
#   CLIENT STILL ALIVE        the GH #51 hang, reproduced
#
# Usage:
#   bash tools/gh51_moonray_client_hang_probe.sh [options]
#     --repo DIR         benchmark checkout whose packages/ + tools/ to use
#                        (default: the CY2024.3 run worktree)
#     --image IMAGE      container image (default: the 2024.3 runnable digest)
#     --scene PATH       scene to render, relative to --repo
#     --camera CAM       camera argument
#     --renderer NAME    renderer token (default Moonray)
#     --rez-package PKG  Rez package that provides usdrecord (default openusd/24.08;
#                        use openusd/23.08 with the 2023.3 runnable image)
#     --kill-after SEC   seconds of shading before killing the worker (default 20)
#     --observe SEC      seconds to wait for the client to exit afterwards (default 90)
#     --keep             keep the container and print its id for inspection
#     --no-setup         skip installing the software-GL bits (the image already
#                        has them)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO="${GH51_REPO:-${HOME}/Projects/usd-render-benchmark}"
IMAGE="${GH51_IMAGE:-ghcr.io/nicolaspopravka/usd-render-benchmark@sha256:9327af68f87900bad78f838d8c1f7fad3df78bf7b8153f5b8eb5f0bb5765bcb3}"
SCENE="${GH51_SCENE:-assets/full_assets/McUsd/McUsd.usda}"
CAMERA="${GH51_CAMERA:-/McUsd/Camera}"
RENDERER="${GH51_RENDERER:-Moonray}"
REZ_PACKAGE="${GH51_REZ_PACKAGE:-openusd/24.08}"
KILL_AFTER="${GH51_KILL_AFTER:-20}"
OBSERVE="${GH51_OBSERVE:-90}"
KEEP=0
SETUP=1

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --scene) SCENE="$2"; shift 2 ;;
        --camera) CAMERA="$2"; shift 2 ;;
        --renderer) RENDERER="$2"; shift 2 ;;
        --rez-package) REZ_PACKAGE="$2"; shift 2 ;;
        --kill-after) KILL_AFTER="$2"; shift 2 ;;
        --observe) OBSERVE="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-setup) SETUP=0; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -d "$REPO" ]; then
    echo "ERROR: --repo not found: $REPO" >&2
    exit 2
fi

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gh51-probe-XXXXXX")"
CONTAINER="gh51-moonray-hang-probe-$$"

cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "container kept: ${CONTAINER}"
        return
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "GH #51 probe"
echo "  image    : ${IMAGE}"
echo "  repo     : ${REPO}"
echo "  cell     : ${RENDERER} / ${SCENE} (camera ${CAMERA})"
echo "  rez      : ${REZ_PACKAGE}"
echo "  kill     : SIGKILL the Arras render worker after ${KILL_AFTER}s of shading"
echo "  observe  : ${OBSERVE}s for the client to exit"
echo

INNER=$(cat <<'INNER_EOF'
set -uo pipefail
REPO=/workspace/usd-render-benchmark
LOG=/tmp/cell.log
OUT=/tmp/entry.jpg
: > "${LOG}"

export REZ_PACKAGES_PATH="${REPO}/packages"
cd "${REPO}" || exit 66

if [ "__SETUP__" = "1" ]; then
    # Same software-GL setup the stack repo's run-demo workflow uses: the
    # 2023-2026 runnable images ship no /usr/lib64/dri, so llvmpipe has to be
    # installed; ASWF LLVM 17 needs the distro LLVM on the path (GH #46); and
    # the Mesa disk cache is disabled for the CY2027 zstd abort (GH #45).
    if [ ! -d /usr/lib64/dri ] && ! ls /usr/lib64/dri/*_dri.so >/dev/null 2>&1; then
        echo "--- installing mesa-dri-drivers (no software GL in this image) ---"
        dnf install -y --disablerepo=cuda mesa-dri-drivers || true
    fi
    if [ -d /usr/lib64/llvm17/lib ]; then
        export LD_LIBRARY_PATH=/usr/lib64/llvm17/lib:${LD_LIBRARY_PATH:-}
    fi
    export MESA_SHADER_CACHE_DISABLE=true
    export LIBGL_ALWAYS_SOFTWARE=1
fi

echo "--- container facts ---"
echo "host cpus: $(nproc)  mem: $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
echo "software GL drivers: $(ls /usr/lib64/dri/*_dri.so 2>/dev/null | head -3 | tr '\n' ' ' || echo none)"
echo "renderer token: ${RENDERER}"

# The harness renders through Rez; the image bakes the delegate environment.
# The alias resolves to the EGL wrapper, which needs a working EGL device; when
# that is unavailable (no GPU in the container) fall back to the image's stock
# usdrecord under Xvfb, which renders the same delegate through GLX.
start_render() {
    # A GL context is needed either way: EGL when the alias and a device are
    # available, GLX under Xvfb otherwise. Set up Xvfb unconditionally when there
    # is no DISPLAY, so both paths work on a headless runner.
    if [ -z "${DISPLAY:-}" ] && command -v Xvfb >/dev/null 2>&1; then
        Xvfb :99 -screen 0 1280x1024x24 >/tmp/xvfb.log 2>&1 &
        sleep 2
        export DISPLAY=:99
    fi
    export LIBGL_ALWAYS_SOFTWARE=1
    if rez env "${REZ_PACKAGE}" -- usdrecord --help >/dev/null 2>&1; then
        echo "render path: rez env ${REZ_PACKAGE} -- usdrecord (EGL wrapper)"
        rez env "${REZ_PACKAGE}" -- usdrecord \
            --camera "${CAMERA}" --renderer "${RENDERER}" --purposes render \
            "${SCENE}" "${OUT}" >>"${LOG}" 2>&1 &
    else
        echo "render path: stock /usr/local/bin/usdrecord under Xvfb (EGL unavailable)"
        /usr/local/bin/usdrecord \
            --camera "${CAMERA}" --renderer "${RENDERER}" --purposes render \
            "${SCENE}" "${OUT}" >>"${LOG}" 2>&1 &
    fi
    CLIENT_PID=$!
}

# Match the Arras render worker by process name, not by command line: this
# script's own command line contains the word "mcrt", so `pgrep -f mcrt` would
# match the probe shell itself.
worker_pids() {
    pgrep -x mcrt 2>/dev/null || pgrep -f '/mcrt( |$)' 2>/dev/null
}

echo "--- starting the cell ---"
start_render
echo "client pid: ${CLIENT_PID}"

DEADLINE=$((SECONDS + 180))
WORKER=""
while [ $SECONDS -lt $DEADLINE ]; do
    if ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
        echo "RESULT: client exited before any worker appeared (see log)"
        tail -20 "${LOG}"
        exit 3
    fi
    WORKER="$(worker_pids | head -n 1)"
    [ -n "${WORKER}" ] && break
    sleep 2
done

if [ -z "${WORKER}" ]; then
    echo "RESULT: no Arras render worker (mcrt) appeared within 180s"
    tail -20 "${LOG}"
    exit 4
fi

echo "--- render worker up: mcrt pid ${WORKER}; letting it shade ${KILL_AFTER}s ---"
sleep "${KILL_AFTER}"
if ! kill -0 "${WORKER}" 2>/dev/null; then
    echo "RESULT: worker ${WORKER} already gone before the kill (unexpected)"
fi
echo "--- SIGKILL mcrt ${WORKER} (what an OOM kill looks like to the client) ---"
kill -9 "${WORKER}" 2>/dev/null || true
KILL_AT=$SECONDS

echo "--- watching the client for ${OBSERVE}s ---"
while [ $((SECONDS - KILL_AT)) -lt ${OBSERVE} ]; do
    if ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
        wait "${CLIENT_PID}"
        CODE=$?
        echo "--- client log tail ---"
        tail -12 "${LOG}"
        if [ -f "${OUT}" ]; then
            echo "output image: present ($(stat -c %s "${OUT}") bytes)"
        else
            echo "output image: absent"
        fi
        echo "RESULT: CLIENT EXITED code=${CODE} after $((SECONDS - KILL_AT))s"
        exit 0
    fi
    sleep 2
done

echo "--- client log tail (last 12 lines) ---"
tail -12 "${LOG}"
echo "--- process state ---"
ps -o pid,ppid,stat,etime,time,comm -p "${CLIENT_PID}" 2>/dev/null || true
echo "children still alive:"
pgrep -P "${CLIENT_PID}" 2>/dev/null | while read -r p; do
    ps -o pid,ppid,stat,etime,time,args -p "$p" 2>/dev/null | tail -1
done
echo "surviving render workers:"
worker_pids || echo "(none)"
echo "RESULT: CLIENT STILL ALIVE ${OBSERVE}s after its render worker died"
exit 1
INNER_EOF
)
INNER="${INNER//\$\{RENDERER\}/${RENDERER}}"
INNER="${INNER//\$\{CAMERA\}/${CAMERA}}"
INNER="${INNER//\$\{SCENE\}/${SCENE}}"
INNER="${INNER//\$\{KILL_AFTER\}/${KILL_AFTER}}"
INNER="${INNER//\$\{OBSERVE\}/${OBSERVE}}"
INNER="${INNER//\$\{REZ_PACKAGE\}/${REZ_PACKAGE}}"
INNER="${INNER//__SETUP__/${SETUP}}"

docker run --rm --name "$CONTAINER" --platform linux/amd64 \
    --entrypoint /bin/bash \
    -e RENDERER="$RENDERER" -e CAMERA="$CAMERA" -e SCENE="$SCENE" \
    -e REZ_PACKAGE="$REZ_PACKAGE" \
    -e KILL_AFTER="$KILL_AFTER" -e OBSERVE="$OBSERVE" \
    -v "${REPO}:/workspace/usd-render-benchmark:ro" \
    -v "${OUT_DIR}:/probe-out" \
    "$IMAGE" -lc "$INNER" 2>&1 | tee "${OUT_DIR}/gh51-moonray-client-hang-probe.log"

STATUS=${PIPESTATUS[0]}
echo
echo "probe log: ${OUT_DIR}/gh51-moonray-client-hang-probe.log"
exit "$STATUS"
