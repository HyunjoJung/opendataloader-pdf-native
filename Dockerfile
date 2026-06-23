# Unofficial GraalVM native-image build of the opendataloader-pdf CLI.
#
# Upstream opendataloader-pdf ships a Java (veraPDF) engine; this compiles its
# CLI to a JVM-free native binary. Output is BYTE-IDENTICAL to `java -jar` on the
# json/markdown / image-output=off path (verified by the parity gate below).
#
# The published image is runnable (`docker run ... file.pdf`) AND serves as a
# binary carrier: `COPY --from=ghcr.io/<owner>/opendataloader-pdf-native:<ver> /opt/odl /opt/odl`.
#
# Not affiliated with or endorsed by the opendataloader project / Hancom Inc.
# See NOTICE for attribution.

ARG OPENDATALOADER_PDF_VERSION=2.4.7

# 1. Extract the exact upstream shaded CLI jar from the pip wheel (= production engine).
FROM python:3.11-slim AS jar
ARG OPENDATALOADER_PDF_VERSION
RUN pip install --no-cache-dir --no-deps "opendataloader-pdf==${OPENDATALOADER_PDF_VERSION}" \
 && cp "$(find / -path '*/opendataloader_pdf/jar/opendataloader-pdf-cli.jar' | head -1)" /tmp/cli.jar \
 && test -s /tmp/cli.jar

# 2. native-image build + parity gate. If native != `java -jar`, this stage fails
#    and nothing downstream (or published) is produced.
FROM ghcr.io/graalvm/native-image-community:21 AS build
WORKDIR /build
COPY --from=jar /tmp/cli.jar /build/cli.jar
COPY native-image/agent-config /build/agent-config
COPY native-image/agent-config-awt /build/agent-config-awt
COPY native-image/build.sh /build/build.sh
RUN bash /build/build.sh
# Make /opt/odl SELF-CONTAINED: bundle a stub java.home + fonts + a fontconfig
# config + a wrapper that sets -Djava.home / FONTCONFIG_FILE relative to its own
# dir. Then ANY consumer (the publish image OR a COPY-from sidecar) just runs
# /opt/odl/odl with no extra setup beyond libfreetype6/libfontconfig1. The parity
# gate below exercises this real wrapper. (freetype/fontconfig libs + dejavu here
# are only to source fonts and let the gate run.)
RUN microdnf install -y freetype fontconfig dejavu-sans-fonts findutils >/dev/null 2>&1 || true
RUN set -eux; \
    mv /opt/odl/odl /opt/odl/odl.bin; \
    mkdir -p /opt/odl/java-home/lib /opt/odl/java-home/conf/fonts /opt/odl/fonts /opt/odl/fontconfig; \
    find /usr/share/fonts -iname '*.ttf' -exec cp -n {} /opt/odl/fonts/ \; ; \
    [ -n "$(ls -A /opt/odl/fonts)" ] || { echo 'FATAL: no fonts bundled into /opt/odl/fonts'; exit 1; }; \
    { echo '<?xml version="1.0"?>'; \
      echo '<fontconfig>'; \
      echo '  <dir>/opt/odl/fonts</dir>'; \
      echo '  <dir>/usr/share/fonts</dir>'; \
      echo '  <cachedir>/tmp/.fontconfig</cachedir>'; \
      echo '</fontconfig>'; } > /opt/odl/fontconfig/fonts.conf; \
    { echo '#!/bin/sh'; \
      echo '# Self-contained launcher: stub java.home + bundled fontconfig,'; \
      echo '# relative to this dir, so the AWT/font path works with only'; \
      echo '# libfreetype6/libfontconfig1 present. See README (AWT / font support).'; \
      echo 'HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"'; \
      echo 'export FONTCONFIG_FILE="$HERE/fontconfig/fonts.conf"'; \
      echo 'exec "$HERE/odl.bin" -Djava.home="$HERE/java-home" -Dsun.jnu.encoding=UTF-8 "$@"'; } > /opt/odl/odl; \
    chmod +x /opt/odl/odl
COPY test /build/test
RUN bash /build/test/parity.sh

# 3. Runnable carrier image (small). Holds /opt/odl (native binary + JDK .so).
FROM debian:12-slim AS publish
ARG OPENDATALOADER_PDF_VERSION
LABEL org.opencontainers.image.title="opendataloader-pdf-native" \
      org.opencontainers.image.description="Unofficial JVM-free native-image build of the opendataloader-pdf CLI" \
      org.opencontainers.image.source="https://github.com/HyunjoJung/opendataloader-pdf-native" \
      org.opencontainers.image.licenses="Apache-2.0" \
      opendataloader.pdf.version="${OPENDATALOADER_PDF_VERSION}"
# Only the two shared libs the native binary dlopens for the AWT/font path.
# Fonts + java.home stub + fontconfig config + the launcher are bundled INSIDE
# /opt/odl by the build stage, so no fonts/fontconfig packages are needed and
# COPY-from consumers need only these two libs (see README, AWT / font support).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libfreetype6 \
        libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/odl /opt/odl
COPY LICENSE NOTICE /opt/odl/
# /opt/odl/odl is the self-contained launcher (sets -Djava.home / FONTCONFIG_FILE
# relative to itself). Consumers just run it — no -D flags, no font setup.
ENTRYPOINT ["/opt/odl/odl"]
# no extra args → CLIMain prints usage and exits 0
CMD []
