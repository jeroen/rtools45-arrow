#!/usr/bin/env bash
# Build a static libarrow for Windows using only the compilers and static
# libraries that ship with Rtools45 (x86_64, gcc) or Rtools45-aarch64 (clang).
# Dependencies that rtools does not include (snappy, utf8proc, thrift, the
# AWS SDK, xsimd, ...) are built from source via Arrow's BUNDLED mechanism
# and end up in libarrow_bundled_dependencies.a.
#
# Adapted from:
#   https://github.com/r-windows/ucrt-libs/blob/master/mingw-w64-arrow/PKGBUILD
#
# Run from the rtools msys2 shell:
#   c:\rtools45\usr\bin\bash.exe -l build-arrow.sh
set -euo pipefail

ARROW_VERSION="${ARROW_VERSION:-25.0.0}"
ARROW_SHA256="12afc2dc8137bdd4a68876cec939f664c9d55cfc7b75f55b45163ebb4e344d81"

cd "$(dirname "$0")"
ROOT="$PWD"

#--- Locate the rtools45 toolchain ------------------------------------------
TOOLCHAIN=""
for t in /aarch64-w64-mingw32.static.posix /x86_64-w64-mingw32.static.posix; do
  if [ -d "$t/bin" ]; then TOOLCHAIN="$t"; break; fi
done
if [ -z "$TOOLCHAIN" ]; then
  echo "ERROR: no rtools45 toolchain found under / — run this from the rtools45 bash shell" >&2
  exit 1
fi
export PATH="$TOOLCHAIN/bin:/usr/bin:$PATH"
PREFIX_WIN="$(cygpath -am "$TOOLCHAIN")"

case "$TOOLCHAIN" in
  /aarch64-*) ARCH=aarch64 ;;
  *)          ARCH=x86_64  ;;
esac

# rtools45 x86_64 is gcc-based, rtools45-aarch64 is llvm/clang-based
if command -v gcc >/dev/null 2>&1; then
  export CC=gcc CXX=g++
elif command -v clang >/dev/null 2>&1; then
  export CC=clang CXX=clang++
else
  echo "ERROR: no C compiler found in $TOOLCHAIN/bin" >&2
  exit 1
fi
command -v cmake >/dev/null 2>&1 || { echo "ERROR: cmake not found on PATH" >&2; exit 1; }

echo "== Toolchain: $TOOLCHAIN ($ARCH)"
echo "== Compiler:  $($CC --version | head -1)"
echo "== CMake:     $(command -v cmake) ($(cmake --version | head -1))"
echo "== Make:      $(command -v make)"

#--- Download and extract the arrow sources ---------------------------------
SRCDIR="$ROOT/src/apache-arrow-$ARROW_VERSION"
TARBALL="apache-arrow-$ARROW_VERSION.tar.gz"
if [ ! -d "$SRCDIR" ]; then
  mkdir -p "$ROOT/src"
  if [ ! -f "$ROOT/src/$TARBALL" ]; then
    curl -fsSL --retry 3 -o "$ROOT/src/$TARBALL" \
      "https://github.com/apache/arrow/releases/download/apache-arrow-$ARROW_VERSION/$TARBALL"
  fi
  if [ "$ARROW_VERSION" = "25.0.0" ]; then
    (cd "$ROOT/src" && echo "$ARROW_SHA256  $TARBALL" | sha256sum -c -)
  else
    echo "NOTE: non-default ARROW_VERSION, skipping checksum verification"
  fi
  tar xf "$ROOT/src/$TARBALL" -C "$ROOT/src"
fi

# gcc 14 libstdc++ (rtools45 x86_64) defines __cpp_lib_chrono >= 201907L but
# its std::formatter<std::chrono::zoned_time<days,...>> is broken, so arrow's
# temporal kernels fail to compile. Only use std::chrono on gcc >= 15 (msys2
# builds work there); older gcc falls back to the vendored date library.
# Clang/libc++ (rtools45-aarch64) never takes the std::chrono path anyway.
CHRONO_H="$SRCDIR/cpp/src/arrow/util/chrono_internal.h"
if grep -q '^#if defined(_WIN32) && defined(__cpp_lib_chrono) && __cpp_lib_chrono >= 201907L$' "$CHRONO_H"; then
  sed -i 's/^#if defined(_WIN32) && defined(__cpp_lib_chrono) && __cpp_lib_chrono >= 201907L$/#if defined(_WIN32) \&\& defined(__cpp_lib_chrono) \&\& __cpp_lib_chrono >= 201907L \&\& (defined(__clang__) || !defined(__GNUC__) || __GNUC__ >= 15)/' "$CHRONO_H"
fi

# xsimd 14.2.0 includes the MSVC-only <arm64_neon.h> on Windows aarch64,
# which mingw-w64 toolchains don't provide. Fixed upstream in xsimd 14.3.0.
if grep -q '^ARROW_XSIMD_BUILD_VERSION=14\.2\.0' "$SRCDIR/cpp/thirdparty/versions.txt"; then
  sed -i -e 's/^ARROW_XSIMD_BUILD_VERSION=.*/ARROW_XSIMD_BUILD_VERSION=14.3.0/' \
         -e 's/^ARROW_XSIMD_BUILD_SHA256_CHECKSUM=.*/ARROW_XSIMD_BUILD_SHA256_CHECKSUM=b3d50e7a73fbf4642ceef30131c93414901d69eee41c2a5302db650b03e2c792/' \
      "$SRCDIR/cpp/thirdparty/versions.txt"
fi

#--- Pick SYSTEM (rtools) vs BUNDLED for each dependency --------------------
# Use the static library from the rtools toolchain when it exists, otherwise
# let arrow build its own copy. Thrift and the AWS SDK are always bundled,
# matching the ucrt-libs PKGBUILD.
src_for() {
  if [ -f "$TOOLCHAIN/lib/$1" ]; then echo SYSTEM; else echo BUNDLED; fi
}
ZLIB_SRC=$(src_for libz.a)
ZSTD_SRC=$(src_for libzstd.a)
LZ4_SRC=$(src_for liblz4.a)
BZIP2_SRC=$(src_for libbz2.a)
BROTLI_SRC=$(src_for libbrotlidec.a)
RE2_SRC=$(src_for libre2.a)
SNAPPY_SRC=$(src_for libsnappy.a)
UTF8PROC_SRC=$(src_for libutf8proc.a)

echo "== Dependency sources (SYSTEM = from rtools, BUNDLED = built by arrow):"
printf '   %-10s %s\n' \
  zlib "$ZLIB_SRC" zstd "$ZSTD_SRC" lz4 "$LZ4_SRC" bz2 "$BZIP2_SRC" \
  brotli "$BROTLI_SRC" re2 "$RE2_SRC" snappy "$SNAPPY_SRC" utf8proc "$UTF8PROC_SRC" \
  thrift BUNDLED awssdk BUNDLED

#--- Configure and build ----------------------------------------------------
# We use static cURL (from rtools) in the bundled google-cloud-cpp, which
# needs CURL_STATICLIB. Use CXXFLAGS instead of ARROW_CXXFLAGS because
# ARROW_CXXFLAGS is not passed on to ExternalProjects.
export CXXFLAGS="${CXXFLAGS:-} -DCURL_STATICLIB"
# BCrypt algorithm pseudo-handles are missing from mingw-w64 headers before
# v11; harmless no-op on newer headers thanks to the #ifndef guards.
export CXXFLAGS="$CXXFLAGS -include $(cygpath -am "$ROOT/bcrypt-compat.h")"
# The rtools libutf8proc is static, but Findutf8proc.cmake doesn't set the
# appropriate compiler definition.
export CPPFLAGS="-DUTF8PROC_STATIC"

DIST="$ROOT/dist"
DIST_WIN="$(cygpath -am "$DIST")"
rm -rf "$ROOT/build" "$DIST"

# CMAKE_UNITY_BUILD is OFF as otherwise some compute functionality segfaults.
# Thrift and the AWS SDK are bundled because rtools does not ship them (and
# the msys2/rtools-packages versions were unmaintained anyway, see PKGBUILD).
cmake -S "$SRCDIR/cpp" -B "$ROOT/build" \
  -G "MSYS Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$DIST_WIN" \
  -DCMAKE_PREFIX_PATH="$PREFIX_WIN" \
  -DCMAKE_UNITY_BUILD=OFF \
  -DARROW_PACKAGE_PREFIX="$PREFIX_WIN" \
  -DARROW_DEPENDENCY_USE_SHARED=OFF \
  -DARROW_ACERO=ON \
  -DARROW_BUILD_SHARED=OFF \
  -DARROW_BUILD_STATIC=ON \
  -DARROW_BUILD_UTILITIES=OFF \
  -DARROW_COMPUTE=ON \
  -DARROW_CSV=ON \
  -DARROW_DATASET=ON \
  -DARROW_FILESYSTEM=ON \
  -DARROW_GCS=ON \
  -DARROW_HDFS=OFF \
  -DARROW_JEMALLOC=OFF \
  -DARROW_JSON=ON \
  -DARROW_MIMALLOC=ON \
  -DARROW_PARQUET=ON \
  -DARROW_S3=ON \
  -DARROW_USE_GLOG=OFF \
  -DARROW_VERBOSE_THIRDPARTY_BUILD=ON \
  -DARROW_WITH_BROTLI=ON \
  -DARROW_WITH_BZ2=ON \
  -DARROW_WITH_LZ4=ON \
  -DARROW_WITH_RE2=ON \
  -DARROW_WITH_SNAPPY=ON \
  -DARROW_WITH_ZLIB=ON \
  -DARROW_WITH_ZSTD=ON \
  -DARROW_CXXFLAGS="$CPPFLAGS" \
  -Dzlib_SOURCE="$ZLIB_SRC" \
  -Dzstd_SOURCE="$ZSTD_SRC" \
  -Dlz4_SOURCE="$LZ4_SRC" \
  -DBZip2_SOURCE="$BZIP2_SRC" \
  -DBrotli_SOURCE="$BROTLI_SRC" \
  -Dre2_SOURCE="$RE2_SRC" \
  -DSnappy_SOURCE="$SNAPPY_SRC" \
  -Dutf8proc_SOURCE="$UTF8PROC_SRC" \
  -DThrift_SOURCE=BUNDLED \
  -DAWSSDK_SOURCE=BUNDLED

cmake --build "$ROOT/build" -j "$(nproc)"
cmake --install "$ROOT/build"

# The vendored date library (used since we patch out std::chrono on gcc < 15,
# and always used by clang/libc++) calls CoTaskMemFree from ole32, which the
# generated arrow.pc does not declare for static linking.
sed -i 's/^Libs.private:.*/& -lole32/' "$DIST/lib/pkgconfig/arrow.pc"

#--- Smoke test: compile, link and run a small program ----------------------
# Runs against the dist tree before the .pc prefix rewrite below, so no
# files need to be copied into the toolchain.
if [ "${ARROW_LINK_TEST:-1}" = "1" ]; then
  echo "== Running link test"
  cat > "$ROOT/build/linktest.cpp" <<'EOF'
#include <arrow/api.h>
#include <parquet/arrow/writer.h>
#include <iostream>
int main() {
  arrow::Int64Builder builder;
  if (!builder.AppendValues({1, 2, 3}).ok()) return 1;
  std::shared_ptr<arrow::Array> array = builder.Finish().ValueOrDie();
  std::cout << "libarrow " << arrow::GetBuildInfo().version_string
            << " ok, sum test array length: " << array->length() << std::endl;
  return 0;
}
EOF
  # The rtools pkg-config is an MXE wrapper script that overrides
  # PKG_CONFIG_PATH/PKG_CONFIG_LIBDIR; the only extra search path it honors
  # is the target-specific PKG_CONFIG_PATH_<triplet> variable.
  echo "== pkg-config: $(command -v pkg-config) ($(pkg-config --version))"
  export "PKG_CONFIG_PATH_$(basename "$TOOLCHAIN" | tr '.-' '__')=$DIST/lib/pkgconfig"
  # capture in an assignment so a pkg-config failure aborts under set -e
  PKGFLAGS=$(pkg-config --cflags --libs --static parquet arrow-dataset arrow-acero)
  set -x
  # arrow 25 headers use std::span etc, so consumers must compile as C++20
  $CXX "$ROOT/build/linktest.cpp" -o "$ROOT/build/linktest.exe" \
    -std=c++20 -DARROW_STATIC -DPARQUET_STATIC $PKGFLAGS
  timeout -k 15 300 "$ROOT/build/linktest.exe"
  set +x
fi

#--- Make the installed tree relocatable ------------------------------------
# Point the pkg-config files at the rtools toolchain prefix, so the artifact
# can be extracted into the toolchain (or used standalone via ARROW_HOME).
find "$DIST/lib/pkgconfig" -name '*.pc' -exec sed -i \
  -e "s|$DIST_WIN|$TOOLCHAIN|g" \
  -e "s|$PREFIX_WIN|$TOOLCHAIN|g" {} +

#--- Package -----------------------------------------------------------------
OUTPUT="$ROOT/libarrow-$ARROW_VERSION-rtools45-$ARCH.tar.gz"
tar czf "$OUTPUT" -C "$DIST" .
echo "== Created $OUTPUT"
du -sh "$OUTPUT"
ls -la "$DIST/lib"
