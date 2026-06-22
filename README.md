# opendataloader-pdf-native

A **JVM-free** GraalVM native-image build of the
[opendataloader-pdf](https://github.com/opendataloader-project/opendataloader-pdf)
CLI, published as a public container image.

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
image is never published.

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
# ... your runtime ...
COPY --from=pdf-native /opt/odl /opt/odl   # native binary + JDK .so, no JVM build
# then exec /opt/odl/odl as a subprocess
```

`/opt/odl/odl` accepts the same arguments as the upstream CLI
(`org.opendataloader.pdf.cli.CLIMain`).

## How it's built

1. The exact upstream shaded CLI jar is extracted from the published pip wheel
   (`opendataloader-pdf==<VERSION>`) — same artifact the official Python wrapper
   runs.
2. GraalVM native-image (CE 21) compiles it using reflection/resource config
   collected with the native-image tracing agent (`native-image/agent-config/`).
   The engine uses veraPDF's low-level parser (not its reflective validation
   model), so the reflection surface is tiny.
3. The parity gate runs; on success the image is published to GHCR.

`-march=x86-64-v2` is used for broad x86-64 compatibility.

## Notes / limitations

- Built for **linux/amd64** only.
- The hybrid / OCR path (which calls an external backend over HTTP) is compiled
  in but not parity-verified here; if you use it, validate separately.
- AWT/ImageIO (image extraction, annotated-PDF output) initialize at run time;
  `libfreetype6` + `libfontconfig1` are included so those paths work, but the
  default json/markdown path never touches AWT.

## Updating the opendataloader-pdf version

Bump [`VERSION`](VERSION) and push to `main`; the workflow builds, runs the
parity gate, and publishes `:<version>` and `:latest`.

## License

The build scripts and configuration in this repository are licensed under
[Apache-2.0](LICENSE). The compiled binary contains opendataloader-pdf and its
dependencies under their own licenses (see [NOTICE](NOTICE)).
