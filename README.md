# Static libarrow built with Rtools45

Experiment: build a static [Apache Arrow](https://arrow.apache.org/) C++
library for Windows (x86_64 and aarch64) using **only** the compilers and
static libraries that ship with [Rtools45](https://cran.r-project.org/bin/windows/Rtools/rtools45/rtools.html)
and Rtools45-aarch64, instead of external mingw-w64 packages from pacman.

The cmake configuration mirrors the
[mingw-w64-arrow PKGBUILD](https://github.com/r-windows/ucrt-libs/blob/master/mingw-w64-arrow/PKGBUILD)
from r-windows/ucrt-libs as closely as possible.

## Dependency sources

The build script probes the rtools toolchain prefix and uses `SYSTEM` for
each dependency whose static library is included with rtools, and Arrow's
`BUNDLED` build for the rest. With rtools45 that works out to:

| From rtools (SYSTEM)        | Built by arrow (BUNDLED)                     |
|-----------------------------|----------------------------------------------|
| zlib, bzip2, zstd, lz4      | snappy, utf8proc, xsimd, mimalloc            |
| brotli, re2 (via grpc deps) | thrift, AWS SDK, google-cloud-cpp (+ crc32c) |
| curl, openssl, boost        | rapidjson, flatbuffers, nlohmann-json (if absent) |

Thrift and the AWS SDK are forced to `BUNDLED` regardless, for the same
reasons as in the PKGBUILD. The bundled pieces are merged into
`libarrow_bundled_dependencies.a` in the installed tree.

## CI

`.github/workflows/build.yml` runs on `windows-latest` (x86_64) and
`windows-11-arm` (aarch64, free for public repos only). Each job:

1. Downloads the Rtools45 installer from CRAN and installs it silently.
2. Runs `build-arrow.sh` inside the rtools msys2 bash (login shell with
   `CHERE_INVOKING=yes` and `MSYS2_PATH_TYPE=inherit`).
3. Uploads `libarrow-<version>-rtools45-<arch>.tar.gz` as an artifact.

The build (bundled AWS SDK + google-cloud-cpp included) takes roughly 1.5–3
hours on the 4-core hosted runners.

## Local build

From an Rtools45 installation:

```
c:\rtools45\usr\bin\bash.exe -l build-arrow.sh
```

Environment variables: `ARROW_VERSION` overrides the arrow release (checksum
verification is skipped for non-default versions), `ARROW_LINK_TEST=0` skips
the compile/link/run smoke test at the end.

## Notes

- The rtools45 x86_64 toolchain is gcc-based; rtools45-aarch64 is
  llvm/clang-based (llvm-mingw). The script picks the compiler accordingly.
- `bcrypt-compat.h` is force-included to provide BCrypt algorithm
  pseudo-handles on older mingw-w64 headers; it is a no-op on current ones.
- The bundled xsimd is bumped to 14.3.0 (the 14.2.0 pinned by arrow 25.0.0
  includes the MSVC-only `<arm64_neon.h>` on Windows aarch64).
- The `.pc` files in the artifact have their prefix rewritten to the rtools
  toolchain mount (`/x86_64-w64-mingw32.static.posix` or
  `/aarch64-w64-mingw32.static.posix`), so the tarball can be extracted
  straight into the toolchain, or used standalone via `ARROW_HOME`.
- The rtools installer filenames in the workflow (`rtools45-6768-6492.exe`)
  are pinned; CRAN removes old builds when rtools is updated, so bump these
  when the workflow's download step starts failing.
