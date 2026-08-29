# Enumeration gate for the hdEmbree delegate images.
# Runs INSIDE the container (PYTHONPATH + PXR_PLUGINPATH_NAME provided by
# the caller / image env):
#   docker run -i --rm --env PYTHONPATH=/usr/local/lib/python IMAGE \
#     python3 - < ci-embree/enumerate_plugins.py
from pxr import Usd, UsdImagingGL

plugins = UsdImagingGL.Engine.GetRendererPlugins()
names = [UsdImagingGL.Engine.GetRendererDisplayName(p) for p in plugins]
print(list(zip(plugins, names)))
assert "Embree" in names, names
# the stock Storm delegate registers as "Storm" from USD 25.x on; the
# CY2023/CY2024-era stacks expose it as "GL"
assert ("Storm" in names) or ("GL" in names), names
print("enumeration OK")
