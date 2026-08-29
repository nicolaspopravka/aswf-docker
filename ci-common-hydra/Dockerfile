# syntax=docker/dockerfile:1.10

ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS cycles-dependencies
ARG CYCLES_LIB_REVISION
COPY ci-common-hydra/build_cycles_dependencies.sh /usr/local/bin/build_cycles_dependencies.sh
RUN chmod +x /usr/local/bin/build_cycles_dependencies.sh && \
    /usr/local/bin/build_cycles_dependencies.sh

FROM ${BASE_IMAGE} AS builder
ARG CYCLES_TAG
ARG CYCLES_REVISION
ARG CYCLES_LIB_REVISION
COPY --from=cycles-dependencies /opt/cycles-dependencies /opt/cycles-dependencies
COPY ci-cycles-historical/import_openusd_dependencies.cmake /usr/local/share/cycles/import_openusd_dependencies.cmake
COPY ci-common-hydra/build_cycles_common.sh /usr/local/bin/build_cycles_common.sh
RUN chmod +x /usr/local/bin/build_cycles_common.sh && \
    /usr/local/bin/build_cycles_common.sh

FROM ${BASE_IMAGE} AS embree-builder
ARG EMBREE_TAG
ARG EMBREE_REVISION
ARG EMBREE_TARBALL_SHA256
ARG OPENUSD_TAG
ARG OPENUSD_REVISION
COPY ci-embree/build_embree.sh /usr/local/bin/build_embree.sh
RUN chmod +x /usr/local/bin/build_embree.sh && \
    /usr/local/bin/build_embree.sh
COPY ci-embree/build_hdembree.sh /usr/local/bin/build_hdembree.sh
COPY ci-embree/hdembree-consumer/ /usr/local/share/hdembree-consumer/
RUN chmod +x /usr/local/bin/build_hdembree.sh && \
    /usr/local/bin/build_hdembree.sh

FROM ${BASE_IMAGE} AS runtime
ARG ASWF_SOURCE_REVISION
ARG CYCLES_TAG
ARG CYCLES_REVISION
ARG CYCLES_LIB_REVISION
ARG EMBREE_TAG
ARG EMBREE_REVISION
ARG OPENUSD_TAG
ARG OPENUSD_REVISION
ARG WORKFLOW_REVISION
COPY --from=cycles-dependencies /opt/cycles-dependency-evidence /opt/cycles-dependency-evidence
COPY --from=builder /opt/cycles /opt/cycles
COPY --from=builder /opt/cycles-build-evidence /opt/cycles-build-evidence
COPY --from=embree-builder /opt/embree /opt/embree
COPY --from=embree-builder /opt/hdembree /opt/hdembree
COPY --from=embree-builder /opt/embree-build-evidence /opt/embree-build-evidence
COPY --from=embree-builder /opt/hdembree-build-evidence /opt/hdembree-build-evidence
COPY ci-common-hydra/common-hydra-env /usr/local/bin/common-hydra-env
RUN chmod +x /usr/local/bin/common-hydra-env && \
    dnf install -y mesa-dri-drivers mesa-libGL mesa-libEGL glx-utils xorg-x11-server-Xvfb && \
    dnf clean all
ENV PXR_PLUGINPATH_NAME="" \
    PXR_PLUGIN_PATH="" \
    RDL2_DSO_PATH="" \
    MOONRAY_CLASS_PATH="" \
    ARRAS_SESSION_PATH="" \
    MOONRAY_ROOT="" \
    REZ_MOONRAY_ROOT="" \
    LOG4CPLUS_ROOT="" \
    LD_LIBRARY_PATH="" \
    HDMOONRAY_DEBUG_MODE="" \
    PYTHONPATH=/usr/local/lib/python \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LABEL org.opencontainers.image.source="https://github.com/nicolaspopravka/aswf-docker"
LABEL org.opencontainers.image.title="Common Hydra stack (Storm + MoonRay + Cycles + Embree) for the USD Render Benchmark"
LABEL org.opencontainers.image.description="Single-OpenUSD common image: OpenUSD 25.05.01 (hdStorm), OpenMoonRay 2026.29.1 (hdMoonray), Cycles ${CYCLES_TAG} (hdCycles, CPU/Embree), Embree ${EMBREE_TAG} (hdEmbree, CPU)"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${WORKFLOW_REVISION}"
LABEL io.usd-render-benchmark.aswf-source-revision="${ASWF_SOURCE_REVISION}"
LABEL io.usd-render-benchmark.cycles-revision="${CYCLES_REVISION}"
LABEL io.usd-render-benchmark.cycles-libraries-revision="${CYCLES_LIB_REVISION}"
LABEL io.usd-render-benchmark.embree-revision="${EMBREE_REVISION}"
LABEL io.usd-render-benchmark.openusd-revision="${OPENUSD_REVISION}"
