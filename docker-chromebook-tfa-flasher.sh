#!/bin/bash
# Flash an AP firmware image onto a DUT through its <DEVICE>-servod container,
# optionally replacing the image's BL31 first. Called from LAVA jobs.
#
# The servo serial is read from the container's SERIAL env. -s is still
# accepted for existing job definitions, and must match it.

set -ex

FLASHROM="/usr/local/sbin/flashrom"
CBFSTOOL="/usr/local/lab-scripts/cbfstool"

usage() {
    echo "Usage: $0 -d <DEVICE> -i <IMAGE> [-b <BL31>] [-s <SERIAL_ID>]" >&2
    exit 1
}

die() {
    echo "error: $*" >&2
    exit 1
}

while getopts "d:i:b:s:" argv
do
    case $argv in
        i)
            IMAGE=${OPTARG}
            ;;
        b)
            # BL31 is optional (e.g. health-check firmware has none). Device
            # templates always pass -b {BL31}, and LAVA leaves the
            # placeholder as-is when the job defines no bl31 image.
            case ${OPTARG} in
                ""|"{"*"}") ;;
                *) BL31=${OPTARG} ;;
            esac
            ;;
        s)
            SERIALID_ARG=${OPTARG}
            ;;
        d)
            DEVICE=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done

[ -z "${IMAGE}" -o -z "${DEVICE}" ] && usage
[ -f "${IMAGE}" ] || die "image not found: ${IMAGE}"
[ -z "${BL31}" -o -f "${BL31}" ] || die "BL31 not found: ${BL31}"

CONTAINER="${DEVICE}-servod"
SERIALID=$(docker exec "${CONTAINER}" printenv SERIAL) \
    || die "cannot read SERIAL from container ${CONTAINER}"
[ -n "${SERIALID}" ] || die "SERIAL is empty in container ${CONTAINER}"
if [ -n "${SERIALID_ARG}" -a "${SERIALID_ARG}" != "${SERIALID}" ]; then
    die "-s ${SERIALID_ARG} does not match ${CONTAINER} SERIAL=${SERIALID}"
fi

# Work on a private copy so the caller's image is never modified, and clean
# up both the host copy and the one pushed into the container on any exit.
WORKDIR=$(mktemp -d)
IMAGE_BIN="${WORKDIR}/${DEVICE}-${SERIALID}-fw.bin"
CONTAINER_IMAGE="/$(basename "${IMAGE_BIN}")"
cleanup() {
    rm -rf "${WORKDIR}"
    if [ -n "${COPIED}" ]; then
        docker exec "${CONTAINER}" rm -f "${CONTAINER_IMAGE}" || true
    fi
}
trap cleanup EXIT

if file "${IMAGE}" | grep -q "gzip compressed data"; then
    gunzip -c "${IMAGE}" > "${IMAGE_BIN}"
else
    cp "${IMAGE}" "${IMAGE_BIN}"
fi

echo "Device: \"${DEVICE}\" Image: \"${IMAGE}\" BL31: \"${BL31}\" SERIALID: \"${SERIALID}\""

if [ -n "${BL31}" ]; then
    echo "Got a new BL31"
    # Replace the BL31
    "${CBFSTOOL}" "${IMAGE_BIN}" remove -n fallback/bl31
    "${CBFSTOOL}" "${IMAGE_BIN}" add-payload -n fallback/bl31 -f "${BL31}"
else
    echo "No BL31 given, flashing the image as-is"
fi

# Copy the image to the container
COPIED=1
docker cp "${IMAGE_BIN}" "${CONTAINER}:${CONTAINER_IMAGE}"
# Flash the firmware
docker exec "${CONTAINER}" "${FLASHROM}" -n -w "${CONTAINER_IMAGE}" \
    -p raiden_debug_spi:target=AP,serial="${SERIALID}"

sleep 10
