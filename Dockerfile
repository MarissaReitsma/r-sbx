# syntax=docker/dockerfile:1.7
# Builds an sbx template image: the stock Claude Code sandbox base plus a pinned R.
#
# The layer order is the whole point. install-r.sh (R + apt, the slow part) sits
# above the COPY of deps/, so editing packages.txt reruns only the dependency
# step. The BuildKit cache mount then means one added package costs one compile
# rather than recompiling the list.
#
#   DOCKER_BUILDKIT=1 docker build --build-arg MODE=packages -t r-sbx:4.6.1-base .

# Pin by digest once you have one you trust:
#   docker buildx imagetools inspect docker/sandbox-templates:claude-code
ARG BASE=docker/sandbox-templates:claude-code
FROM ${BASE}

ARG BASE
ARG R_VERSION=4.6.1
ARG SNAPSHOT=2026-08-01

USER root

ENV R_VERSION=${R_VERSION} \
    SNAPSHOT=${SNAPSHOT} \
    BASE_IMAGE=${BASE} \
    DEPS_DIR=/tmp/deps

# ---- stable half: cached unless install-r.sh or apt.txt changes --------------
COPY install-r.sh /usr/local/bin/install-r.sh
COPY deps/apt.txt /tmp/deps/apt.txt
RUN chmod 0755 /usr/local/bin/install-r.sh && /usr/local/bin/install-r.sh

# ---- volatile half: reruns on any change under deps/ -------------------------
ARG MODE=packages
COPY install-deps.sh /usr/local/bin/install-deps.sh
COPY deps/ /tmp/deps/
RUN --mount=type=cache,target=/build-cache,sharing=locked \
    chmod 0755 /usr/local/bin/install-deps.sh \
 && RENV_PATHS_CACHE=/build-cache/renv \
    R_USER_CACHE_DIR=/build-cache/rcache \
    CACHE_OUT=/opt/renv/cache \
    /usr/local/bin/install-deps.sh "${MODE}" \
 && rm -rf /tmp/deps

# Back to the user the agent runs as. Entrypoint and workdir are inherited from
# the base image — don't override them, sbx relies on both.
USER agent