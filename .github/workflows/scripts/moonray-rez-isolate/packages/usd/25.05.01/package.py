name = "usd"

version = "25.05.01"

def commands():
    # Benchmark-specific: route usdrecord to the EGL wrapper. The pxr runtime
    # (PYTHONPATH /usr/local/lib/python) and /usr/local/bin PATH come from the
    # image base, not this package (GH #29 env audit, 2026-08).
    alias("usdrecord", "/workspace/usd-render-benchmark/tools/usdrecord_egl.py")
