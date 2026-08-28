# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# OpenUSD 25.05 exports garch with an OpenGL::GL link dependency. Cycles 5.0.0
# loads pxrConfig.cmake before its normal OpenGL discovery, so provide the
# imported target before the released Cycles sources inspect OpenUSD.
find_package(OpenGL REQUIRED)
