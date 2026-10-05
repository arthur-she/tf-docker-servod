#!/bin/bash
# Container entrypoint. Launches servod via the base image's /start_servod.sh,
# waits for it to accept connections, then publishes the DUT UART pty paths
# under /run/pts/ so the LAVA worker can reach them by a stable name.

set -x

DUT_CONTROL="/usr/local/bin/dut-control"
PTS_DIR="/run/pts"
PORT="${PORT:-9999}"
PORT_FLAG="--port ${PORT}"

create_uart_links() {
    [ -n "${LAVA_DEVICE}" ] || return 0
    local name uart
    for name in cpu cr50 ec; do
        uart="$(${DUT_CONTROL} ${PORT_FLAG} "${name}_uart_pty" | awk -F':' '{print $2}')"
        [ -n "${uart}" ] && ln -fs "${uart}" "${PTS_DIR}/${name}_uart-${LAVA_DEVICE}"
    done
}

# servod registers the devices it serves under /run/servoscratch, which lives
# in the container filesystem and so survives a container restart. No servod
# runs in this container yet, so any entry there is stale. servod itself only
# drops one once it can bind the old port, which fails while that port has
# TIME_WAIT connections, and it then refuses to start ("already served by
# another servod instance").
find /run/servoscratch -maxdepth 1 ! -type d -delete 2>/dev/null

/start_servod.sh &
PID=$!
trap 'kill -TERM "${PID}" 2>/dev/null' INT TERM

if /usr/bin/wait-for-it -t 120 "localhost:${PORT}"; then
    sleep 5
    create_uart_links
    echo "servod started on $(date)"
    wait "${PID}"
else
    echo "servod launch failed"
    kill -TERM "${PID}" 2>/dev/null
    exit 1
fi

echo "servod terminated on $(date)"
