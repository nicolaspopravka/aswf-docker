name = "hdMoonray"

version = "7.6"

variants = [
    ["usd-25.05.01"]
]

requires = [
    'moonray-18.4',
    'mcrt_computation-16.4',
    'arras4_core-4.10'
]

def commands():
    path = "/opt/openmoonray"

    env.PXR_PLUGINPATH_NAME.append(path + "/plugin/pxr")
