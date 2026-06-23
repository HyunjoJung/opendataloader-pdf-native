# opendataloader-pdf-native

A **JVM-free** GraalVM native-image build of the
[opendataloader-pdf](https://github.com/opendataloader-project/opendataloader-pdf)
CLI, published as a public, **multi-arch** (`linux/amd64` + `linux/arm64`)
container image.

> **Unofficial.** Not affiliated with, endorsed by, or supported by the
> opendataloader project or Hancom Inc. See [NOTICE](NOTICE) for attribution.

## Why

opendataloader-pdf is an excellent rule-based PDF extractor (reading order,
heading hierarchy, table reconstruction, markdown/JSON output) — but it ships as
a **Java** engine (built on veraPDF), so every invocation pays a JVM cold start
(~1.3 s) and holds a large JVM heap (~370 MB RSS). For per-file CLI / sidecar
usage that overhead dominates.

This repo compiles the CLI ahead-of-time with GraalVM native-image:

| | native | `java -jar` |
|---|---|---|
| cold start | **~0.3 s** | ~1.3 s |
| peak RSS (sub-MB PDF) | **~140 MB** | ~370 MB |
| runtime | single binary | JRE + jar |

The engine is unchanged — only the JVM runtime is removed.

## Correctness: byte-identical output

The native binary must produce **byte-for-byte identical** JSON and Markdown to
`java -jar` on the `--format json,markdown --image-output off` path (downstream
consumers parse the reconstructed tables — any divergence silently corrupts
them). Every build runs a **parity gate** (`test/parity.sh`): it runs both
engines over the test PDFs and fails the build on any mismatch, so a divergent
image is never published. The gate runs on **each arch's** native build (arm64
native vs arm64 `java -jar`, and likewise for amd64), so neither arch can ship a
binary that diverges from the JVM reference on that arch.

> The parity gate uses generic English table/heading PDFs. If your workload has
> language- or font-specific content (e.g. Korean CMaps), re-verify parity on a
> representative sample before pinning a new version.

## Usage

### As a standalone tool

```bash
docker run --rm -v "$PWD:/data" \
  ghcr.io/hyunjojung/opendataloader-pdf-native:2.4.7 \
  --format json,markdown --image-output off --output-dir /data /data/your.pdf
```

### As a binary carrier (copy into your own image)

```dockerfile
FROM ghcr.io/hyunjojung/opendataloader-pdf-native:2.4.7 AS pdf-native

FROM debian:12-slim
# /opt/odl is self-contained (bundled fonts + java.home stub + launcher). A
# consumer only needs the two shared libs the binary dlopens for the font path:
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfreetype6 libfontconfig1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=pdf-native /opt/odl /opt/odl   # binary + JDK .so + fonts + stub + launcher
# then just run the launcher — no -D flags, no font setup:
#   /opt/odl/odl --format json,markdown --image-output off --output-dir <out> <pdf>
```

`/opt/odl/odl` is a self-contained launcher: it sets `-Djava.home` /
`FONTCONFIG_FILE` relative to its own dir, then execs the native binary
(`/opt/odl/odl.bin`) with the upstream CLI args
(`org.opendataloader.pdf.cli.CLIMain`). See [AWT / font support](#awt--font-support).

## How it's built

1. The exact upstream shaded CLI jar is extracted from the published pip wheel
   (`opendataloader-pdf==<VERSION>`) — same artifact the official Python wrapper
   runs.
2. GraalVM native-image (CE 21) compiles it using reflection/resource config
   collected with the native-image tracing agent (`native-image/agent-config/`).
   The engine uses veraPDF's low-level parser (not its reflective validation
   model), so the reflection surface is tiny.
3. The parity gate runs; on success the per-arch image is pushed by digest.
4. The per-arch digests are stitched into one **multi-arch manifest**
   (`:<version>` + `:latest`) and published to GHCR.

native-image AOT-compiles for the build host's CPU (no cross-compile), so each
arch builds on its own native runner — `linux/amd64` on an x86 runner,
`linux/arm64` on an arm runner. The instruction-set baseline is chosen per arch:
`-march=x86-64-v2` on x86-64 (broad compatibility) and `-march=compatibility`
(GraalVM's portable baseline) on aarch64.

## Notes / limitations

- Published as a **multi-arch manifest** (`linux/amd64` + `linux/arm64`); Docker
  pulls the matching arch automatically.
- The hybrid / OCR path (which calls an external backend over HTTP) is compiled
  in but not parity-verified here; if you use it, validate separately.
- Self-contained: needs only `libfreetype6` + `libfontconfig1` at runtime;
  everything else for the AWT/font path is bundled in `/opt/odl` (see below).

## AWT / font support

Even with `--image-output off`, the engine touches the AWT/font stack on some
PDFs (font metrics for layout). Under GraalVM native-image this fatally crashes
("Fatal error reported via JNI: Could not allocate library name") unless three
things are in place — and **the launcher `/opt/odl/odl` provides all three
itself**, so neither `docker run` nor a COPY-from consumer configures anything:

1. **A stub `java.home`** (bundled at `/opt/odl/java-home`), passed via
   `-Djava.home`. GraalVM leaves `java.home` unset, so `AWTIsHeadless()` fails and
   the error cascades into the misleading message above. It **cannot** be baked at
   build time (breaks the builder), so the launcher sets it at runtime.
   (oracle/graal #7711, #9485)
2. **Fonts** — DejaVu is bundled at `/opt/odl/fonts`, exposed via a bundled
   `FONTCONFIG_FILE` (`/opt/odl/fontconfig/fonts.conf`, cache in `/tmp`). Without
   ≥1 font, fontconfig reports "head is null" and font init fails. No system
   fonts or `fc-cache` needed.
3. **`-Dsun.jnu.encoding=UTF-8`** (encoding-init path, oracle/graal #8475).

The build also bakes the AWT JNI config (`native-image/agent-config-awt/`:
`System.load`, `GraphicsEnvironment.isHeadless`, `sun.java2d.Disposer`) and
`-H:+AddAllCharsets`. The only thing a consumer provides is the two shared libs
the binary dlopens: `libfreetype6` + `libfontconfig1`.

## Updating the opendataloader-pdf version

The build workflow **tracks upstream automatically**: a daily scheduled run
checks PyPI for the latest stable `opendataloader-pdf`, and if it is newer than
[`VERSION`](VERSION) it builds + publishes that version **unattended**, then
commits the bump. The publish only happens *after* the per-arch parity gate
passes — a release that diverges from `java -jar` fails the build and is never
published (and is retried on the next run) — so this is safe to leave running on
its own.

To pin, downgrade, or force a specific version by hand, edit
[`VERSION`](VERSION) and push to `main` (or trigger the workflow via
`workflow_dispatch`).

## License

The build scripts and configuration in this repository are licensed under
[Apache-2.0](LICENSE). The compiled binary contains opendataloader-pdf and its
dependencies under their own licenses (see [NOTICE](NOTICE)).
