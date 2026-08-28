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

FROM ${BASE_IMAGE} AS runtime
ARG ASWF_SOURCE_REVISION
ARG CYCLES_TAG
ARG CYCLES_REVISION
ARG CYCLES_LIB_REVISION
ARG WORKFLOW_REVISION
COPY --from=builder /opt/cycles /opt/cycles
COPY --from=builder /opt/cycles-build-evidence /opt/cycles-build-evidence
COPY ci-common-hydra/common-hydra-env /usr/local/bin/common-hydra-env
RUN chmod +x /usr/local/bin/common-hydra-env && \
    dnf install -y mesa-dri-drivers mesa-libGL mesa-libEGL glx-utils xorg-x11-server-Xvfb && \
    dnf clean all
ENV PYTHONPATH=/usr/local/lib/python
ENV PATH=/usr/local/bin:/opt/cycles:${PATH}
LABEL org.opencontainers.image.source="https://github.com/nicolaspopravka/aswf-docker"
LABEL org.opencontainers.image.title="Common Hydra stack (Storm + MoonRay + Cycles) for the USD Render Benchmark"
LABEL org.opencontainers.image.description="Single-OpenUSD common image: OpenUSD 25.05.01 (hdStorm), OpenMoonRay 2026.29.1 (hdMoonray), Cycles ${CYCLES_TAG} (hdCycles, CPU/Embree)"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${WORKFLOW_REVISION}"
LABEL io.usd-render-benchmark.aswf-source-revision="${ASWF_SOURCE_REVISION}"
LABEL io.usd-render-benchmark.cycles-revision="${CYCLES_REVISION}"
LABEL io.usd-render-benchmark.cycles-libraries-revision="${CYCLES_LIB_REVISION}"
