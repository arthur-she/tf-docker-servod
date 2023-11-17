# Copyright 2021 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

#!/bin/bash

set -x

if [ -f "/servod.pid" ]; then
    servod_pid=$(cat /servod.pid)
    if $(kill -0 ${servod_pid}); then
        dut-control -p $PORT "log_msg:Turning down servod."
        
        for CMD in iptables-legacy ip6tables-legacy ; do
            $CMD -D INPUT -p tcp --dport $PORT -j ACCEPT || true
        done
        rm -f /servod.pid
        kill -HUP ${servod_pid}
    fi
fi
