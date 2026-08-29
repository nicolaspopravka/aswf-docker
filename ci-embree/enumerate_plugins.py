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
assert "Storm" in names, names
print("enumeration OK")
