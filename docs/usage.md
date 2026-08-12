# Usage

## The analyzer

KingstVIS talks to the analyzer through libusb, which is linked into the binary and opens
`/dev/bus/usb` directly. Two things have to be true: the bus has to be in the container,
and its device nodes have to be writable by the uid the container runs as.

    -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw'

The whole tree, not `--device`: an analyzer plugged in after the container starts gets a
device node that a `--device` mapping would not carry. The cgroup rule is what permits
opening those nodes; `189` is the USB device major.

### udev rules

The nodes are created `root:root` mode `0664`, which a passed in uid can neither read nor
write. Upstream ships rules that relax the Kingst devices to `0666`; they are in the image,
but they are the **host's** to install:

    docker run --rm ghcr.io/anarkiwi/docker-kingstvis:latest \
      cat /usr/lib/udev/rules.d/99-kingst.rules | sudo tee /etc/udev/rules.d/99-kingst.rules
    sudo udevadm control --reload && sudo udevadm trigger

They cover vendor `77a1`, products `01a1`–`03a3` (LA1002, LA1010, LA2016, LA5016 and the
rest of the range). Replug the analyzer afterwards. The entrypoint warns when it sees nodes
it cannot write, which is what a missing rules file looks like from inside.

Without the rules, run the container as root instead:

    docker run --rm -u 0:0 -v /dev/bus/usb:/dev/bus/usb ...

### Running with no analyzer

KingstVIS cannot start without a USB bus at all: `libusb_init()` fails when `/dev/bus/usb`
is missing or empty, and the application calls `libusb_get_device_list()` on the null
context it gets back and segfaults. The entrypoint creates an empty bus directory when it
can, so the application starts with no hardware — upstream's demo mode, which is enough to
open saved captures. Where `/dev` is not writable, ask for a writable one:

    --tmpfs /dev/bus/usb:mode=0777

If neither is possible the entrypoint stops with a diagnostic rather than let the
application crash.

## Data directory

`HOME` inside the container is the data directory, `/data` by default, so KingstVIS keeps
its settings under `.local/share/kingst` on one mount. Captures go wherever you save them,
which has to be under a mount to survive the container:

    docker run --rm -u $(id -u):$(id -g) \
      -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw' \
      -v ~/kingstvis:/data ghcr.io/anarkiwi/docker-kingstvis:latest

The entrypoint refuses to start if the data directory is not writable by the uid it is
running as, rather than letting Qt half start against a read only home.

### An existing install

To take over from an unpacked `/usr/local/KingstVIS`, mount the home directory holding its
settings **at the path it has on the host** and point `KINGSTVIS_HOME` at it, so the
absolute paths in the settings and the recent capture list still resolve:

    docker run --rm -u $(id -u):$(id -g) \
      -e KINGSTVIS_HOME=/home/josh \
      -v /home/josh:/home/josh \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw' \
      ghcr.io/anarkiwi/docker-kingstvis:latest

Capture directories outside the home directory need their own mount at the same path.

| Variable | Default | Purpose |
| --- | --- | --- |
| `KINGSTVIS_HOME` | `/data` | data directory, used as `HOME` |
| `KINGSTVIS_HEADLESS` | `auto` | `1` always start Xvfb, `0` never, `auto` only when no host display |
| `KINGSTVIS_DISPLAY_WIDTH` | `1600` | Xvfb screen width |
| `KINGSTVIS_DISPLAY_HEIGHT` | `1000` | Xvfb screen height |
| `KINGSTVIS_DISPLAY_DEPTH` | `24` | Xvfb colour depth |
| `KINGSTVIS_USB_CHECK` | `1` | `0` skips the USB bus check and its placeholder |
| `VNC_PORT` | `5900` | x11vnc port; `0` disables VNC and noVNC |
| `NOVNC_PORT` | `6080` | noVNC port; `0` disables noVNC only |
| `VNC_PASSWORD_FILE` | `/run/secrets/vnc_password` | password file, if present |

## Headless (VNC and noVNC)

With no host X11 display the container starts `Xvfb`, `x11vnc` and noVNC:

    docker run --rm -p 5900:5900 -p 6080:6080 \
      -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw' \
      -v ~/kingstvis:/data ghcr.io/anarkiwi/docker-kingstvis:latest

* VNC client: `localhost:5900`
* Browser: <http://localhost:6080/vnc.html>

This is the useful mode for an analyzer plugged into a headless machine. The application
paints through Qt's raster engine and never creates an OpenGL context, so there is nothing
to gain from passing a GPU in with `--device /dev/dri`.

### VNC password

Without a password file the VNC server is unauthenticated — publish it only on a trusted
network or bind it to localhost (`-p 127.0.0.1:5900:5900`). To require a password, provide
it as a Docker secret; `x11vnc` reads the file itself, so it never appears in the process
list or in `docker inspect`:

    echo 's3cret' | docker secret create vnc_password -    # swarm
    docker run --rm -v ~/vnc_password:/run/secrets/vnc_password:ro ...   # plain docker

noVNC's HTTP endpoint is plain HTTP; put it behind a TLS reverse proxy if it leaves the
host.

## Host X11 display

Mounting the X11 socket makes the entrypoint skip Xvfb and VNC and use your display
directly:

    docker run --rm -u $(id -u):$(id -g) \
      -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
      -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw' \
      -v ~/kingstvis:/data ghcr.io/anarkiwi/docker-kingstvis:latest

`bin/kingstvis-docker` does that for you, mounting your home directory at its own path and
adding the USB tree when the host has one:

    ./bin/kingstvis-docker
    KINGSTVIS_IMAGE=ghcr.io/anarkiwi/docker-kingstvis:3.6.6 ./bin/kingstvis-docker

| Variable | Default | Purpose |
| --- | --- | --- |
| `KINGSTVIS_IMAGE` | `ghcr.io/anarkiwi/docker-kingstvis:latest` | image to run |
| `KINGSTVIS_DOCKER` | `docker` | container runtime |
| `KINGSTVIS_HOME` | `$HOME` | host directory mounted at its own path |
| `KINGSTVIS_DOCKER_OPTS` | | extra `docker run` options, word split |

If your X server needs authorisation, the wrapper mounts `$XAUTHORITY`. `xhost` rules
otherwise apply as usual.

## Network

The application checks for updates on launch, which is why Qt logs two
`QSslSocket: cannot resolve SSLv2_*_method` warnings — Qt 5.6 probing its bundled OpenSSL
1.0.2 for methods that release no longer exports. Both are harmless.

Nothing can act on the result: upstream's self updater is removed from the image, because
it rewrites the install directory the image pins, so *Help → Check for Updates* reports one
but cannot apply it. Turn off *Check for updates on launch* in the preferences, or run with
`--network none`, to stop it asking.

## What is in the image

The upstream tarball unpacked at `/opt/KingstVIS`, with `KingstVIS` and `kingstvis` on
`PATH`. The bundle carries its own Qt 5.6, ICU and OpenSSL and finds them through an
`$ORIGIN` rpath, so only X11, glib and fontconfig come from Debian. Most of the image is
not KingstVIS at all: Qt's xcb plugin links `libGL`/`libEGL`, and Mesa and the LLVM behind
its software rasteriser follow, unused.

| Path | Contents |
| --- | --- |
| `/opt/KingstVIS/Analyzer/` | protocol analyzer plugins (I2C, SPI, UART, CAN, USB-PD, …) |
| `/opt/KingstVIS/Language/` | translations |
| `/opt/KingstVIS/Resource/` | the user guide, English (`ug-en.pdf`) and Chinese (`ug-cn.pdf`) |
| `/opt/KingstVIS/License.txt` | upstream licence |
| `/usr/lib/udev/rules.d/99-kingst.rules` | the rules to install on the host |

Use `--entrypoint` to bypass the entrypoint entirely:

    docker run --rm --entrypoint sh ghcr.io/anarkiwi/docker-kingstvis:latest \
      -c 'ls /opt/KingstVIS'
