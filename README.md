# docker-kingstvis

[KingstVIS](https://www.qdkingst.com/en/download), the Kingst Virtual Instruments Studio
for their logic analyzers, in a container: run it headlessly over VNC/noVNC, or on a host
X11 display, with the analyzer passed in over USB.

Image versions match the upstream release exactly: image `3.6.6` runs KingstVIS `3.6.6`,
built from the pinned, checksummed upstream Linux tarball. A daily workflow opens a pull
request when upstream publishes a new version.

## Images

    ghcr.io/anarkiwi/docker-kingstvis:3.6.6
    docker.io/anarkiwi/kingstvis:3.6.6

Tags: `X.Y.Z`, `latest`. linux/amd64.

## Use

The analyzer is reached through `/dev/bus/usb`, and `HOME` in the container is the data
directory, `/data` by default. Run as yourself so captures stay yours:

    docker run --rm -p 5900:5900 -p 6080:6080 \
      -u $(id -u):$(id -g) \
      -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw' \
      -v ~/kingstvis:/data \
      ghcr.io/anarkiwi/docker-kingstvis:latest

With no host X11 display available the container starts its own Xvfb, exports it on VNC
port 5900, and serves noVNC on <http://localhost:6080/vnc.html>.

To use the host's display and analyzer instead, pass them in —
`bin/kingstvis-docker` wraps this, mounting your home directory at its own path:

    ./bin/kingstvis-docker

The device nodes are owned by root, so the host needs the udev rules that make them
world writable. They ship in the image; install them on the **host**, not in the container:

    docker run --rm ghcr.io/anarkiwi/docker-kingstvis:latest \
      cat /usr/lib/udev/rules.d/99-kingst.rules | sudo tee /etc/udev/rules.d/99-kingst.rules
    sudo udevadm control --reload && sudo udevadm trigger

Without them, run the container as root (`-u 0:0`) instead.

See [docs/usage.md](docs/usage.md) for USB passthrough, VNC passwords and
the environment variables, and [docs/releasing.md](docs/releasing.md) for the release and
upstream tracking workflows.

## Test

    docker build -t kingstvis:test .
    tests/smoke.sh kingstvis:test

The smoke test checks the pinned version against the bundle, checks the protocol analyzers
and udev rules are present and the self updater is not, checks every shared library
resolves, boots the application headlessly and checks it maps its window and creates its
settings as the calling user, checks VNC and noVNC are serving, checks a missing USB bus
and an unwritable data directory are both rejected with a diagnostic, and checks a shared
host X11 display is used when one is present.

## Scope

The image is the upstream Linux tarball unpacked at `/opt/KingstVIS`: a Qt 5.6 application
that bundles its own Qt, ICU and OpenSSL, with libusb 1.0 linked into the binary, so only
X11, glib and fontconfig come from Debian. Upstream's in place self updater is removed —
the image pins a version, and rebuilding is how it changes.

KingstVIS cannot start without a USB bus: `libusb_init()` fails when `/dev/bus/usb` has no
entries, and the application uses the null context it gets back. The entrypoint supplies an
empty bus when none is passed in, so it starts with no hardware (upstream's demo mode)
rather than crashing.

KingstVIS is proprietary freeware, © Qingdao Kingst Electronics; it is downloaded at build
time and not redistributed here. Its licence permits free use and redistribution but not
modification — see `/opt/KingstVIS/License.txt` in the image. This packaging is licensed
separately, see [LICENSE](LICENSE).
