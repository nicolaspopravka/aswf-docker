#!/usr/bin/env bash
# MoonRay VFX-Platform unification - Phase B load probe.
#
# Q: can the current common image's MoonRay run with its /opt prefix hidden and
#    the tree relocated under /usr/local, resolving all libs from /usr/local?
#    (evidence for a true VFX-Platform /usr/local-only layout, single `usd` rez env)
#
# Evidence dir argument: $1 (default /evidence).
# Optional env REFRESHED_LOG4CPLUS=/path: replace the image's /usr/local
# liblog4cplus.so.9 with this refreshed narrow-char build before running, to
# model "rebuilt on the refreshed ASWF base" without a full image rebuild.
set -u

EVID="${1:-/evidence}"
mkdir -p "$EVID"
repo() { echo "== $*" >>"$EVID/probe.log"; echo "== $*"; }

repo "moonray_unify_load_probe start $(date -u +%Y%m%dT%H%M%SZ)"
repo "image: ${DIAGNOSTIC_IMAGE:-unknown}"

apply_refreshed_log4cplus() {
    if [ -n "${REFRESHED_LOG4CPLUS:-}" ] && [ -f "$REFRESHED_LOG4CPLUS" ]; then
        repo "swapping /usr/local/lib/liblog4cplus.so.9 <- $REFRESHED_LOG4CPLUS (refreshed narrow-char)"
        cp "$REFRESHED_LOG4CPLUS" /usr/local/lib/liblog4cplus.so.9
        repo "post-swap symbol counts:"
        nm -D --defined-only /usr/local/lib/liblog4cplus.so.9 2>/dev/null | grep -c "basic_stringIw" | sed 's/^/  wchar_t (Iw): /'
        nm -D --defined-only /usr/local/lib/liblog4cplus.so.9 2>/dev/null | grep -c "basic_stringIc" | sed 's/^/  char (Ic): /'
    else
        repo "no REFRESHED_LOG4CPLUS swap (using image stock /usr/local log4cplus)"
    fi
}

run_local() {
    repo "local ldd (host avx512 n/a) - static resolution check in image"
    ldd /opt/MoonRay/installs/openmoonray/plugin/hd_moonray.so > "$EVID/ldd_hd_moonray_stock.txt" 2>&1
    {
        echo "not-found lines:"
        grep -c "not found" "$EVID/ldd_hd_moonray_stock.txt" || true
        echo "--- missing list ---"
        grep -E "not found" "$EVID/ldd_hd_moonray_stock.txt" || echo "(none)"
    } | tee "$EVID/ldd_missing_stock.txt"
}

simulate_relocate() {
    repo "simulate /usr/local relocation"
    cp -a /opt/MoonRay/installs/openmoonray/. /usr/local/openmoonray/ 2>>"$EVID/probe.log"
    mv /opt/MoonRay /opt/MoonRay.bak 2>&1 | tee -a "$EVID/probe.log"
    mv /opt/openmoonray /opt/openmoonray.bak 2>&1 | tee -a "$EVID/probe.log"
    # hide the private log4cplus so /usr/local must satisfy it
    rm -f /usr/local/openmoonray/../openmoonray
}

ldd_relocated() {
    repo "ldd on relocated /usr/local/openmoonray plugin (no /opt prefix)"
    ldd /usr/local/openmoonray/plugin/hd_moonray.so > "$EVID/ldd_relocated.txt" 2>&1
    {
        echo "not-found (should be empty if /usr/local satisfies all):"
        grep "not found" "$EVID/ldd_relocated.txt" || echo "(none)"
    } | tee "$EVID/ldd_missing_relocated.txt"
}

plugin_enum() {
    repo "plugin enumeration (proves registry sees Moonray from /usr/local)"
    cat > /tmp/renderer_enum.py <<PYEOF
import os
os.environ.setdefault("PXR_PLUGINPATH_NAME", "/usr/local/openmoonray/plugin/pxr")
from pxr import Plug
reg = Plug.Registry()
print("PXR_PLUGINPATH_NAME =", os.environ.get("PXR_PLUGINPATH_NAME"))
print("total plugins:", len(reg.GetAllPlugins()))
for p in reg.GetAllPlugins():
    print("  ", p.name, "->", p.path)
moon = [p for p in reg.GetAllPlugins() if "moonray" in str(p.name).lower()]
print("MOONRAY PLUGINS:", [str(p.name) for p in moon])
try:
    from pxr import UsdImagingGL
    print("UsdImagingGL renderers:", [str(x) for x in UsdImagingGL.Engine.GetRendererPlugins()])
except Exception as e:
    print("UsdImagingGL enum err:", e)
PYEOF
    PYTHONPATH=/usr/local/lib/python PXR_PLUGINPATH_NAME=/usr/local/openmoonray/plugin/pxr \
        python3.11 /tmp/renderer_enum.py 2>&1 | tee "$EVID/plugin_enum.txt"
}

# teapot render: build a minimal scene inline (no external asset needed)
write_scene() {
    cat > /tmp/teapot.usda <<'USDA'
#usda 1.0
def Xform "World" {
    def Sphere "S0" {
        float3[] extent = [(-0.5, -0.5, -0.5), (0.5, 0.5, 0.5)]
    }
    def DistantLight "d_light" {
        matrix4d xformOp:transform = ( (0, 0, 1, 0), (0, 1, 0, 0), (-1, 0, 0, 0), (-10, 0, 0, 1) )
        uniform token[] xformOpOrder = ["xformOp:transform"]
        float intensity = 1
        bool normalize = true
    }
    def Camera "cam" {
        matrix4d xformOp:transform = ( (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0.5, 10, 1) )
        uniform token[] xformOpOrder = ["xformOp:transform"]
        string focalLength = "test"
    }
}
USDA
}

render_moonray() {
    repo "usdrecord --renderer Moonray on minimal scene (single-rez-usd env, no LD_LIBRARY_PATH)"
    write_scene
    local out="$EVID/moonray_relocated.jpg"
    # prepend the relocated MoonRay bin dir so Arras execComp is discoverable
    export PATH="/usr/local/openmoonray/bin:$PATH"
    export PYTHONPATH=/usr/local/lib/python
    export PXR_PLUGINPATH_NAME=/usr/local/openmoonray/plugin/pxr
    export RDL2_DSO_PATH=/usr/local/openmoonray/rdl2dso
    export MOONRAY_CLASS_PATH=/usr/local/openmoonray/shader_json
    export ARRAS_SESSION_PATH=/usr/local/openmoonray/sessions
    export MOONRAY_ROOT=/usr/local/openmoonray
    # headless: xvfb-run if present (stock usdrecord wants X), else Qt offscreen
    if command -v xvfb-run >/dev/null 2>&1; then
        xvfb-run -a usdrecord --camera /World/cam --renderer "Moonray" --purposes render /tmp/teapot.usda "$out" \
            2>&1 | tee "$EVID/moonray_render.log"
        echo "usdrecord exit: ${PIPESTATUS[0]}" | tee -a "$EVID/moonray_render.log"
    else
        QT_QPA_PLATFORM=offscreen usdrecord --camera /World/cam --renderer "Moonray" --purposes render /tmp/teapot.usda "$out" \
            2>&1 | tee "$EVID/moonray_render.log"
        echo "usdrecord exit: ${PIPESTATUS[0]}" | tee -a "$EVID/moonray_render.log"
    fi
    ls -la "$out" 2>&1 | tee -a "$EVID/moonray_render.log"
}


######## MAIN ########
apply_refreshed_log4cplus
run_local
simulate_relocate
ldd_relocated
plugin_enum
render_moonray
repo "DONE. evidence under $EVID"
exit 0
