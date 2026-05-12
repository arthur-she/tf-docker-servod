#!/usr/bin/env bash
# Install the udev rule, tmpfiles config, and handler that start/stop
# docker-compose services in response to Ti50 USB plug/unplug events.
#
# The handler's default COMPOSE_FILE is wired to the docker-compose.yaml
# sitting next to this script.

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yaml"
UDEV_SRC="$INSTALL_DIR/udev"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "error: docker-compose.yaml not found next to install-servod-usb-handler.sh ($COMPOSE_FILE)" >&2
  exit 1
fi

for f in servod-usb-handler 99-servod-usb.rules servod-usb.conf; do
  if [[ ! -f "$UDEV_SRC/$f" ]]; then
    echo "error: $UDEV_SRC/$f missing" >&2
    exit 1
  fi
done

SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

tmp_handler="$(mktemp)"
trap 'rm -f "$tmp_handler"' EXIT
sed "s|__COMPOSE_FILE__|$COMPOSE_FILE|g" "$UDEV_SRC/servod-usb-handler" > "$tmp_handler"

echo "installing handler  -> /usr/local/bin/servod-usb-handler (COMPOSE_FILE=$COMPOSE_FILE)"
$SUDO install -m 0755 "$tmp_handler" /usr/local/bin/servod-usb-handler

echo "installing udev rule -> /etc/udev/rules.d/99-servod-usb.rules"
$SUDO install -m 0644 "$UDEV_SRC/99-servod-usb.rules" /etc/udev/rules.d/99-servod-usb.rules

echo "installing tmpfiles  -> /etc/tmpfiles.d/servod-usb.conf"
$SUDO install -m 0644 "$UDEV_SRC/servod-usb.conf" /etc/tmpfiles.d/servod-usb.conf

echo "reloading udev rules and applying tmpfiles"
$SUDO udevadm control --reload-rules
$SUDO systemd-tmpfiles --create /etc/tmpfiles.d/servod-usb.conf

echo "done."
