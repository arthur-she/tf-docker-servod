#!/bin/bash

set -x

DUT_CONTROL="/usr/local/bin/dut-control"
PTS_DIR="/run/pts"
PORT_FLAG="--port ${PORT}"
DATE="`date`"

create_uart_links() {
    if [ -n "$LAVA_DEVICE" ]; then
        CPU_UART="$(${DUT_CONTROL} ${PORT_FLAG} cpu_uart_pty | awk -F':' '{print $2}')"
        [ -n "${CPU_UART}" ] && ln -fs "${CPU_UART}" "${PTS_DIR}/cpu_uart-${LAVA_DEVICE}"
        CR50_UART="$(${DUT_CONTROL} ${PORT_FLAG} cr50_uart_pty | awk -F':' '{print $2}')"
        [ -n "${CR50_UART}" ] && ln -fs "${CR50_UART}" "${PTS_DIR}/cr50_uart-${LAVA_DEVICE}"
        EC_UART="$(${DUT_CONTROL} ${PORT_FLAG} ec_uart_pty | awk -F':' '{print $2}')"
        [ -n "${EC_UART}" ] && ln -fs "${EC_UART}" "${PTS_DIR}/ec_uart-${LAVA_DEVICE}"
    fi
}

/start_servod.sh &
PID=$!

/usr/bin/wait-for-it -t 120 localhost:${PORT}
if [ $? -eq 0 ]; then
    sleep 5
    create_uart_links
    echo "Started on ${DATE}"
    wait ${PID}
else
    echo "servod launch failed"
    exit 1
fi

rm -f /servod.pid

echo "servod has been terminated on `date`!!"

