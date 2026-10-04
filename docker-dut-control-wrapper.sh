#!/bin/sh

set -x

DUT_CONTROL="/usr/local/bin/dut-control"

usage() {
    echo "Usage: $0 -d DEVICE -p PORT -c 'COMMAND'"
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

echo "Send command \"${cmd}\" to the device \"${device}\" through port ${port}"

docker exec ${device}-servod ${DUT_CONTROL} --port ${port} ${cmd}

if [ $? -ne 0 ]; then
    # If the command failed, restart the container and retry
    echo "Retry.."
    docker exec ${device}-servod /bin/bash /stop_servod.sh
    sleep 5
    /usr/bin/wait-for-it -t 120 localhost:${port}
    [ $? -eq 0 ] &&  docker exec ${device}-servod ${DUT_CONTROL} --port ${port} ${cmd}
fi
