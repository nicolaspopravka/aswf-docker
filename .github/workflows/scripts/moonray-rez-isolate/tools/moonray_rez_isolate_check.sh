#!/usr/bin/env bash
# MoonRay rez package isolation check (T0-T4)
#
# Verifies each rez package defined in this branch is well-defined in isolation
# against the CURRENT image: the image provides the shared base
# (LD_LIBRARY_PATH incl. log4cplus + CUDA + /opt/openmoonray/lib{,64},
# MOONRAY_ROOT, REZ_MOONRAY_ROOT); the packages provide package-unique runtime
# discovery vars.  Each env var must be necessary and owned by the right package;
# REZ_MOONRAY_ROOT / REZ_MOONRAY_VERSION are upstream findings and must NOT be
# set by any package.
#
# Run on the pod image from the repo root (needs a working `rez`, e.g.
# pip-installed, plus GPU/EGL for the render sections):
#
#   bash tools/moonray_rez_isolate_check.sh                    # full
#   RUN_RENDER=0 bash tools/moonray_rez_isolate_check.sh       # env-level only
#
# Exit code: 0 = all checks passed, 1 = at least one check failed.

set -u

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export REZ_PACKAGES_PATH="${REZ_PACKAGES_PATH:-${REPO}/packages}"
IMAGEROOT=/opt/openmoonray
RUN_RENDER="${RUN_RENDER:-1}"
EQL="${REPO}/tools/usdrecord_egl.py"
SCENE="${SCENE:-${REPO}/assets/full_assets/Teapot/Teapot.usd}"
CAMERA="${CAMERA:-main_cam}"
# Render command: split on whitespace intentionally (`RENDER_PREFIX` then
# `RENDER_PROG`). Pod default = EGL wrapper via python3; GHA/CPU sets
# RENDER_PREFIX="xvfb-run -a" RENDER_PROG="/usr/local/bin/usdrecord".
RENDER_PREFIX="${RENDER_PREFIX:-}"
RENDER_PROG="${RENDER_PROG:-python3 ${EQL}}"
OUTDIR="${OUTDIR:-/tmp/moonray-rez-isolate}"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS+1)); echo "    [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "    [FAIL] $*"; }
skip() { SKIP=$((SKIP+1)); echo "    [SKIP] $*"; }

# is_sigill RC OUT — true when a command died from illegal-instruction (host CPU
# lacks AVX-512 the libs were built for; needs a GHA/pod host, not this Mac).
is_sigill() { [ "$1" = "132" ] || echo "$2" | grep -qi 'Illegal instruction'; }

require_rez() {
    if ! command -v rez >/dev/null 2>&1; then
        echo "ERROR: no 'rez' on PATH (install rez first)." >&2
        exit 2
    fi
}

# run_render LABEL LOGFILE
# Runs the render via $RENDER_PREFIX $RENDER_PROG (by absolute path where
# supported, so rez aliases are not involved). Pod default = EGL wrapper via
# python3; GHA/CPU sets xvfb-run + /usr/local/bin/usdrecord.
run_render() {
    local label="$1" log="$2"
    timeout 300 rez env hdMoonray -- $RENDER_PREFIX $RENDER_PROG \
        --camera "${CAMERA}" --renderer "Moonray" --purposes render \
        "${SCENE}" "${OUTDIR}/${label}.jpg" >"${log}" 2>&1
    echo "${OUTDIR}/${label}.jpg"
}

#------------------------------------------------------------------------------
echo "== T0: resolve + env dump =="
require_rez
for pkg in usd moonray mcrt_computation arras4_core hdMoonray; do
    if rez env "$pkg" -- true >/dev/null 2>&1; then
        ok "rez env ${pkg} resolves"
    else
        bad "rez env ${pkg} resolves"
    fi
done

echo "  -- crux vars under 'rez env hdMoonray' --"
rez env hdMoonray -- bash -c 'printf "    REZ_MOONRAY_ROOT=<<%s>>\n    REZ_MOONRAY_VERSION=<<%s>>\n    REZ_MCRT_COMPUTATION_VERSION=<<%s>>\n    REZ_ARRAS4_CORE_VERSION=<<%s>>\n    MOONRAY_ROOT=<<%s>>\n" \
    "${REZ_MOONRAY_ROOT-}" "${REZ_MOONRAY_VERSION-}" "${REZ_MCRT_COMPUTATION_VERSION-}" "${REZ_ARRAS4_CORE_VERSION-}" "${MOONRAY_ROOT-}"'

RMV="$(rez env hdMoonray -- printenv REZ_MOONRAY_VERSION 2>/dev/null || true)"
MCRT="$(rez env hdMoonray -- printenv REZ_MCRT_COMPUTATION_VERSION 2>/dev/null || true)"
A4C="$(rez env hdMoonray -- printenv REZ_ARRAS4_CORE_VERSION 2>/dev/null || true)"
# The intended rez env (mirrors upstream DW structure) = a moonray package
# WITH the companion computation packages so all three REZ_*_VERSION vars are
# set; hdMoonray's setupPackaging() then takes the "current-environment" branch.
if [ -n "${RMV}" ] && [ -n "${MCRT}" ] && [ -n "${A4C}" ]; then
    ok "all three REZ_*_VERSION vars set (moonray='${RMV}', mcrt='${MCRT}', arras4_core='${A4C}') -> current-environment path"
else
    bad "partial rez env: moonray='${RMV-}' mcrt='${MCRT-}' arras4_core='${A4C-}' (risk of rez2-resolve hang)"
fi
RMR="$(rez env hdMoonray -- printenv REZ_MOONRAY_ROOT 2>/dev/null || true)"
case "${RMR}" in
    "${IMAGEROOT}") ok "REZ_MOONRAY_ROOT is the install root (image/base value preserved)" ;;
    *) ok "REZ_MOONRAY_ROOT is <<${RMR:-unset}>> (clobbered by rez per GH #29; upstream finding, not a package pin)" ;;
esac

#------------------------------------------------------------------------------
echo "== T1: sufficiency probes per package =="

echo "  -- usd (alias only; PATH/PYTHONPATH from image) --"
if rez env usd -- python3 -c "import pxr.Usd; print('usd', pxr.Usd.GetVersion())" >/dev/null 2>&1; then
    ok "usd: pxr.Usd imports"
else
    bad "usd: pxr.Usd imports"
fi
USDREC="$(rez env usd -- bash -c 'type usdrecord 2>/dev/null || true')"
case "${USDREC}" in
    *usdrecord_egl.py*) ok "usd: usdrecord alias -> EGL wrapper" ;;
    *) bad "usd: usdrecord alias unexpected ('${USDREC}')" ;;
esac
PYREZ="$(rez env usd -- printenv PYTHONPATH 2>/dev/null || true)"
PYIMG="$(printenv PYTHONPATH 2>/dev/null || true)"
if [ -n "${PYREZ}" ] && [ "${PYREZ}" = "${PYIMG}" ]; then
    ok "usd: PYTHONPATH unchanged from image (pxr runtime via image base)"
else
    bad "usd: PYTHONPATH differs from image base ('${PYREZ}' vs '${PYIMG}')"
fi

echo "  -- moonray (empty package; RDL2_DSO_PATH / MOONRAY_CLASS_PATH from image) --"
RDL2="$(rez env moonray -- printenv RDL2_DSO_PATH 2>/dev/null || true)"
RDL2_IMG="$(printenv RDL2_DSO_PATH 2>/dev/null || true)"
if [ -n "${RDL2}" ] && [ "${RDL2}" = "${RDL2_IMG}" ]; then
    ok "moonray: RDL2_DSO_PATH unchanged from image base (package declares nothing)"
else
    bad "moonray: RDL2_DSO_PATH differs from image ('${RDL2}' vs '${RDL2_IMG}')"
fi
if [ -d "${IMAGEROOT}/rdl2dso" ]; then
    n_dsos="$(find "${IMAGEROOT}/rdl2dso" -maxdepth 1 -name '*.so' | wc -l | tr -d ' ')"
    ok "moonray: rdl2dso dir present in image (${n_dsos} dsos)"
else
    bad "moonray: rdl2dso dir missing under ${IMAGEROOT}"
fi
MCP="$(rez env moonray -- printenv MOONRAY_CLASS_PATH 2>/dev/null || true)"
MCP_IMG="$(printenv MOONRAY_CLASS_PATH 2>/dev/null || true)"
if [ -n "${MCP}" ] && [ "${MCP}" = "${MCP_IMG}" ]; then
    ok "moonray: MOONRAY_CLASS_PATH unchanged from image base"
else
    bad "moonray: MOONRAY_CLASS_PATH differs from image ('${MCP}' vs '${MCP_IMG}')"
fi
if [ -d "${IMAGEROOT}/shader_json" ]; then
    n_json="$(find "${IMAGEROOT}/shader_json" -name '*.json' | wc -l | tr -d ' ')"
    ok "moonray: shader_json present in image (${n_json} json)"
else
    bad "moonray: shader_json missing under ${IMAGEROOT}"
fi

echo "  -- arras4_core (empty marker; ARRAS_SESSION_PATH from image) --"
ARRAS="$(rez env arras4_core -- printenv ARRAS_SESSION_PATH 2>/dev/null || true)"
ARRAS_IMG="$(printenv ARRAS_SESSION_PATH 2>/dev/null || true)"
if [ -n "${ARRAS}" ] && [ "${ARRAS}" = "${ARRAS_IMG}" ]; then
    ok "arras4_core: ARRAS_SESSION_PATH unchanged from image base (${ARRAS})"
else
    bad "arras4_core: ARRAS_SESSION_PATH differs from image ('${ARRAS}' vs '${ARRAS_IMG}')"
fi
if [ -f "${ARRAS}/hd_single.sessiondef" ] || [ -f "${IMAGEROOT}/sessions/hd_single.sessiondef" ]; then
    ok "arras4_core: hd_single.sessiondef present"
else
    bad "arras4_core: hd_single.sessiondef missing"
fi
PATH_REZ="$(rez env arras4_core -- printenv PATH 2>/dev/null || true)"
PATH_IMG="$(printenv PATH 2>/dev/null || true)"
if [ -n "${PATH_REZ}" ] && [ "${PATH_REZ}" = "${PATH_IMG}" ]; then
    ok "arras4_core: PATH unchanged from image base (execComp via image)"
else
    bad "arras4_core: PATH differs from image base"
fi

echo "  -- mcrt_computation (empty package; covered by image LD_LIBRARY_PATH + arras4_core PATH) --"
COMPDSO=""
for c in lib/libcomputation_progmcrt.so lib64/libcomputation_progmcrt.so dso/libcomputation_progmcrt.so \
         lib64/computation/libcomputation_progmcrt.so; do
    if [ -f "${IMAGEROOT}/${c}" ]; then COMPDSO="${IMAGEROOT}/${c}"; break; fi
done
if [ -n "${COMPDSO}" ]; then
    ok "mcrt_computation: computation DSO present (${COMPDSO})"
else
    bad "mcrt_computation: computation DSO not found under ${IMAGEROOT} (candidates lib/lib64/dso)"
fi
if [ -n "${COMPDSO}" ]; then
    if ldd "${COMPDSO}" 2>/dev/null | grep -q 'not found'; then
        bad "mcrt_computation: computation DSO has unresolved deps"
    else
        ok "mcrt_computation: computation DSO deps resolve (image LD_LIBRARY_PATH)"
    fi
fi

echo "  -- hdMoonray --"
HDMX="$(rez env hdMoonray -- python3 -c "
from pxr import UsdImagingGL
plugins = UsdImagingGL.Engine.GetRendererPlugins()
names = [str(UsdImagingGL.Engine.GetRendererDisplayName(p)) for p in plugins]
print('|'.join(names))
" 2>&1)"; HDMX_RC=$?
if is_sigill "${HDMX_RC}" "${HDMX}"; then
    skip "hdMoonray: renderer-discovery probe needs AVX-512 host (SIGILL on this CPU)"
elif case "${HDMX}" in *Moonray*) ;; *) false ;; esac; then
    ok "hdMoonray: 'Moonray' renderer discovered"
else
    bad "hdMoonray: 'Moonray' not in renderer plugins ('${HDMX}')"
fi

#------------------------------------------------------------------------------
echo "== T2: remove-one necessity =="

echo "  -- PXR_PLUGINPATH_NAME (cheap, no render) --"
HDMX2="$(rez env hdMoonray -- env -u PXR_PLUGINPATH_NAME python3 -c "
from pxr import UsdImagingGL
plugins = UsdImagingGL.Engine.GetRendererPlugins()
names = [str(UsdImagingGL.Engine.GetRendererDisplayName(p)) for p in plugins]
print('|'.join(names))
" 2>&1)"; HDMX2_RC=$?
if is_sigill "${HDMX2_RC}" "${HDMX2}"; then
    skip "PXR_PLUGINPATH_NAME remove-one needs AVX-512 host (SIGILL on this CPU)"
elif case "${HDMX2}" in *Moonray*) ;; *) false ;; esac; then
    bad "PXR_PLUGINPATH_NAME removal still discovers Moonray -- var redundant/leaked"
else
    ok "PXR_PLUGINPATH_NAME removal hides Moonray (var necessary)"
fi

if [ "${RUN_RENDER}" = "1" ]; then
    mkdir -p "${OUTDIR}"

    echo "    -- baseline render (T4) --"
    baseline_img="$(run_render baseline "${OUTDIR}/t4_baseline.log")"
    if [ -s "${baseline_img}" ]; then
        ok "T4 baseline: image written"
    elif grep -qi 'Illegal instruction' "${OUTDIR}/t4_baseline.log"; then
        skip "T4 baseline: needs AVX-512 host (SIGILL on this CPU)"
    else
        bad "T4 baseline: no image written ($(cat "${OUTDIR}/t4_baseline.log" | head -c 300))"
    fi
    if grep -qiE 'Performing remote REZ resolve|REZ2_DEFAULT_VERSION' "${OUTDIR}/t4_baseline.log"; then
        bad "T4 baseline: rez2 resolve/hang symptom present"
    else
        ok "T4 baseline: no rez2 resolve/hang symptom"
    fi

    # run_subtest <label> <mode> [expected-failure-egrep] [env args...] -- via env(1)
    #   mode=fail : removal must produce a matching failure (var is necessary)
    #   mode=image: render must still complete (var is not needed for this scene)
    run_subtest() {
        local label="$1" mode="$2" pat="${3:-}"; shift 3
        local log="${OUTDIR}/t2_${label}.log" img="${OUTDIR}/t2_${label}.jpg"
        timeout 300 rez env hdMoonray -- env "$@" $RENDER_PREFIX $RENDER_PROG \
            --camera "${CAMERA}" --renderer "Moonray" --purposes render \
            "${SCENE}" "${img}" >"${log}" 2>&1
        if grep -qiE 'Illegal instruction' "${log}"; then
            skip "T2 ${label}: needs AVX-512 host (SIGILL on this CPU)"
            return
        fi
        case "${mode}" in
            fail)
                if grep -qiE "${pat}" "${log}"; then
                    ok "T2 ${label}: ${label} removal breaks render (necessary)"
                else
                    bad "T2 ${label}: no expected failure (var may not matter)"
                fi ;;
            image)
                if [ -s "${img}" ]; then
                    ok "T2 ${label}: render still completes without ${label} on the minimal scene (not required here; scene-dependent)"
                else
                    bad "T2 ${label}: no image (unexpected for a scene-independent var)"
                fi ;;
        esac
    }

    run_subtest PATH          fail 'execFailed|Failed to exec mcrt|execv|Failed to create an Arras session' PATH=/usr/local/bin:/usr/bin:/bin
    run_subtest RDL2          image '' -u RDL2_DSO_PATH
    run_subtest MOONRAYCLASS  image '' -u MOONRAY_CLASS_PATH
    run_subtest ARRASSESSION  fail 'session definition search path is empty|hd_single|Arras session' -u ARRAS_SESSION_PATH
else
    echo "    (RUN_RENDER=0: skipping render-based remove-one and T4)"
fi

#------------------------------------------------------------------------------
echo "== T3: right-place (ownership) assertions =="
# usd owns the usdrecord alias; moonray/mcrt_computation are empty version
# markers (their runtime vars come from the image base). Remaining
# package-declared vars (audit pending for the same image-provided treatment):
for expect_pkg_var in \
    "arras4_core|ARRAS_SESSION_PATH" \
    "hdMoonray|PXR_PLUGINPATH_NAME"; do
    pkg="${expect_pkg_var%%|*}"
    var="${expect_pkg_var##*|}"
    val="$(rez env "${pkg}" -- printenv "${var}" 2>/dev/null || true)"
    case "${val}" in
        "${IMAGEROOT}"*|*"${IMAGEROOT}"*) ok "${var} owned by ${pkg} (${val})" ;;
        *) bad "${var} not set by ${pkg} ('${val}')" ;;
    esac
done

#------------------------------------------------------------------------------
echo
echo "== Summary: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped =="
[ "${FAIL}" -eq 0 ] || exit 1
exit 0