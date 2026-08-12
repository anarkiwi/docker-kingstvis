#!/bin/sh
# Smoke test a KingstVIS image: tests/smoke.sh <image> [expected-version]
# Checks the pinned version against the bundle, boots the application
# headlessly, and checks the usb, display, VNC and noVNC paths.
set -eu

image=${1:?usage: smoke.sh <image> [expected-version]}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
expected=${2:-$(sed -n 's/^ARG KINGSTVIS_VERSION=//p' "${here}/../Dockerfile")}
boot_timeout=${KINGSTVIS_SMOKE_TIMEOUT:-120}

# The analyzer is not present on a build host, so every boot here gets an empty
# usb bus rather than the host's, which keeps the result independent of what is
# plugged into the machine running the test.
no_hw="--tmpfs /dev/bus/usb:mode=0777"

work=$(mktemp -d)
containers=
volumes=
cleanup() {
  # shellcheck disable=SC2086 # deliberately word split lists.
  [ -z "${containers}" ] || docker rm -f ${containers} >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  [ -z "${volumes}" ] || docker volume rm -f ${volumes} >/dev/null 2>&1 || true
  chmod -R u+w "${work}" 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# Wait for a command to succeed, or fail after boot_timeout seconds.
wait_for() {
  what=$1
  shift
  waited=0
  while [ "${waited}" -lt "${boot_timeout}" ]; do
    "$@" >/dev/null 2>&1 && return 0
    waited=$((waited + 1))
    sleep 1
  done
  fail "timed out after ${boot_timeout}s waiting for ${what}"
}

vis_window() {
  docker exec "$1" xwininfo -root -children 2>/dev/null \
    | sed -n 's/.*"\([^"]*KingstVIS[^"]*\)".*/\1/p' | head -1
}
has_vis_window() { [ -n "$(vis_window "$1")" ]; }

# 1. The pinned version is the one in the image and in the application binary.
env_version=$(docker run --rm --entrypoint sh "${image}" -c 'printf %s "$KINGSTVIS_VERSION"')
[ "${env_version}" = "${expected}" ] \
  || fail "image KINGSTVIS_VERSION ${env_version} != ${expected}"
app_version=$(docker run --rm --entrypoint sh "${image}" -c \
  "grep -aoF '${expected}' /opt/KingstVIS/KingstVIS | head -1")
[ "${app_version}" = "${expected}" ] \
  || fail "the application binary does not carry version ${expected}"
ok "KingstVIS ${expected}"

# 2. The bundle is complete: Qt and its xcb plugin, the protocol analyzers, and
# the udev rules the host needs. A missing analyzer only shows up when a user
# adds that decoder, so count them here.
docker run --rm --entrypoint sh "${image}" -c '
  cd /opt/KingstVIS \
    && test -x KingstVIS \
    && test -e platforms/libqxcb.so \
    && test -e libQt5Core.so.5 && test -e libQt5Widgets.so.5 \
    && test -e Resource/ug-en.pdf \
    && [ "$(ls Analyzer/*.so | wc -l)" -gt 30 ] \
    && test -e /usr/lib/udev/rules.d/99-kingst.rules' \
  || fail "the KingstVIS bundle is incomplete"
analyzers=$(docker run --rm --entrypoint sh "${image}" -c 'ls /opt/KingstVIS/Analyzer/*.so | wc -l')
ok "bundle complete: ${analyzers} protocol analyzers, udev rules, Qt xcb plugin"

# The self updater would rewrite the install directory the image pins.
docker run --rm --entrypoint sh "${image}" -c 'test ! -e /opt/KingstVIS/Updater' \
  || fail "the upstream self updater is still present"
docker run --rm --entrypoint sh "${image}" -c \
  'grep -q "77a1" /usr/lib/udev/rules.d/99-kingst.rules' \
  || fail "the udev rules do not mention the Kingst vendor id"
ok "self updater removed, udev rules carry vendor 77a1"

# 3. Every shared library the application and its plugins load resolves inside
# the image; the bundle finds its own Qt through an $ORIGIN rpath.
docker run --rm --entrypoint sh "${image}" -c '
  cd /opt/KingstVIS
  missing=$(ldd KingstVIS platforms/libqxcb.so libQt5XcbQpa.so.5 2>&1 \
    | grep "not found" | sort -u)
  [ -z "${missing}" ] || { echo "${missing}"; exit 1; }' \
  || fail "unresolved shared libraries in the bundle"
ok "application and xcb plugin link cleanly"

# 4. Headless boot, as the calling user against a bind mounted data dir.
mkdir -p "${work}/data"
name=kingstvis-smoke-$$
containers="${containers} ${name}"
# shellcheck disable=SC2086 # no_hw is a deliberately word split option list.
docker run -d --name "${name}" \
  -u "$(id -u):$(id -g)" \
  ${no_hw} \
  -p 127.0.0.1::5900 -p 127.0.0.1::6080 \
  -v "${work}/data:/data" \
  "${image}" >/dev/null

wait_for "the KingstVIS window" has_vis_window "${name}"
ok "kingstvis window: $(vis_window "${name}")"

docker logs "${name}" 2>&1 | grep -q "no usb bus passed in" \
  || fail "no diagnostic for the empty usb bus"
# An empty /dev/bus/usb makes libusb_init fail, and the application dereferences
# the null context it gets back; the entrypoint placeholders a bus to avoid it.
docker inspect -f '{{.State.Running}}' "${name}" | grep -q true \
  || fail "the container died with an empty usb bus"
ok "empty usb bus handled without crashing"

# HOME is the data directory, so settings land on the one mount.
wait_for "the settings directory" \
  docker exec "${name}" test -d /data/.local/share/kingst
[ "$(find "${work}/data/.local/share/kingst" -maxdepth 0 -user "$(id -un)" | wc -l)" = 1 ] \
  || fail "data dir not owned by the calling user"
ok "settings created under the data directory and owned by the calling user"

# 5. VNC and noVNC are serving, checked from inside the container's netns
# (python3 comes with websockify).
probe() {
  docker run --rm --network "container:${name}" --entrypoint python3 "${image}" \
    -c "$1" 2>/dev/null || true
}
handshake=$(probe 'import socket
s = socket.create_connection(("127.0.0.1", 5900), 10)
print(s.recv(11).decode(errors="replace").strip())')
case "${handshake}" in
  RFB*) ok "vnc serving (${handshake})";;
  *) fail "no RFB handshake on the VNC port (got '${handshake}')";;
esac
status=$(probe 'import socket
s = socket.create_connection(("127.0.0.1", 6080), 10)
s.sendall(b"GET /vnc.html HTTP/1.0\r\n\r\n")
print(s.recv(64).decode(errors="replace").splitlines()[0])')
case "${status}" in
  *200*) ok "novnc serving (${status})";;
  *) fail "noVNC did not return 200 (got '${status}')";;
esac

vnc_port=$(docker port "${name}" 5900/tcp | head -1 | sed 's/.*://')
[ -n "${vnc_port}" ] || fail "VNC port not published"
ok "vnc published on 127.0.0.1:${vnc_port}"

docker rm -f "${name}" >/dev/null
containers=

# 6. With no usb bus and no way to make one, the entrypoint has to say so
# rather than let the application segfault on a null libusb context.
if docker run --rm -u "$(id -u):$(id -g)" -v "${work}/data:/data" "${image}" \
     >"${work}/nousb.log" 2>&1; then
  fail "a missing usb bus did not fail"
fi
grep -q "device-cgroup-rule" "${work}/nousb.log" \
  || fail "missing usb bus gave no actionable diagnostic: $(tail -3 "${work}/nousb.log")"
grep -q "Segmentation fault" "${work}/nousb.log" \
  && fail "the application segfaulted instead of being stopped by the entrypoint"
ok "missing usb bus rejected with an actionable diagnostic"

# 7. An unwritable data directory fails immediately rather than half starting.
mkdir -p "${work}/locked"
chmod 500 "${work}/locked"
# shellcheck disable=SC2086
if docker run --rm -u 12345:12345 ${no_hw} -v "${work}/locked:/data" "${image}" \
     >"${work}/locked.log" 2>&1; then
  fail "an unwritable data directory did not fail"
fi
grep -q "is not writable" "${work}/locked.log" \
  || fail "unwritable data dir gave no diagnostic: $(tail -3 "${work}/locked.log")"
ok "unwritable data directory rejected with a diagnostic"

# 8. Host display passthrough: an X server in another container, shared over a
# volume, is detected and used instead of starting Xvfb and VNC.
volume=kingstvis-smoke-x11-$$
volumes="${volumes} ${volume}"
xserver=kingstvis-smoke-x-$$
containers="${containers} ${xserver}"
docker volume create "${volume}" >/dev/null
docker run -d --name "${xserver}" -u "$(id -u):$(id -g)" \
  -v "${volume}:/tmp/.X11-unix" --entrypoint Xvfb \
  "${image}" :0 -screen 0 1600x1000x24 -nolisten tcp >/dev/null

mkdir -p "${work}/hostdata"
client=kingstvis-smoke-client-$$
containers="${containers} ${client}"
# shellcheck disable=SC2086
docker run -d --name "${client}" -u "$(id -u):$(id -g)" ${no_hw} \
  -v "${volume}:/tmp/.X11-unix" -v "${work}/hostdata:/data" \
  "${image}" >/dev/null

wait_for "KingstVIS on the shared X display" has_vis_window "${xserver}"
docker logs "${client}" 2>&1 | grep -q "starting Xvfb" \
  && fail "started Xvfb despite a host display being available"
ok "host X11 display used without starting Xvfb or VNC"

echo "PASS ${image} (${expected})"
