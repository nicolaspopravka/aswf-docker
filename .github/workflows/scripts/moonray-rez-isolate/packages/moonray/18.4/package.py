name = "moonray"

version = "18.4"

# Empty by design (GH #29 env audit, 2026-08): RDL2_DSO_PATH and
# MOONRAY_CLASS_PATH are provided by the image base and are only
# scene-dependent (MoonRay rdl2 shaders). Re-add here if/when the image ENV
# is removed or a scene proves them required.
