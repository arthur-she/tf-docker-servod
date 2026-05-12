# tf-docker-servod

Dockerized [`servod`](https://chromium.googlesource.com/chromiumos/third_party/hdctools/+/HEAD/docs/servod.md)
instances for ChromiumOS hardware test farms, orchestrated via `docker compose`,
with an optional udev integration that starts and stops each container in step
with its Ti50 USB device.

One compose service per DUT. Each service is bound to a specific servo by its
USB serial number; `servod` is launched inside the container against that
serial on a dedicated TCP port.

## Layout

| Path | Purpose |
| --- | --- |
| `Dockerfile` | Image, derived from `us-docker.pkg.dev/chromeos-hw-tools/servod/servod`. |
| `docker-compose.yaml` | Per-host service definitions. `x-common` holds the shared settings; each service pins `PORT`, `BOARD`, `MODEL`, `SERIAL`, `LAVA_DEVICE`. |
| `post_servod.sh` | Container entrypoint — launches `start_servod.sh` and links UART pty paths into `/run/pts/`. |
| `start_servod.sh` / `stop_servod.sh` | Wrappers around the upstream servod start/stop scripts; baked into the image. |
| `Dockerfile.cbfstool` | Separate image that builds `cbfstool` from coreboot 4.14. |
| `install-servod-usb-handler.sh` | Installs the udev integration (handler, rule, tmpfiles config). |
| `udev/` | Source files for the udev integration. |

## Running

Edit `docker-compose.yaml` so exactly one service block is active per Ti50
plugged into this host. The pattern looks like:

```yaml
services:
  geralt-01:
    <<: *common_settings
    container_name: "geralt-01-servod"
    hostname: "geralt-01-servod"
    environment:
      - PORT=9999
      - MODEL=geralt
      - BOARD=geralt
      - SERIAL=1400e002-4c1b4b03    # the USB serial of the Ti50
      - LAVA_DEVICE=geralt-01
```

Then:

```bash
docker compose up -d --build         # build image + start everything
docker compose stop geralt-01        # stop one service
docker compose start geralt-01       # start it again (no rebuild)
docker compose logs -f geralt-01     # tail servod output
docker exec geralt-01-servod \
    dut-control -p 9999 power_state:off   # send a command to the DUT
```

The container's `restart: always` policy means servod is brought back up after
host reboots and after the servod process exits.

## udev auto start/stop

`install-servod-usb-handler.sh` deploys three files that wire each Ti50 USB device
(`18d1:504a`) to its compose service:

- `/usr/local/bin/servod-usb-handler` — looks up the device's serial in the
  compose file and runs `docker compose start|stop <service>`.
- `/etc/udev/rules.d/99-servod-usb.rules` — fires on `add`/`remove` for the
  Ti50 vendor:product pair and invokes the handler via `systemd-run`.
- `/etc/tmpfiles.d/servod-usb.conf` — declares `/run/servod-usb/` as transient
  state (kernel-name → serial map), wiped on boot.

The mapping from serial to compose service is resolved at runtime from
`docker-compose.yaml`, so the udev rule has no hard-coded serial.

To install:

```bash
sudo ./install-servod-usb-handler.sh
```

The handler's default `COMPOSE_FILE` is wired to the `docker-compose.yaml`
sitting next to `install-servod-usb-handler.sh`. Override at runtime with the `COMPOSE_FILE` env
var if you need to point at a different file.

After install, plugging a Ti50 listed in `docker-compose.yaml` starts its
service automatically; unplugging stops it. Other USB devices are ignored.

Inspect activity with:

```bash
journalctl -t servod-usb-handler -f
```

## Per-host configuration

The repository keeps one branch per host (`tf-nuc-worker02`, `mele`, …); each
branch ships a `docker-compose.yaml` with the services for that host. The
common settings, scripts, image, and udev integration are shared across
branches.
