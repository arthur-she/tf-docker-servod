# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

ARG RELEASE_TYPE=latest

# Build flashrom from a pinned ChromiumOS commit; copied into the servod image
# below in place of the stock flashrom.
#
# The pin must include 794ac5ef ("raiden_debug_spi: Check serial before
# claiming USB device"). Older raiden_debug_spi claims each Ti50's interface
# before checking its serial and resets a Ti50 it finds busy, so with several
# DUTs on one host, flashing one could reset another's Ti50 mid-flash. The
# servod base image's flashrom predates that fix.
FROM debian:trixie AS flashrom-builder

ARG FLASHROM_REF=fa2aff4ccada95422289ab767cae0ab5c97a39b8
ARG FLASHROM_SERIAL_FIX=794ac5ef12fca0aaed32a0c1c41fd583121f45af

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        gcc \
        meson \
        ninja-build \
        pkg-config \
        python3 \
        libpci-dev \
        libusb-1.0-0-dev \
        libftdi1-dev \
        libjaylink-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
        https://chromium.googlesource.com/chromiumos/third_party/flashrom \
        /src/flashrom \
    && git -C /src/flashrom checkout --detach "${FLASHROM_REF}" \
    && git -C /src/flashrom merge-base --is-ancestor \
        "${FLASHROM_SERIAL_FIX}" HEAD

WORKDIR /src/flashrom

RUN meson setup build \
    --prefix=/usr/local \
    && meson compile -C build


FROM us-docker.pkg.dev/chromeos-hw-tools/servod/servod:${RELEASE_TYPE}

RUN apt-get update --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bzip2 \
        curl \
        fdisk \
        vim \
        file \
        bash-completion \
        net-tools \
        tzdata \
        wait-for-it \
        libjaylink0 \
        libftdi1-2 \
        libusb-1.0-0 \
        libpci3

# Avoid watchtower updating servod, it gets pulled before every start of the
# container, we should not stop/start it in the case a new version is pushed.
LABEL com.centurylinklabs.watchtower.enable="false"

# Try to remove as much as possible to make the container smaller
RUN apt-get autoclean \
    && rm -rf /var/lib/apt/lists/*

# Replace the flashrom supplied by the servod image with the pinned build.
COPY --from=flashrom-builder \
    /src/flashrom/build/flashrom \
    /usr/local/sbin/flashrom

# The base image's /start_servod.sh launches `servod ... --log-dir /var/log`.
# Retarget it to /var/log/servod so servod's logs land on the host-mounted
# volume declared in docker-compose.yaml.
RUN mkdir -p /var/log/servod \
    && sed -i 's#--log-dir /var/log"#--log-dir /var/log/servod"#' /start_servod.sh

# Make the upstream gRPC ports configurable per container (GRPC_DATA_PORT /
# GRPC_CORE_PORT). With network_mode: host every container shares the host's
# ports, so more than one servod per host needs a distinct pair each. Fail the
# build if upstream changes the hardcoded ports and the substitution misses.
RUN sed -i '/^set -x/a GRPC_DATA_PORT=${GRPC_DATA_PORT:-50051}\nGRPC_CORE_PORT=${GRPC_CORE_PORT:-50052}' /start_servod.sh \
    && sed -i 's/--grpc-core-port 50052/--grpc-core-port ${GRPC_CORE_PORT}/g' /start_servod.sh \
    && sed -i 's/--grpc-data-port 50051/--grpc-data-port ${GRPC_DATA_PORT}/g' /start_servod.sh \
    && ! grep -qE -- '--grpc-(core|data)-port 5005[12]' /start_servod.sh \
    && grep -q -- '--grpc-core-port ${GRPC_CORE_PORT}' /start_servod.sh \
    && grep -q -- '--grpc-data-port ${GRPC_DATA_PORT}' /start_servod.sh

COPY post_servod.sh /post_servod.sh
