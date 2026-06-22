#!/usr/bin/env bash
# GraalVM native-image build of the opendataloader-pdf CLI (veraPDF engine).
#
# Produces a JVM-free native binary that is BYTE-IDENTICAL to `java -jar` on the
# json/markdown / image-output=off path. Runs on a dedicated CI runner, so no
# build resource caps here (native-image uses all cores / default heap).
#
# Env (Docker defaults):
#   JAR     = /build/cli.jar       input shaded CLI jar (= the pip runtime jar)
#   OUT     = /opt/odl/odl         output binary (JDK AWT .so emitted alongside)
#   CONFIGS = /build/agent-config  tracing-agent reflect/resource/jni/... config
set -euo pipefail

JAR=${JAR:-/build/cli.jar}
OUT=${OUT:-/opt/odl/odl}
CONFIGS=${CONFIGS:-/build/agent-config}
mkdir -p "$(dirname "$OUT")"

# Resource trees the veraPDF/fontbox parse path loads by name at runtime.
# Trimmed to the json+markdown path; under-including diverges output silently,
# so the parity gate (test/parity.sh) re-verifies after every build.
RES=(
  'font/.*'                       # veraPDF fonts: cmap (incl. Korean), stdmetrics, glyphlist
  'org/apache/fontbox/.*'         # fontbox AFM / cmap / glyphlist
  'org/apache/pdfbox/.*'
  'org/verapdf/.*'                # veraPDF profiles / metadata / policy
  'org/xmlresolver/.*'            # XML catalogs for XMP metadata parsing
  '.*\.pf$'                       # ICC profiles (sRGB/GRAY/PYCC/CIEXYZ)
  '.*/iio-plugin.*\.properties$'  # ImageIO plugin descriptors
  'META-INF/services/.*'          # ServiceLoader providers
)
RES_ARGS=()
for r in "${RES[@]}"; do RES_ARGS+=("-H:IncludeResources=$r"); done

# AWT/ImageIO/ICC must init at RUN time (ICC_ColorSpace etc. cannot live in the
# image heap). With --image-output off these paths are never taken at runtime,
# but they are statically reachable so the closure (and JDK AWT .so) is included.
RUNTIME_INIT=java.awt,java.awt.color,java.awt.image,java.awt.datatransfer,javax.imageio,com.sun.imageio,sun.awt,sun.awt.datatransfer,sun.datatransfer,sun.font,sun.java2d,sun.print
# okhttp/kotlin/okio static state (hybrid HTTP path) is safe to fix at build time.
BUILD_INIT=kotlin,okio,okhttp3.internal.Util

# -march sets the instruction-set baseline for the build arch. native-image
# AOT-compiles for the host (no cross-compile), so each arch builds on its own
# runner. x86-64-v2 is the broad x86 baseline (≈all CPUs since ~2009);
# `compatibility` is GraalVM's portable baseline, used for aarch64 (broad arm64
# compatibility). Override per build with MARCH=… for a specific microarch.
case "$(uname -m)" in
  x86_64 | amd64) MARCH=${MARCH:-x86-64-v2} ;;
  aarch64 | arm64) MARCH=${MARCH:-compatibility} ;;
  *) MARCH=${MARCH:-compatibility} ;;
esac

set -x
native-image \
  -jar "$JAR" \
  -o "$OUT" \
  --no-fallback \
  -H:+UnlockExperimentalVMOptions \
  -H:ConfigurationFileDirectories="$CONFIGS" \
  -H:+ReportExceptionStackTraces \
  -march="$MARCH" \
  -Djava.awt.headless=true \
  --enable-url-protocols=http,https \
  --initialize-at-run-time="$RUNTIME_INIT" \
  --initialize-at-build-time="$BUILD_INIT" \
  "${RES_ARGS[@]}"
