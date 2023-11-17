# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

ARG RELEASE_TYPE=latest

FROM us-docker.pkg.dev/chromeos-hw-tools/servod/servod:${RELEASE_TYPE}

RUN apt-get update --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bzip2 \
        curl \
        fdisk \
        python-is-python3 \
        vim \
        file \
        bash-completion \
        net-tools \
        tzdata \
        wait-for-it

# Avoid watchtower updating servod, it gets pulled before every start of the
# container, we should not stop/start it in the case a new version is pushed.
LABEL com.centurylinklabs.watchtower.enable="false"

# Try to remove as much as possible to make the container smaller
RUN apt-get autoclean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/bin/futility /usr/bin/gbb_utility

# Add --log-dir parameter to servod
RUN sed -i '$ s/$/ \\/' /start_servod.sh; \
    echo "    --log-dir /var/log/servod &" >> /start_servod.sh; \
    echo "echo \$! > /servod.pid" >> /start_servod.sh; \
    echo "\nwait \$(cat /servod.pid)" >> /start_servod.sh

COPY post_servod.sh /post_servod.sh
COPY stop_servod.sh /stop_servod.sh
