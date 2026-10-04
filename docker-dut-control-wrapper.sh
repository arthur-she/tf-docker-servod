#!/bin/sh
# Run dut-control against a DUT through its <DEVICE>-servod container. Called
# from LAVA jobs.
#
# A failed command is retried once as-is. Only if that also fails is servod
# treated as wedged: the container is restarted and the command tried a last
# time. A restart re-creates the DUT UART ptys, so any console already open
# on the old pty (e.g. LAVA's) is lost.

set -x

DUT_CONTROL="/usr/local/bin/dut-control"
WAIT_FOR_IT="/usr/bin/wait-for-it"

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

echo "Send command \"${cmd}\" to the device \"${device}\" through port ${port}"

run_cmd && exit 0

echo "Retry.."
sleep 2
run_cmd && exit 0

echo "WARNING: restarting ${container}; DUT UART ptys will be re-created" >&2
docker restart "${container}" || exit 1
# Wait from inside the container so the host needs no wait-for-it. Then give
# post_servod.sh time to finish: it sleeps 5s after the port opens before
# linking the UART ptys.
docker exec "${container}" ${WAIT_FOR_IT} -t 120 "localhost:${port}" || exit 1
sleep 10
run_cmd
