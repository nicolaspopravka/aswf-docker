name = "moonray"

version = "18.4"

def commands():
    path = "/opt/openmoonray"

    env.RDL2_DSO_PATH.append(path + "/rdl2dso.proxy")
    env.RDL2_DSO_PATH.append(path + "/rdl2dso")

    env.MOONRAY_CLASS_PATH.append(path + "/shader_json")
