#!/usr/bin/env bash
# GH #28 probe: validate the pinned Rez source install inside an ASWF image.
#
# Mirrors the benchmark-repo helper `tools/install_rez.sh` (canonical branch
# opencode/docs/benchmark-rerun-plan): downloads the sha256-pinned Rez 3.4.0
# release tarball, verifies integrity, and runs the supported `install.py`
# source install. Asserts the three success criteria from GH #28:
#
#   1. `rez --version` reports the pinned version after install
#   2. no "Pip-based rez installation detected" warning appears
#   3. `rez env usd -- usdrecord --help` resolves (env resolution works)
#
# Usage: gh28_rez_probe.sh /probeout

set -euo pipefail
OUT="${1:-/probeout}"
mkdir -p "${OUT}"

log() { echo "== $*"; }

log "running on $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME || uname -a)"
python3 --version

# --- 1. Run the same pinned source-install path as tools/install_rez.sh ---
REZ_VERSION=3.4.0
REZ_INSTALL_DIR=/opt/rez
REZ_TARBALL_SHA256=bcef8c8d04c9846d2369b04fad2a22c1e6761c3b5a60ebe13cc42169152c3d1f
REZ_TARBALL_URL="https://github.com/AcademySoftwareFoundation/rez/releases/download/${REZ_VERSION}/${REZ_VERSION}.tar.gz"
REZ_BIN="${REZ_INSTALL_DIR}/bin/rez/rez"

tmpdir="$(mktemp -d)"
tarball="${tmpdir}/rez-${REZ_VERSION}.tar.gz"

log "downloading ${REZ_TARBALL_URL}"
curl -fsSL -o "${tarball}" "${REZ_TARBALL_URL}"
log "verifying sha256 (${REZ_TARBALL_SHA256})"
echo "${REZ_TARBALL_SHA256}  ${tarball}" | sha256sum -c -
workdir="${tmpdir}/src"
mkdir -p "${workdir}"
tar -xzf "${tarball}" -C "${workdir}" --strip-components 1
mkdir -p "${REZ_INSTALL_DIR}"
(cd "${workdir}" && python3 install.py "${REZ_INSTALL_DIR}")
rm -rf "${tmpdir}"

REZ_BIN_DIR="$(cd "$(dirname "${REZ_BIN}")" && pwd)"
export PATH="${REZ_BIN_DIR}:${PATH}"

# --- 2. Assert the three success criteria ---
echo
log "rez --version:"
rez --version 2>&1 | tee "${OUT}/rez-version.txt"
grep -q "${REZ_VERSION}" "${OUT}/rez-version.txt" \
    || { echo "FAIL: rez version does not report ${REZ_VERSION}"; exit 1; }
log "PASS: rez --version reports ${REZ_VERSION}"

# Ensure the benchmark env does NOT contain a pip install
pip show rez 2>/dev/null && { echo "FAIL: rez is pip-installed"; exit 1; } || true

# Build a minimal packages path mirroring the benchmark repo (packages/usd/...)
# so `rez env usd -- usdrecord --help` can resolve. ASWF images provide
# /usr/local/bin/usdrecord, and the package adds /usr/local/bin to PATH.
PKG_DIR="${OUT}/packages"
mkdir -p "${PKG_DIR}/usd/26.03"
cat > "${PKG_DIR}/usd/26.03/package.py" <<'PY'
name = "usd"
version = "26.03"

def commands():
    path = "/usr/local"
    env.PYTHONPATH.append(path + "/lib/python")
    env.PATH.append(path + "/bin")
PY
export REZ_PACKAGES_PATH="${PKG_DIR}"

# Resolve the usd env and exercise usdrecord; capture stderr for the warning check
set +e
rez env usd -- usdrecord --help >"${OUT}/usdrecord-help.txt" 2>"${OUT}/usdrecord-help.err"
rez_status=$?
set -e
if [ "${rez_status}" -ne 0 ]; then
    echo "FAIL: rez env usd -- usdrecord --help exited ${rez_status}" >&2
    cat "${OUT}/usdrecord-help.err" >&2 || true
    exit 1
fi
log "PASS: rez env usd -- usdrecord --help resolved and ran"
head -20 "${OUT}/usdrecord-help.txt" | tee "${OUT}/usdrecord-help-head.txt"

echo
log "scanning for pip-rez warning:"
if grep -ri "Pip-based rez installation detected" "${OUT}/usdrecord-help.err" "${OUT}/usdrecord-help.txt"; then
    echo "FAIL: pip-rez warning still appears" >&2
    exit 1
fi
log "PASS: no 'Pip-based rez installation detected' warning"

# --- 3. Summary ---
{
    echo "# GH28 Rez pinned source-install probe"
    date -u +%Y-%m-%dT%H:%M:%SZ
    uname -a
    python3 --version
    echo
    echo "## rez --version"
    cat "${OUT}/rez-version.txt"
    echo
    echo "## usdrecord --help (head)"
    cat "${OUT}/usdrecord-help-head.txt"
    echo
    echo "RESULT: PASS"
} | tee "${OUT}/summary.md"

echo
log "GH #28 probe PASSED"
