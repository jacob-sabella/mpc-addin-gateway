#!/usr/bin/env bash
# Downloads the Caddy release named in upstream.env (the release tarball for one CPU, and the licence) into a folder,
# refuses them unless their SHA-256 matches upstream.env, and takes the caddy binary out of the tarball. Nothing
# downloaded is committed.
# Usage: tools/fetch-upstream.sh armv7|aarch64 <folder>
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 armv7|aarch64 <folder>" >&2; exit 2; }
arch=$1 out=$2
. ./upstream.env
v=${CADDY_TAG#v}
case "$arch" in
    armv7) asset=caddy_${v}_linux_armv7.tar.gz sum=$CADDY_SHA256_ARMV7 want="ELF 32-bit LSB executable, ARM" ;;
    aarch64) asset=caddy_${v}_linux_arm64.tar.gz sum=$CADDY_SHA256_ARM64 want="ELF 64-bit LSB executable, ARM aarch64" ;;
    *) echo "unknown arch $arch" >&2; exit 2 ;;
esac
mkdir -p "$out"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
get() {   # url, file, sha256
    curl -fsSL --retry 3 -o "$T/$2" "$1"
    got=$(sha256sum "$T/$2" | cut -d' ' -f1)
    [ "$got" = "$3" ] || { echo "$2 from $1: sha256 $got, upstream.env expects $3" >&2; exit 1; }
}
get "https://github.com/$CADDY_REPO/releases/download/$CADDY_TAG/$asset" caddy.tar.gz "$sum"
get "https://raw.githubusercontent.com/$CADDY_REPO/$CADDY_TAG/LICENSE" LICENSE-caddy "$CADDY_SHA256_LICENSE"
tar -xzf "$T/caddy.tar.gz" -C "$T" caddy
# it must not depend on the device's libraries: a static executable for the device's CPU
info=$(file -b "$T/caddy")
case "$info" in "$want"*"statically linked"*) ;; *) echo "caddy is not a static $arch executable: $info" >&2; exit 1 ;; esac
mv -f "$T/caddy" "$out/caddy"; chmod 755 "$out/caddy"
mv -f "$T/LICENSE-caddy" "$out/LICENSE-caddy"
echo "Caddy $CADDY_TAG ($arch): $out/caddy ($(du -h "$out/caddy" | cut -f1))"
