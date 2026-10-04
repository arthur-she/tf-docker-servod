#!/bin/bash

set -ex

FLASHROM="/usr/local/sbin/flashrom"
CBFSTOOL="/usr/local/lab-scripts/cbfstool"
PRE_CMD=""
POST_CMD=""

usage() {
    echo "Usage: $0 -d <DEVICE> -i <IMAGE> [-b <BL31>] -s <SERIAL_ID>" >&2
    exit 1
}

while getopts "d:i:b:s:" argv
do
    case $argv in
        i)
            [ -f "${OPTARG}" ] && IMAGE=${OPTARG}
            ;;
        b)
            [ -f "${OPTARG}" ] && BL31=${OPTARG}
            ;;
        s)
            SERIALID=${OPTARG}
            ;;
        d)
            DEVICE=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done

[ -z "${IMAGE}" -o -z "${SERIALID}" -o -z "${DEVICE}" ] && usage

if $(file ${IMAGE} | grep -q "gzip compressed data"); then
    IMAGE_BIN=$(dirname ${IMAGE})/${DEVICE}-${SERIALID}-fw.bin
    gunzip -c ${IMAGE} > ${IMAGE_BIN}
    IMAGE=${IMAGE_BIN}
fi

echo "Device: \"${DEVICE}\" Image: \"${IMAGE}\" BL31: \"${BL31}\" SERIALID: \"${SERIALID}\""

if [ -n "${BL31}" ]; then
    echo "Got a new BL31"
    # Replace the BL31
    ${CBFSTOOL} "${IMAGE}" remove -n fallback/bl31
    ${CBFSTOOL} "${IMAGE}" add-payload -n fallback/bl31 -f "${BL31}"
fi

# Copy the image to the container
docker cp "${IMAGE}" ${DEVICE}-servod:/
# Flash the firmware
IMAGE=$(basename ${IMAGE})
docker exec ${DEVICE}-servod ${FLASHROM} -n -w "/${IMAGE}" -p raiden_debug_spi:target=AP,serial="${SERIALID}"
# Delete the image
docker exec ${DEVICE}-servod rm /${IMAGE}

sleep 10
