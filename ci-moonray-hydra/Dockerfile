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

COPY ci-moonray-hydra/relocate_openusd_cmake.py /usr/local/bin/relocate_openusd_cmake.py
RUN /usr/local/bin/relocate_openusd_cmake.py \
    | tee /usr/local/share/openusd-cmake-relocation.txt

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
    cmake \
        -S /opt/MoonRay/source/openmoonray \
        -B /opt/MoonRay/build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/MoonRay/installs/openmoonray \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DPYTHON_EXECUTABLE=/usr/local/bin/python3 \
        -DPython3_EXECUTABLE=/usr/local/bin/python3.11 \
        -DPython3_LIBRARY=/usr/local/lib/libpython3.11.so \
        -DPython3_INCLUDE_DIR=/usr/local/include/python3.11 \
        -DBOOST_PYTHON_COMPONENT_NAME=python311 \
        -DABI_VERSION=0 \
        -DBUILD_QT_APPS=NO \
        -DMOONRAY_USE_OPTIX=NO \
        -DBUILD_MATERIALX_SHADERS=ON && \
    cmake --build /opt/MoonRay/build --target install --parallel "${BUILD_JOBS}" && \
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

USER root
RUN dnf install -y xorg-x11-server-Xvfb && \
    dnf clean all && \
    rm -rf /var/cache/dnf

COPY ci-moonray-hydra/relocate_openusd_cmake.py /usr/local/bin/relocate_openusd_cmake.py
RUN /usr/local/bin/relocate_openusd_cmake.py \
    | tee /usr/local/share/openusd-cmake-relocation.txt

COPY --from=builder /opt/MoonRay/installs/openmoonray /opt/MoonRay/installs/openmoonray

RUN ln -s /opt/MoonRay/installs/openmoonray /opt/openmoonray

ENV MOONRAY_ROOT=/opt/MoonRay/installs/openmoonray
ENV RDL2_DSO_PATH=/opt/MoonRay/installs/openmoonray/rdl2dso.proxy:/opt/MoonRay/installs/openmoonray/rdl2dso
ENV MOONRAY_CLASS_PATH=/opt/MoonRay/installs/openmoonray/shader_json
ENV ARRAS_SESSION_PATH=/opt/MoonRay/installs/openmoonray/sessions/hdMoonray
ENV REZ_MOONRAY_ROOT=/opt/MoonRay/installs/openmoonray
ENV PATH=/opt/MoonRay/installs/openmoonray/bin:${PATH}
ENV PXR_PLUGINPATH_NAME=/opt/MoonRay/installs/openmoonray/plugin/pxr
ENV PXR_PLUGIN_PATH=/opt/MoonRay/installs/openmoonray/plugin/pxr
ENV LD_LIBRARY_PATH=/opt/MoonRay/installs/openmoonray/lib:/opt/MoonRay/installs/openmoonray/lib64:${LD_LIBRARY_PATH}
ENV HDMOONRAY_DEBUG_MODE=1

WORKDIR /work
CMD ["/bin/bash"]
