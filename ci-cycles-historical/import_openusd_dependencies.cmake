# OpenUSD's exported garch target references OpenGL::GL. Ensure that imported
# target exists before Cycles loads pxrTargets.cmake. This changes neither
# Cycles nor OpenUSD source and remains harmless for releases that rediscover it.
find_package(OpenGL REQUIRED)
