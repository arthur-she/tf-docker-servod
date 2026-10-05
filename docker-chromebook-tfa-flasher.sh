#!/bin/bash
# Flash an AP firmware image onto a DUT through its <DEVICE>-servod container,
# optionally replacing the image's BL31 first. Called from LAVA jobs.
#
# The servo serial is read from the container's SERIAL env. -s is still
# accepted for existing job definitions, and must match it.
#
# If flashing fails, the servod container is assumed glitched: it is
# restarted and the flash retried, up to SERVOD_MAX_RESTARTS times
# (default 2).

set -ex

FLASHROM="/usr/local/sbin/flashrom"
CBFSTOOL="/usr/local/lab-scripts/cbfstool"
WAIT_FOR_IT="/usr/bin/wait-for-it"
MAX_RESTARTS="${SERVOD_MAX_RESTARTS:-2}"

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

# Read a variable from the container's configured env. Uses docker inspect
# rather than docker exec so it works even while the container is down.
container_env() {
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" \
        | sed -n "s/^$1=//p"
}

SERIALID=$(container_env SERIAL)
[ -n "${SERIALID}" ] || die "cannot read SERIAL from container ${CONTAINER}"
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

# Copy the image into the container and flash it. Runs as an until/if
# condition, where set -e is off, so steps are chained with && explicitly.
flash_once() {
    COPIED=1
    docker cp "${IMAGE_BIN}" "${CONTAINER}:${CONTAINER_IMAGE}" \
        && docker exec "${CONTAINER}" "${FLASHROM}" -n -w "${CONTAINER_IMAGE}" \
            -p raiden_debug_spi:target=AP,serial="${SERIALID}"
}

# Restart the container and wait until servod is up again. post_servod.sh
# sleeps 5s after the port opens before linking the UART ptys, so allow for
# that too.
#
# servod registers the devices it serves under /run/servoscratch, which
# survives a container restart. servod drops a leftover entry only once it
# can bind the old port, which fails while that port still has TIME_WAIT
# connections, and it then refuses to start ("already served by another
# servod instance"). Clear the entries first.
restart_servod() {
    local port
    echo "WARNING: restarting ${CONTAINER}; DUT UART ptys will be re-created" >&2
    docker exec "${CONTAINER}" find /run/servoscratch -maxdepth 1 ! -type d -delete || true
    docker restart "${CONTAINER}" || return 1
    port=$(container_env PORT)
    docker exec "${CONTAINER}" ${WAIT_FOR_IT} -t 120 "localhost:${port:-9999}" || return 1
    sleep 10
}

restarts=0
until flash_once; do
    [ "${restarts}" -lt "${MAX_RESTARTS}" ] \
        || die "flashing failed after ${MAX_RESTARTS} servod restarts"
    restarts=$((restarts + 1))
    echo "Flashing failed, restarting servod and retrying (${restarts}/${MAX_RESTARTS})"
    restart_servod || echo "servod restart failed" >&2
done

sleep 10
