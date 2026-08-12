# syntax=docker/dockerfile:1

# Pinned upstream release, updated by .github/workflows/upstream-bump.yml. The
# image release version is KINGSTVIS_VERSION.
ARG KINGSTVIS_VERSION=3.6.6
ARG KINGSTVIS_SHA256=3fefb1416998b3b2f8c7c6c519deb04b9c26585bbb9f5d5ecded1e385838fb70

FROM debian:trixie-slim AS build
ARG KINGSTVIS_VERSION
ARG KINGSTVIS_SHA256
SHELL ["/bin/sh", "-eux", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# /download/vis_linux redirects to the current release; the versioned path is
# stable and is what a pin has to name.
RUN curl -fsSL -o vis.tar.gz \
      "https://www.qdkingst.com/kfs/KingstVIS_v${KINGSTVIS_VERSION}.tar.gz" \
    && printf '%s  vis.tar.gz\n' "${KINGSTVIS_SHA256}" > vis.sha256 \
    && sha256sum -c vis.sha256 \
    && mkdir -p /out/opt \
    && tar xzf vis.tar.gz -C /out/opt \
    && rm vis.tar.gz vis.sha256

# noVNC's client is static browser javascript, but the Debian package depends on
# nodejs for developer tools that serving those files does not use, so take the
# assets and let websockify serve them.
RUN apt-get update \
    && apt-get download novnc \
    && dpkg -x novnc_*.deb /out/novnc \
    && rm -f novnc_*.deb \
    && rm -rf /var/lib/apt/lists/* \
    && test -e /out/novnc/usr/share/novnc/vnc.html

WORKDIR /out/opt/KingstVIS
# The bundle is self contained apart from X11 and glib: Qt 5.6, ICU and OpenSSL
# ship beside the binary and are found through its $ORIGIN rpath, and libusb
# 1.0 is linked into the binary itself.
RUN set -- Analyzer/*.so \
    && [ "$#" -gt 30 ] \
    && test -x KingstVIS \
    && test -e platforms/libqxcb.so \
    && test -e Driver/99-Kingst.rules \
# Upstream's in place self updater rewrites the install directory, which an
# image pins on purpose; the version is changed by rebuilding. The install
# scripts only sudo the udev rules into place, which is the host's job.
    && rm -f Updater install.sh Driver/install_driver.sh

FROM debian:trixie-slim
ARG KINGSTVIS_VERSION
SHELL ["/bin/sh", "-eux", "-c"]

# The X11, glib and font libraries Qt 5.6's xcb platform plugin needs; the rest
# of Qt is bundled. libgl1 and libegl1 are link time dependencies of that plugin
# and have to resolve even though the application paints through Qt's raster
# engine and never creates a GL context; Mesa, and the LLVM its software
# rasteriser is built on, come with them and are most of the image size.
# xvfb/x11vnc/websockify provide the headless display served by entrypoint.sh.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libdbus-1-3 libegl1 libfontconfig1 libfreetype6 libgl1 \
        libglib2.0-0t64 libice6 libsm6 libx11-6 \
        libx11-xcb1 libxcb1 libxext6 libxi6 libxrender1 \
        ca-certificates fonts-dejavu-core websockify x11-utils x11vnc xauth xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -G plugdev -s /bin/sh kingst \
    && install -d -o kingst -g kingst /data \
    && install -d -m 1777 /tmp/.X11-unix

COPY --from=build /out/opt /opt
COPY --from=build /out/novnc/usr/share/novnc /usr/share/novnc
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# The udev rules are the host's to install; they are kept here so they can be
# copied out of the image rather than tracked separately. See docs/usage.md.
RUN ln -s /opt/KingstVIS/KingstVIS /usr/local/bin/KingstVIS \
    && ln -s /opt/KingstVIS/KingstVIS /usr/local/bin/kingstvis \
    && install -D -m 644 /opt/KingstVIS/Driver/99-Kingst.rules \
        /usr/lib/udev/rules.d/99-kingst.rules

ENV KINGSTVIS_VERSION=${KINGSTVIS_VERSION} \
    KINGSTVIS_HOME=/data \
    DISPLAY=:0 \
    KINGSTVIS_DISPLAY_WIDTH=1600 \
    KINGSTVIS_DISPLAY_HEIGHT=1000 \
    VNC_PORT=5900 \
    NOVNC_PORT=6080 \
    XDG_RUNTIME_DIR=/tmp/runtime-kingst

# By name, not 1000:1000: a numeric USER gets no supplementary groups, and
# plugdev is the group hosts commonly put /dev/bus/usb nodes in.
USER kingst
WORKDIR /data
VOLUME ["/data"]
EXPOSE 5900 6080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["kingstvis"]

LABEL org.opencontainers.image.title="KingstVIS" \
      org.opencontainers.image.description="Kingst Virtual Instruments Studio, headless over VNC or on a host X11 display, with the logic analyzer passed in" \
      org.opencontainers.image.version="${KINGSTVIS_VERSION}" \
      org.opencontainers.image.source="https://github.com/anarkiwi/docker-kingstvis" \
      org.opencontainers.image.url="https://www.qdkingst.com/en/download" \
      org.opencontainers.image.licenses="LicenseRef-KingstVIS"
