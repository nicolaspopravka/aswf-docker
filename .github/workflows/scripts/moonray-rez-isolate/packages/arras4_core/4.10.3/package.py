name = "arras4_core"

version = "4.10.3"

def commands():
    path = "/opt/openmoonray"

    env.PATH.append(path + "/bin")
    env.ARRAS_SESSION_PATH.append(path + "/sessions")
