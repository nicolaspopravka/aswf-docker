# syntax=docker/dockerfile:1.10

ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS builder
ARG EMBREE_TAG
ARG EMBREE_REVISION
ARG EMBREE_TARBALL_SHA256
ARG OPENUSD_TAG
ARG OPENUSD_REVISION
COPY ci-embree/build_embree.sh /usr/local/bin/build_embree.sh
RUN chmod +x /usr/local/bin/build_embree.sh && \
    /usr/local/bin/build_embree.sh
# Separate layers: Embree (slow, stable) caches; consumer iterations
# (hdEmbree build) only re-run the last stage of this step sequence.
COPY ci-embree/build_hdembree.sh /usr/local/bin/build_hdembree.sh
COPY ci-embree/hdembree-consumer/ /usr/local/share/hdembree-consumer/
RUN chmod +x /usr/local/bin/build_hdembree.sh && \
    /usr/local/bin/build_hdembree.sh

FROM ${BASE_IMAGE} AS runtime
ARG ASWF_SOURCE_REVISION
ARG EMBREE_TAG
ARG EMBREE_REVISION
ARG OPENUSD_TAG
ARG OPENUSD_REVISION
ARG WORKFLOW_REVISION
COPY --from=builder /opt/embree /opt/embree
COPY --from=builder /opt/hdembree /opt/hdembree
COPY --from=builder /opt/embree-build-evidence /opt/embree-build-evidence
COPY --from=builder /opt/hdembree-build-evidence /opt/hdembree-build-evidence
RUN dnf clean all
# Delegate-only image: the plugin tree is on the default plugin path so a
# plain docker run enumerates Storm + Embree.  PYTHONPATH is intentionally
# NOT baked (the base image does not set it; the run harness's usd Rez
# package owns it, matching the field-tested *-only image pattern).
# LD_LIBRARY_PATH must NOT be overridden: the base image bakes
# /usr/local/lib into it and the conan-built pxr libraries resolve their
# dependency chain through it (the ldconfig cache predates the conan
# deploy -- GHA run 33251354330 died on libblosc.so.1 after this ENV
# clobbered the inherited value).  hdEmbree.so carries its own RUNPATH to
# /opt/embree/lib, so Embree needs no entry here either.
ENV PXR_PLUGINPATH_NAME=/opt/hdembree/hydra
LABEL org.opencontainers.image.source="https://github.com/nicolaspopravka/aswf-docker"
LABEL org.opencontainers.image.title="hdEmbree delegate for the USD Render Benchmark"
LABEL org.opencontainers.image.description="ASWF prebuilt OpenUSD ${OPENUSD_TAG} with hdEmbree (Embree ${EMBREE_TAG}, CPU render delegate) as an external pxr consumer"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${WORKFLOW_REVISION}"
LABEL io.usd-render-benchmark.aswf-source-revision="${ASWF_SOURCE_REVISION}"
LABEL io.usd-render-benchmark.embree-revision="${EMBREE_REVISION}"
LABEL io.usd-render-benchmark.openusd-revision="${OPENUSD_REVISION}"
