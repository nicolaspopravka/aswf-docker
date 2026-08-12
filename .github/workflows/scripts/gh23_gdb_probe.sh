#!/usr/bin/env bash
# GH #23 gdb probe: break on VtValue::_FailGet during a Moonray render of
# the minimal scene and capture the caller backtrace, to name the exact
# empty-TfToken source. CPU-only; free GitHub Actions.
#
# usdrecord is a python3 script, so gdb loads python3 (ELF) via `file` and
# passes the script + args via `set args`. LD_PRELOAD is intentionally NOT
# set for gdb's own startup; the minimal scene renders without it.
set -u

SCENE="${1:-/validation/minimal.usda}"
OUT="${2:-/probeout}"

export LIBGL_ALWAYS_SOFTWARE=1
export MESA_GL_VERSION_OVERRIDE=4.5

mkdir -p "$OUT"

if ! command -v gdb >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install gdb >/dev/null 2>&1 || dnf -y --allowerasing install gdb >/dev/null 2>&1
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf -y install gdb >/dev/null 2>&1
  fi
fi

python3_bin=$(command -v python3)
script_bin=$(command -v usdrecord)

for renderer in "Moonray" "Moonray (debug)"; do
  tag=$(echo "$renderer" | tr ' ()' '___')
  echo "===== gdb delegate: $renderer ($tag) ====="
  cat > "/tmp/gdb-$tag.cmd" <<EOF
set pagination off
set confirm off
set breakpoint pending on
file ${python3_bin}
set args ${script_bin} --renderer "${renderer}" --camera /World/Camera --imageWidth 256 ${SCENE} ${OUT}/minimal-${tag}.exr
break _ZNK34pxrInternal_v0_25_5__pxrReserved__7VtValue8_FailGetEPFNS_21Vt_DefaultValueHolderEvERKSt9type_info
commands
silent
printf "\\n=== HIT _FailGet ===\\n"
bt 25
printf "=== END HIT ===\\n"
continue
end
run
EOF
  set +e
  timeout -k 15 900 xvfb-run -a gdb -batch -x "/tmp/gdb-$tag.cmd" \
    > "$OUT/gdb-$tag.log" 2>&1
  status=$?
  set -e
  echo "$status" > "$OUT/gdb-$tag.exit"
  echo "exit=$status"
  echo "FailGet hits: $(grep -c '=== HIT _FailGet ===' "$OUT/gdb-$tag.log" || true)"
  echo "invalid framebuffer: $(grep -c 'invalid framebuffer' "$OUT/gdb-$tag.log" || true)"
  echo
done
