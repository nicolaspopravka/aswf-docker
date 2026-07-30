# syntax=docker/dockerfile:1.10

ARG DEPENDENCY_IMAGE
FROM ${DEPENDENCY_IMAGE} AS builder

ARG CYCLES_REVISION
ARG CYCLES_TAG
ARG CYCLES_LIB_REVISION

COPY ci-cycles/build_cycles.sh /usr/local/bin/build_cycles.sh

RUN chmod +x /usr/local/bin/build_cycles.sh && \
    /usr/local/bin/build_cycles.sh

FROM ${DEPENDENCY_IMAGE} AS runtime

ARG ASWF_SOURCE_REVISION
ARG CYCLES_REVISION
ARG CYCLES_TAG
ARG OPENUSD_REVISION
ARG OPENUSD_TAG
ARG WORKFLOW_REVISION

COPY --from=builder /opt/usd /opt/usd
COPY --from=builder /opt/cycles /opt/cycles
COPY --from=builder /opt/cycles-build-evidence /opt/cycles-build-evidence

ENV PATH=/opt/usd/bin:/opt/cycles:${PATH}
ENV PYTHONPATH=/opt/usd/lib/python:${PYTHONPATH}
ENV PXR_PLUGINPATH_NAME=/opt/cycles/hydra
ENV LD_LIBRARY_PATH=/opt/cycles/lib:/opt/cycles-dependencies/lib:/opt/usd/lib:/opt/usd/lib64:${LD_LIBRARY_PATH}

LABEL org.opencontainers.image.source="https://github.com/nicolaspopravka/aswf-docker"
LABEL org.opencontainers.image.title="Cycles Hydra delegate for USD Render Benchmark"
LABEL org.opencontainers.image.description="Cycles ${CYCLES_TAG} Hydra delegate built against OpenUSD ${OPENUSD_TAG} on the ASWF CY2026 stack"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${WORKFLOW_REVISION}"
LABEL io.usd-render-benchmark.aswf-source-revision="${ASWF_SOURCE_REVISION}"
LABEL io.usd-render-benchmark.cycles-revision="${CYCLES_REVISION}"
LABEL io.usd-render-benchmark.openusd-revision="${OPENUSD_REVISION}"
