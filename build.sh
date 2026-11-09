#!/usr/bin/env bash
# The addin, ready to package: mpc_gateway_addin.so, the script, the settings, addin.manifest, and Caddy's binary and
# licence downloaded by tools/fetch-upstream.sh.
#   ./build.sh          Gen1 (armv7: MPC Live/Live II, One, X, Key 61/37, Force) into build/; the library is built
#                       against glibc 2.31 so it loads on older MPC OS too
#   ./build.sh aarch64  Gen2 (Live III, One G2, Key(s) G2; MPC OS 3.x only, glibc 2.39) into build/aarch64/
# Needs Docker with QEMU for the target, and curl.
set -euo pipefail
cd "$(dirname "$0")"
ARCH=${1:-armv7}
case "$ARCH" in
    armv7) OUT=build PLATFORM=linux/arm/v7 IMAGE=arm32v7/gcc:11-bullseye
           CFLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
           GLIBC_OK='GLIBC_2.[0-9]|GLIBC_2.[12][0-9]|GLIBC_2.3[01]' ;;
    aarch64) OUT=build/aarch64 PLATFORM=linux/arm64 IMAGE=arm64v8/gcc:12-bookworm CFLAGS=""
           GLIBC_OK='GLIBC_2.[0-9]|GLIBC_2.[123][0-9]' ;;
    *) echo "usage: $0 [armv7|aarch64]" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
VER=$(cat VERSION)
docker run --rm --platform "$PLATFORM" -u "$(id -u):$(id -g)" -v "$PWD":/b -w /b \
    -e VER="$VER" -e OUT="$OUT" -e CF="$CFLAGS" -e GLIBC_OK="$GLIBC_OK" "$IMAGE" sh -c '
  set -e
  F="-std=gnu11 -O2 -Wall -Wextra -Werror $CF -DADDIN_VERSION=\"$VER\""
  gcc $F -fPIC -shared -fvisibility=hidden -Wl,-z,defs -Wl,--as-needed -o $OUT/mpc_gateway_addin.so src/gateway.c
  strip --strip-unneeded $OUT/mpc_gateway_addin.so
  max=$(objdump -T $OUT/mpc_gateway_addin.so | grep -o "GLIBC_[0-9.]*" | sort -t. -k2 -n -u | tail -n 1)
  echo "highest glibc symbol version: $max"
  eval "case \"\$max\" in $GLIBC_OK) ;; *) echo \"too new for the oldest MPC OS this targets: \$max\" >&2; exit 1 ;; esac"
  readelf -d $OUT/mpc_gateway_addin.so | grep NEEDED
'
tools/fetch-upstream.sh "$ARCH" "$OUT"
cp -f mpc_gateway_addin.conf addin.manifest gateway-run.sh "$OUT"/   # the release workflow packages it with the installer
ls -l "$OUT"
