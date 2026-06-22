#!/usr/bin/env bash
# Parity gate: the native binary MUST produce byte-identical json+markdown to
# `java -jar` for every test PDF, or the build fails (and nothing is published).
# Runs inside the GraalVM build stage (has both `java` and the native binary).
set -uo pipefail

JAR=${JAR:-/build/cli.jar}
ODL=${ODL:-/opt/odl/odl}
PDFS=${PDFS:-/build/test/pdfs}
FLAGS="--quiet --format json,markdown --image-output off"
# Runtime props the native binary needs for the AWT/font path (java.home stub +
# UTF-8 jnu encoding). Harmless on the non-font PDFs; matches the deployed image.
NAT_PROPS="${NAT_PROPS:--Djava.home=/opt/java-home -Dsun.jnu.encoding=UTF-8}"

ok=0; fail=0; n=0
for f in "$PDFS"/*.pdf; do
  [ -e "$f" ] || { echo "no test PDFs in $PDFS"; exit 1; }
  b=$(basename "$f" .pdf); n=$((n+1))
  rm -rf /tmp/j /tmp/x; mkdir -p /tmp/j /tmp/x
  java -Djava.awt.headless=true -jar "$JAR" $FLAGS --output-dir /tmp/j "$f" >/dev/null 2>&1
  "$ODL" $NAT_PROPS                       $FLAGS --output-dir /tmp/x "$f" >/dev/null 2>&1
  for ext in json md; do
    jh=$(sha256sum < "/tmp/j/$b.$ext" 2>/dev/null)
    xh=$(sha256sum < "/tmp/x/$b.$ext" 2>/dev/null)
    if [ -n "$jh" ] && [ "$jh" = "$xh" ]; then
      ok=$((ok+1))
    else
      echo "PARITY MISMATCH: $b.$ext  (jvm=${jh:0:12} native=${xh:0:12})"
      fail=$((fail+1))
    fi
  done
done

echo "parity over $n PDFs: identical=$ok mismatch=$fail"
[ "$ok" -gt 0 ] || { echo "FAIL: no outputs produced"; exit 1; }
[ "$fail" -eq 0 ] || { echo "FAIL: native output diverged from JVM"; exit 1; }
echo "PARITY GATE PASSED"
