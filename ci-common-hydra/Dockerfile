# syntax=docker/dockerfile:1.10
# Copyright (c) Contributors to the aswf-docker Project. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

ARG MOONRAY_IMAGE

FROM ${MOONRAY_IMAGE} AS cycles-builder
ARG CYCLES_TAG
ARG CYCLES_REVISION
ARG NANOVDB_TAG
ARG NANOVDB_REVISION
COPY --chmod=0755 ci-common-hydra/build_cycles.sh /usr/local/bin/build_cycles.sh
COPY ci-common-hydra/cycles_project_include.cmake /usr/local/share/cycles_project_include.cmake
RUN /usr/local/bin/build_cycles.sh

FROM ${MOONRAY_IMAGE} AS runtime
ARG CYCLES_TAG
ARG CYCLES_REVISION
ARG MOONRAY_COMMIT
ARG REZ_VERSION
ARG WORKFLOW_REVISION

USER root
COPY --from=cycles-builder /opt/cycles /opt/cycles
COPY --from=cycles-builder /opt/cycles-build-evidence /opt/cycles-build-evidence

RUN dnf install -y libepoxy time && \
    dnf clean all && \
    rm -rf /var/cache/dnf && \
    python3 -m pip install --no-cache-dir "rez==${REZ_VERSION}" && \
    rez --version | grep -F "${REZ_VERSION}" && \
    test -x /usr/bin/time

# Delegate paths are supplied by the benchmark's split Rez packages. Clear the
# MoonRay base image's process-wide delegate settings; each Rez package then
# owns only the paths needed by its component.
ENV LOG4CPLUS_ROOT="" \
    MOONRAY_ROOT="" \
    RDL2_DSO_PATH="" \
    MOONRAY_CLASS_PATH="" \
    ARRAS_SESSION_PATH="" \
    REZ_MOONRAY_ROOT="" \
    PXR_PLUGINPATH_NAME="" \
    PXR_PLUGIN_PATH="" \
    LD_LIBRARY_PATH="" \
    HDMOONRAY_DEBUG_MODE="" \
    PYTHONPATH=/usr/local/lib/python \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LABEL org.opencontainers.image.source="https://github.com/nicolaspopravka/aswf-docker"
LABEL org.opencontainers.image.title="USD Render Benchmark common Hydra image"
LABEL org.opencontainers.image.description="Storm, OpenMoonRay and Cycles on one OpenUSD 25.05.01 runtime"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${WORKFLOW_REVISION}"
LABEL io.usd-render-benchmark.openusd-version="25.05.01"
LABEL io.usd-render-benchmark.moonray-revision="${MOONRAY_COMMIT}"
LABEL io.usd-render-benchmark.cycles-version="${CYCLES_TAG}"
LABEL io.usd-render-benchmark.cycles-revision="${CYCLES_REVISION}"
LABEL io.usd-render-benchmark.rez-version="${REZ_VERSION}"
LABEL io.usd-render-benchmark.gpu-runtime-validation="not-run"

WORKDIR /workspace
CMD ["/bin/bash"]
