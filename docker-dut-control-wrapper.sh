#!/bin/sh
# Run dut-control against a DUT through its <DEVICE>-servod container. Called
# from LAVA jobs.
#
# A failed command is retried once as-is. If that also fails, the servod
# container is assumed glitched: it is restarted and the command retried, up
# to SERVOD_MAX_RESTARTS times (default 2). A restart re-creates the DUT UART
# ptys, so any console already open on the old pty (e.g. LAVA's) is lost.

set -x

DUT_CONTROL="/usr/local/bin/dut-control"
WAIT_FOR_IT="/usr/bin/wait-for-it"
MAX_RESTARTS="${SERVOD_MAX_RESTARTS:-2}"

usage() {
    echo "Usage: $0 -d DEVICE -p PORT -c 'COMMAND'" >&2
    exit 1
}

while getopts "c:d:p:" argv
do
    case $argv in
        p)
            port=$OPTARG
            ;;
        d)
            device=$OPTARG
            ;;
        c)
            cmd=$OPTARG
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "${port}" -o -z "${device}" -o -z "${cmd}" ]; then
    usage
fi

container="${device}-servod"

# ${cmd} may hold several space-separated controls, so it is word-split on
# purpose; disable globbing so '*' or '?' in it reach dut-control as-is.
set -f

run_cmd() {
    docker exec "${container}" ${DUT_CONTROL} --port "${port}" ${cmd}
}

# Restart the container and wait until servod is up again. Waits from inside
# the container so the host needs no wait-for-it, then gives post_servod.sh
# time to finish: it sleeps 5s after the port opens before linking the UART
# ptys.
#
# servod registers the devices it serves under /run/servoscratch, which
# survives a container restart. servod drops a leftover entry only once it
# can bind the old port, which fails while that port still has TIME_WAIT
# connections from recent dut-control calls, and it then refuses to start
# ("already served by another servod instance"). Clear the entries first.
restart_servod() {
    echo "WARNING: restarting ${container}; DUT UART ptys will be re-created" >&2
    docker exec "${container}" find /run/servoscratch -maxdepth 1 ! -type d -delete
    docker restart "${container}" || return 1
    docker exec "${container}" ${WAIT_FOR_IT} -t 120 "localhost:${port}" || return 1
    sleep 10
}

echo "Send command \"${cmd}\" to the device \"${device}\" through port ${port}"

run_cmd && exit 0

echo "Retry.."
sleep 2
run_cmd && exit 0

restarts=0
while [ "${restarts}" -lt "${MAX_RESTARTS}" ]; do
    restarts=$((restarts + 1))
    echo "Command failed, restarting servod and retrying (${restarts}/${MAX_RESTARTS})"
    if restart_servod; then
        run_cmd && exit 0
    else
        echo "servod restart failed" >&2
    fi
done

echo "error: \"${cmd}\" failed after ${MAX_RESTARTS} servod restarts" >&2
exit 1
