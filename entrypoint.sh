#!/bin/sh
# Run KingstVIS either on a host X11 display passed into the container, or on a
# private Xvfb display exported over VNC (and noVNC). See docs/usage.md.
set -eu

: "${KINGSTVIS_HOME:=/data}"
: "${KINGSTVIS_HEADLESS:=auto}"
: "${KINGSTVIS_DISPLAY_WIDTH:=1600}"
: "${KINGSTVIS_DISPLAY_HEIGHT:=1000}"
: "${KINGSTVIS_DISPLAY_DEPTH:=24}"
: "${DISPLAY:=:0}"
: "${VNC_PORT:=5900}"
: "${NOVNC_PORT:=6080}"
: "${VNC_PASSWORD_FILE:=/run/secrets/vnc_password}"
: "${XDG_RUNTIME_DIR:=/tmp/runtime-kingst}"
export DISPLAY XDG_RUNTIME_DIR

log() { echo "entrypoint: $*" >&2; }
die() { log "$*"; exit 1; }

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"
mkdir -p "${KINGSTVIS_HOME}" 2>/dev/null || true

# Qt keys its settings off HOME, so captures, decoder settings and the window
# state all land under one mount.
[ -w "${KINGSTVIS_HOME}" ] \
  || die "${KINGSTVIS_HOME} is not writable by uid $(id -u); mount it -u $(id -u):$(id -g)"
HOME=${KINGSTVIS_HOME}
export HOME

[ $# -gt 0 ] || set -- kingstvis

needs_display=false
case "$1" in
  kingstvis|KingstVIS|/opt/KingstVIS/KingstVIS) needs_display=true;;
esac

# libusb 1.0 is linked into KingstVIS and opens /dev/bus/usb directly. Its
# check_usb_vfs() needs at least one entry under that directory or
# libusb_init() fails, and KingstVIS then calls libusb_get_device_list() on the
# null context it got back and segfaults. Give it an empty bus directory when
# no real one was passed in, so it starts with no hardware instead of dying.
empty_dir() { ! find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; }
if [ "${needs_display}" = true ] && [ "${KINGSTVIS_USB_CHECK:-1}" != 0 ]; then
  if empty_dir /dev/bus/usb; then
    if mkdir -p /dev/bus/usb/001 2>/dev/null; then
      log "no usb bus passed in; starting with no hardware"
    else
      log "/dev/bus/usb is empty or missing, and cannot be created by uid $(id -u)."
      log "KingstVIS cannot start without it. Pass the host's buses in with"
      log "  -v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule 'c 189:* rmw'"
      die "or run with no hardware using --tmpfs /dev/bus/usb:mode=0777"
    fi
  # libusb opens the node read write; the default root owned 0664 grants a
  # passed in uid neither, and the shipped udev rules relax it to 0666.
  elif find /dev/bus/usb -type c ! -writable -print -quit 2>/dev/null | grep -q .; then
    log "warning: some /dev/bus/usb nodes are not writable by uid $(id -u);"
    log "warning: install the udev rules on the host (see docs/usage.md)."
  fi
fi

# A local display (:N[.S]) is a host display only if its socket is mounted in.
local_display=false
display_number=
case "${DISPLAY}" in
  :*) local_display=true
      display_number=${DISPLAY#:}
      display_number=${display_number%%.*};;
esac
# A remote DISPLAY (host:0) is always someone else's server; a local one is
# only usable if its socket was mounted in.
host_display=true
if [ "${local_display}" = true ] && [ ! -e "/tmp/.X11-unix/X${display_number}" ]; then
  host_display=false
fi

case "${KINGSTVIS_HEADLESS}" in
  1|true|yes) headless=true;;
  0|false|no) headless=false;;
  auto) if [ "${host_display}" = true ]; then headless=false; else headless=true; fi;;
  *) die "KINGSTVIS_HEADLESS must be auto, 1 or 0 (got ${KINGSTVIS_HEADLESS})";;
esac

pids=
cleanup() {
  [ -n "${pids}" ] || return 0
  # shellcheck disable=SC2086 # pids is a deliberately word split list.
  kill ${pids} 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

start_display() {
  [ "${local_display}" = true ] \
    || die "headless mode needs a local DISPLAY like :0 (got ${DISPLAY})"
  geometry="${KINGSTVIS_DISPLAY_WIDTH}x${KINGSTVIS_DISPLAY_HEIGHT}x${KINGSTVIS_DISPLAY_DEPTH}"
  log "starting Xvfb on ${DISPLAY} (${geometry})"
  Xvfb "${DISPLAY}" -screen 0 "${geometry}" -nolisten tcp &
  pids="${pids} $!"

  waited=0
  while [ "${waited}" -lt 100 ]; do
    xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1 && return 0
    waited=$((waited + 1))
    sleep 0.1
  done
  die "Xvfb did not come up on ${DISPLAY}"
}

start_vnc() {
  set -- x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" \
    -forever -shared -noxdamage -quiet
  if [ -r "${VNC_PASSWORD_FILE}" ]; then
    # x11vnc reads the file itself, so the password never appears in argv.
    log "using VNC password from ${VNC_PASSWORD_FILE}"
    set -- "$@" -passwdfile "${VNC_PASSWORD_FILE}"
  else
    log "no password file at ${VNC_PASSWORD_FILE}; VNC is unauthenticated"
    set -- "$@" -nopw
  fi
  log "starting x11vnc on port ${VNC_PORT}"
  "$@" &
  pids="${pids} $!"
}

start_novnc() {
  log "starting noVNC on port ${NOVNC_PORT} (http://localhost:${NOVNC_PORT}/vnc.html)"
  websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
  pids="${pids} $!"
}

if [ "${headless}" = true ] && [ "${needs_display}" = true ]; then
  start_display
  if [ "${VNC_PORT}" != 0 ]; then
    start_vnc
    [ "${NOVNC_PORT}" = 0 ] || start_novnc
  fi
fi

log "running: $*"
"$@" &
app_pid=$!
pids="${pids} ${app_pid}"
wait "${app_pid}"
