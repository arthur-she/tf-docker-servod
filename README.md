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
| `Dockerfile` | Image, derived from `us-docker.pkg.dev/chromeos-hw-tools/servod/servod`. Replaces the stock flashrom with a pinned upstream build (see below) and makes servod's gRPC ports configurable per container. |
| `docker-compose.yaml` | Per-host service definitions. `x-common` holds the shared settings; each service pins `PORT`, `BOARD`, `MODEL`, `SERIAL`, `LAVA_DEVICE`, and, when a host runs more than one service, `GRPC_DATA_PORT`/`GRPC_CORE_PORT`. |
| `post_servod.sh` | Container entrypoint — launches the base-image `/start_servod.sh`, waits for servod, then links the DUT UART pty paths into `/run/pts/`. |
| `Dockerfile.cbfstool` | Separate image that builds `cbfstool` from coreboot 4.14. |
| `install-servod-usb-handler.sh` | Installs the udev integration (handler, rule, tmpfiles config). |
| `udev/` | Source files for the udev integration. |
| `docker-chromebook-tfa-flasher.sh` | Host-side LAVA helper — flashes AP firmware through the DUT's servod container, optionally replacing BL31 first. |
| `docker-dut-control-wrapper.sh` | Host-side LAVA helper — runs `dut-control` in the DUT's servod container, restarting servod as a last resort. |

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
      - GRPC_DATA_PORT=50101        # unique per service on this host
      - GRPC_CORE_PORT=50102
```

Containers use `network_mode: host`, so each one's servod port and gRPC ports
must be unique on the host. `GRPC_DATA_PORT`/`GRPC_CORE_PORT` default to
upstream's 50051/50052, which is fine for a single service.

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

## flashrom

The image builds flashrom from
[chromiumos/third_party/flashrom](https://chromium.googlesource.com/chromiumos/third_party/flashrom)
at a pinned commit (`FLASHROM_REF` in the `Dockerfile`) and installs it as
`/usr/local/sbin/flashrom` in place of the servod image's own. The pin must
include `794ac5ef` ("raiden_debug_spi: Check serial before claiming USB
device"); the build fails otherwise. Without that fix, `raiden_debug_spi`
claims each Ti50's USB interface before checking its serial and resets a Ti50
it finds busy, so flashing one DUT can disrupt a concurrent flash of another
DUT on the same host.

## Rebuilding the image

`FROM` uses `us-docker.pkg.dev/chromeos-hw-tools/servod/servod:${RELEASE_TYPE}`
(default `latest`). Never tag a local build with that name: the next build
would stack this Dockerfile's edits on top of an already edited image. Pull
the upstream image before rebuilding:

```bash
docker pull us-docker.pkg.dev/chromeos-hw-tools/servod/servod:latest
docker compose build
docker compose up -d
```

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

## LAVA wrapper scripts

LAVA jobs on the worker reach a DUT through its `<device>-servod` container
with two host-side scripts. `<device>` is the compose service name, which is
also the `LAVA_DEVICE`.

### `docker-chromebook-tfa-flasher.sh`

```bash
docker-chromebook-tfa-flasher.sh -d geralt-01 -i image.bin[.gz] [-b bl31.elf] [-s <serial>]
```

- Works on a temporary copy of the image (gunzipped if needed), so the input
  file is never modified.
- With `-b`, replaces `fallback/bl31` in the image using the host's
  `/usr/local/lab-scripts/cbfstool` (see `Dockerfile.cbfstool`). BL31 is
  optional: with no `-b`, an empty value, or an unfilled LAVA placeholder
  such as `{BL31}` (a job with no `bl31` image, e.g. health-check firmware),
  the image is flashed as-is.
- Copies the image into the container and writes it with
  `flashrom -p raiden_debug_spi:target=AP`, then removes it again.
- The servo serial is read from the container's `SERIAL`. `-s` is optional;
  if given, it must match.
- If flashing fails, restarts the container, waits for servod, and flashes
  again, up to `SERVOD_MAX_RESTARTS` times (default 2).

### `docker-dut-control-wrapper.sh`

```bash
docker-dut-control-wrapper.sh -d geralt-01 -p 9999 -c 'power_state:off'
```

- Runs `dut-control --port <port> <command>` in the container. `-c` may hold
  several space-separated controls.
- On failure, retries once. If that also fails, restarts the container, waits
  for servod, and retries, up to `SERVOD_MAX_RESTARTS` times (default 2).

In both scripts, a restart re-creates the DUT UART ptys, so any console
already open on the old pty is lost; the scripts print a `WARNING` when this
happens.

## Per-host configuration

The repository keeps one branch per host (`tf-nuc-worker02`, `mele`, …); each
branch ships a `docker-compose.yaml` with the services for that host. The
common settings, scripts, image, and udev integration are shared across
branches.
