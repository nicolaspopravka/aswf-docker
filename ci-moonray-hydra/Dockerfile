# syntax=docker/dockerfile:1.10
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG BASE_IMAGE=aswf/ci-moonray:2025.7@sha256:0a6fd225c6a58b673d980c5d8503bb8a35a122006b9274428911374a3bc5dead

FROM ${BASE_IMAGE} AS builder

ARG BASE_IMAGE
ARG MOONRAY_TAG=v2026.29.1
ARG MOONRAY_COMMIT=d96c6e30a8c280d4b5eb3bafa5e54efc445d7ea8
ARG BUILD_JOBS=4

USER root
RUN dnf install -y cppunit-devel git git-lfs xorg-x11-server-Xvfb && \
    dnf clean all && \
    rm -rf /var/cache/dnf

COPY --chmod=0755 ci-moonray-hydra/relocate_openusd_cmake.py /usr/local/bin/relocate_openusd_cmake.py
RUN set -o pipefail && \
    /usr/local/bin/relocate_openusd_cmake.py \
        | tee /usr/local/share/openusd-cmake-relocation.txt

ADD --checksum=sha256:164c7849653b80ae67bec4b7473b884bf5cc8d2dca05653475ec2ed27b9ebf61 \
    https://www.lua.org/ftp/lua-5.4.4.tar.gz \
    /tmp/lua-5.4.4.tar.gz
RUN mkdir -p \
        /opt/MoonRay/dependencies/lua/bin \
        /tmp/lua-source && \
    tar -xzf /tmp/lua-5.4.4.tar.gz \
        --strip-components=1 \
        -C /tmp/lua-source && \
    make -C /tmp/lua-source linux -j "${BUILD_JOBS}" && \
    install -m 0755 \
        /tmp/lua-source/src/lua \
        /tmp/lua-source/src/luac \
        /opt/MoonRay/dependencies/lua/bin/ && \
    /opt/MoonRay/dependencies/lua/bin/lua -v 2>&1 \
        | grep -F 'Lua 5.4.4' && \
    /opt/MoonRay/dependencies/lua/bin/luac -v 2>&1 \
        | grep -F 'Lua 5.4.4' && \
    rm -rf /tmp/lua-5.4.4.tar.gz /tmp/lua-source

ADD --checksum=sha256:2450dfbb4ab35dd2c9e64d8c750c514bf7293b81d8f32af7ab124417f70adfad \
    https://github.com/log4cplus/log4cplus/releases/download/REL_2_1_2/log4cplus-2.1.2.tar.bz2 \
    /tmp/log4cplus-2.1.2.tar.bz2
RUN mkdir -p /tmp/log4cplus-source && \
    tar -xjf /tmp/log4cplus-2.1.2.tar.bz2 \
        --strip-components=1 \
        -C /tmp/log4cplus-source && \
    cmake \
        -S /tmp/log4cplus-source \
        -B /tmp/log4cplus-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/MoonRay/dependencies/log4cplus \
        -DBUILD_SHARED_LIBS=ON \
        -DUNICODE=OFF \
        -DLOG4CPLUS_BUILD_TESTING=OFF \
        -DWITH_UNIT_TESTS=OFF \
        -DLOG4CPLUS_BUILD_LOGGINGSERVER=OFF \
        -DLOG4CPLUS_ENABLE_DECORATED_LIBRARY_NAME=OFF && \
    cmake --build /tmp/log4cplus-build --parallel "${BUILD_JOBS}" && \
    cmake --install /tmp/log4cplus-build && \
    ln -s lib64 /opt/MoonRay/dependencies/log4cplus/lib && \
    nm -D --defined-only \
        /opt/MoonRay/dependencies/log4cplus/lib/liblog4cplus.so \
        | c++filt \
        | grep -F \
            'log4cplus::Logger::getInstance(std::__cxx11::basic_string<char' && \
    rm -rf \
        /tmp/log4cplus-2.1.2.tar.bz2 \
        /tmp/log4cplus-build \
        /tmp/log4cplus-source

ENV LOG4CPLUS_ROOT=/opt/MoonRay/dependencies/log4cplus
ENV LD_LIBRARY_PATH=/opt/MoonRay/dependencies/log4cplus/lib:${LD_LIBRARY_PATH}

WORKDIR /opt/MoonRay/source
RUN git clone \
        --branch "${MOONRAY_TAG}" \
        --depth 1 \
        --recurse-submodules \
        --shallow-submodules \
        https://github.com/OpenMoonRay/openmoonray.git && \
    test "$(git -C openmoonray rev-parse HEAD)" = "${MOONRAY_COMMIT}" && \
    git -C openmoonray lfs pull && \
    git -C openmoonray submodule status --recursive

RUN test -x /usr/local/bin/python3.11 && \
    test -f /usr/local/lib/libpython3.11.so && \
    test -f /usr/local/include/python3.11/Python.h && \
    test -x /usr/local/cuda/bin/nvcc && \
    test -f "/usr/local/NVIDIA-OptiX-SDK-${ASWF_OPTIX_VERSION}/include/optix.h" && \
    test "${ASWF_CUDA_VERSION}" = "12.6.3" && \
    test "${ASWF_OPTIX_VERSION}" = "8.0.0" && \
    export OPTIX_ROOT="/usr/local/NVIDIA-OptiX-SDK-${ASWF_OPTIX_VERSION}" && \
    export PATH=/usr/local/cuda/bin:${PATH} && \
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH} && \
    export PYTHONPATH=/opt/MoonRay/build/moonray/scene_rdl2/mod/python/py_scene_rdl2:${PYTHONPATH} && \
    cmake \
        -S /opt/MoonRay/source/openmoonray \
        -B /opt/MoonRay/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/MoonRay/installs/openmoonray \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DCUDAToolkit_ROOT=/usr/local/cuda \
        -DLUA_BIN_LUA:FILEPATH=/opt/MoonRay/dependencies/lua/bin/lua \
        -DLUA_BIN_LUAC:FILEPATH=/opt/MoonRay/dependencies/lua/bin/luac \
        -DLog4cplus_INCLUDE_DIR:PATH=/opt/MoonRay/dependencies/log4cplus/include/log4cplus \
        -DLog4cplus_LIBRARIES:FILEPATH=/opt/MoonRay/dependencies/log4cplus/lib/liblog4cplus.so \
        -DPYTHON_EXECUTABLE=/usr/local/bin/python3 \
        -DPython3_EXECUTABLE=/usr/local/bin/python3.11 \
        -DPython3_LIBRARY=/usr/local/lib/libpython3.11.so \
        -DPython3_INCLUDE_DIR=/usr/local/include/python3.11 \
        -DBOOST_PYTHON_COMPONENT_NAME=python311 \
        -DABI_VERSION=0 \
        -DBUILD_QT_APPS=NO \
        -DMOONRAY_USE_OPTIX=ON \
        -DBUILD_MATERIALX_SHADERS=ON && \
    grep -Fx \
        'MOONRAY_USE_OPTIX:BOOL=ON' \
        /opt/MoonRay/build/CMakeCache.txt && \
    grep -F \
        '/usr/local/NVIDIA-OptiX-SDK-8.0.0/include' \
        /opt/MoonRay/build/CMakeCache.txt && \
    grep -Fx \
        'Log4cplus_LIBRARIES:FILEPATH=/opt/MoonRay/dependencies/log4cplus/lib/liblog4cplus.so' \
        /opt/MoonRay/build/CMakeCache.txt && \
    grep -Fx \
        'LUA_BIN_LUA:FILEPATH=/opt/MoonRay/dependencies/lua/bin/lua' \
        /opt/MoonRay/build/CMakeCache.txt && \
    grep -Fx \
        'LUA_BIN_LUAC:FILEPATH=/opt/MoonRay/dependencies/lua/bin/luac' \
        /opt/MoonRay/build/CMakeCache.txt && \
    cmake --build /opt/MoonRay/build --target install --parallel "${BUILD_JOBS}" && \
    test -f /opt/MoonRay/installs/openmoonray/shaders/OptixGPUPrograms.ptx && \
    mkdir -p /opt/MoonRay/installs/openmoonray/shader_json && \
    /opt/MoonRay/installs/openmoonray/bin/rdl2_json_exporter \
        --out /opt/MoonRay/installs/openmoonray/shader_json/ \
        --sparse && \
    cp -a \
        /opt/MoonRay/source/openmoonray/testdata \
        /opt/MoonRay/installs/openmoonray/testdata && \
    mkdir -p /opt/MoonRay/installs/openmoonray/share/openmoonray && \
    cp /usr/local/share/openusd-cmake-relocation.txt \
        /opt/MoonRay/installs/openmoonray/share/openmoonray/ && \
    printf '%s\n' \
        "tag=${MOONRAY_TAG}" \
        "commit=${MOONRAY_COMMIT}" \
        "base_image=${BASE_IMAGE}" \
        "build_materialx_shaders=ON" \
        "build_moonray_optix=ON" \
        "cuda_version=${ASWF_CUDA_VERSION}" \
        "optix_version=${ASWF_OPTIX_VERSION}" \
        "lua_tool_version=5.4.4" \
        "log4cplus_version=2.1.2" \
        "log4cplus_unicode=OFF" \
        > /opt/MoonRay/installs/openmoonray/share/openmoonray/provenance.txt

FROM ${BASE_IMAGE} AS runtime

ARG MOONRAY_TAG=v2026.29.1
ARG MOONRAY_COMMIT=d96c6e30a8c280d4b5eb3bafa5e54efc445d7ea8
ARG BUILD_REVISION=unknown

LABEL org.opencontainers.image.title="OpenMoonRay Hydra delegate"
LABEL org.opencontainers.image.description="OpenMoonRay Hydra delegate built against the ASWF CY2025 MoonRay dependency image"
LABEL org.opencontainers.image.source="https://github.com/nicolaspopravka/aswf-docker"
LABEL org.opencontainers.image.version="${MOONRAY_TAG}"
LABEL org.opencontainers.image.revision="${BUILD_REVISION}"
LABEL io.openmoonray.source.commit="${MOONRAY_COMMIT}"
LABEL io.openmoonray.materialx-shaders="true"
LABEL io.openmoonray.optix="true"

USER root
RUN dnf install -y mesa-dri-drivers xorg-x11-server-Xvfb && \
    dnf clean all && \
    rm -rf /var/cache/dnf

COPY --chmod=0755 ci-moonray-hydra/relocate_openusd_cmake.py /usr/local/bin/relocate_openusd_cmake.py
RUN set -o pipefail && \
    /usr/local/bin/relocate_openusd_cmake.py \
        | tee /usr/local/share/openusd-cmake-relocation.txt

COPY --from=builder /opt/MoonRay/installs/openmoonray /opt/MoonRay/installs/openmoonray
COPY --from=builder /opt/MoonRay/dependencies/log4cplus /opt/MoonRay/dependencies/log4cplus

RUN ln -s /opt/MoonRay/installs/openmoonray /opt/openmoonray

ENV LOG4CPLUS_ROOT=/opt/MoonRay/dependencies/log4cplus
ENV MOONRAY_ROOT=/opt/MoonRay/installs/openmoonray
ENV RDL2_DSO_PATH=/opt/MoonRay/installs/openmoonray/rdl2dso.proxy:/opt/MoonRay/installs/openmoonray/rdl2dso
ENV MOONRAY_CLASS_PATH=/opt/MoonRay/installs/openmoonray/shader_json
ENV ARRAS_SESSION_PATH=/opt/MoonRay/installs/openmoonray/sessions
ENV REZ_MOONRAY_ROOT=/opt/MoonRay/installs/openmoonray
ENV PATH=/opt/MoonRay/installs/openmoonray/bin:${PATH}
ENV PYTHONPATH=/opt/MoonRay/installs/openmoonray/python/lib/python3.11:/usr/local/lib/python:${PYTHONPATH}
ENV PXR_PLUGINPATH_NAME=/opt/MoonRay/installs/openmoonray/plugin/pxr
ENV PXR_PLUGIN_PATH=/opt/MoonRay/installs/openmoonray/plugin/pxr
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/opt/MoonRay/dependencies/log4cplus/lib:/opt/MoonRay/installs/openmoonray/lib:/opt/MoonRay/installs/openmoonray/lib64:${LD_LIBRARY_PATH}
ENV HDMOONRAY_DEBUG_MODE=1

WORKDIR /work
CMD ["/bin/bash"]
