# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: MIT

import os
from conan import ConanFile
from conan.tools.build import check_min_cppstd
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout
from conan.tools.files import copy, get, rm, rmdir

required_conan_version = ">=2.0.9"


class CyclesConan(ConanFile):
    name = "cycles"
    description = "Cycles renderer — a GPU and CPU production render engine."
    license = "GPL-2.0-or-later"
    url = "https://github.com/nicolaspopravka/aswf-docker"
    homepage = "https://projects.blender.org/blender/cycles"
    topics = ("rendering", "vfx", "hydra", "gpu")
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
    }
    default_options = {
        "shared": True,
        "fPIC": True,
    }
    implements = ["auto_shared_fpic"]

    @property
    def _min_cppstd(self):
        return 17

    def export_sources(self):
        pass

    def layout(self):
        cmake_layout(self, src_folder="src")

    def requirements(self):
        self.requires("openusd/26.03")
        self.requires("embree/4.2.0")
        self.requires("onetbb/2021.12.0")

    def build_requirements(self):
        self.tool_requires("cmake/[>=3.16 <4]")

    def validate(self):
        if self.settings.compiler.cppstd:
            check_min_cppstd(self, self._min_cppstd)

    def source(self):
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    def generate(self):
        tc = CMakeToolchain(self)
        # Cycles builds against a pre-installed USD
        usd_info = self.dependencies["openusd"]
        tc.variables["PXR_ROOT"] = usd_info.package_folder
        tc.variables["CMAKE_INSTALL_PREFIX"] = self.package_folder
        tc.generate()
        CMakeDeps(self).generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        copy(self, "LICENSE", src=self.source_folder,
             dst=os.path.join(self.package_folder, "licenses", self.name))
        cmake = CMake(self)
        cmake.install()
        # Keep cmake files for non-Conan consumers
        rmdir(self, os.path.join(self.package_folder, "lib", "cmake"))
        rm(self, "*.la", self.package_folder)

    def package_info(self):
        self.cpp_info.libs = ["hdCycles"]
        self.cpp_info.includedirs = []
        if self.settings.os in ["Linux", "FreeBSD"]:
            self.cpp_info.system_libs.extend(["dl", "m", "pthread"])
