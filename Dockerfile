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
COPY native-image/build.sh /build/build.sh
RUN bash /build/build.sh
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
# libfreetype6/libfontconfig1 let AWT load if a feature path needs it (image
# extraction / annotated-pdf); the default json/markdown path never touches AWT.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libfreetype6 \
        libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/odl /opt/odl
COPY LICENSE NOTICE /opt/odl/
ENTRYPOINT ["/opt/odl/odl"]
# no args → CLIMain prints usage and exits 0
CMD []
