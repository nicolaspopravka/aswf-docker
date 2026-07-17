# Copyright (c) Contributors to the conan-center-index Project. All rights reserved.
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: MIT
#
# From: https://github.com/conan-io/conan-center-index/blob/2a3cb93885141024c1b405a01a79fb3abc239b12/recipes/materialx/all/test_package/conanfile.py

from conan import ConanFile
from conan.tools.build import can_run
from conan.tools.cmake import cmake_layout, CMake
import os

class TestMaterialXConan(ConanFile):
    settings = "os", "arch", "compiler", "build_type"
    generators = "CMakeDeps", "CMakeToolchain", "VirtualRunEnv"
    test_type = "explicit"

    def requirements(self):
        self.requires(self.tested_reference_str)

    def layout(self):
        cmake_layout(self)

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def test(self):
        if can_run(self):
            bin_path = os.path.join(self.cpp.build.bindir, "test_package")
            self.run(bin_path, env="conanrun")
            if os.getenv("DIAGNOSTIC_SKIP_MATERIALX_PYTHON_TEST") != "1":
                self.run(
                    'python3 -c "import MaterialX as mx; print(mx.getVersionString())"',
                    env="conanrun",
                )
            self.run(
                "python3 -c \"import os; p = os.environ['PXR_MTLX_STDLIB_SEARCH_PATHS']; "
                "assert os.path.isfile(os.path.join(p, 'libraries', 'bxdf', "
                "'standard_surface.mtlx')); print(p)\"",
                env="conanrun",
            )
