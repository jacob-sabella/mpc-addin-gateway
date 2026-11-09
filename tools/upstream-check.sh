#!/usr/bin/env bash
# Whether Caddy has a stable release newer than upstream.env's. If so, rewrites upstream.env for it (the SHA-256 of each
# tarball and of the licence, as downloaded now) and prints the new tag; prints nothing otherwise. Prereleases (betas,
# release candidates) are ignored. Needs gh and curl.
# Usage: tools/upstream-check.sh [<tag>]   (a tag: move to that one instead of the newest)
set -euo pipefail
cd "$(dirname "$0")/.."
. ./upstream.env
tag=${1:-$(gh api "repos/$CADDY_REPO/releases/latest" --jq .tag_name)}
[ -n "$tag" ] && [ "$tag" != null ] || { echo "no stable release found in $CADDY_REPO" >&2; exit 1; }
[ "$tag" != "$CADDY_TAG" ] || exit 0
newest=$(printf '%s\n%s\n' "${CADDY_TAG#v}" "${tag#v}" | sort -V | tail -n 1)
[ $# -eq 1 ] || [ "$newest" = "${tag#v}" ] || exit 0   # never move back to an older one on its own
v=${tag#v}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sum() { curl -fsSL --retry 3 -o "$T/f" "$1" && sha256sum "$T/f" | cut -d' ' -f1; }
# the tarballs must match upstream's own signed checksum list too
curl -fsSL --retry 3 -o "$T/sums" "https://github.com/$CADDY_REPO/releases/download/$tag/caddy_${v}_checksums.txt"
for a in armv7 arm64; do
    curl -fsSL --retry 3 -o "$T/caddy_${v}_linux_$a.tar.gz" "https://github.com/$CADDY_REPO/releases/download/$tag/caddy_${v}_linux_$a.tar.gz"
done
(cd "$T" && grep -E "  caddy_${v}_linux_(armv7|arm64)\.tar\.gz$" sums | sha512sum -c - > /dev/null) ||
    { echo "the tarballs don't match $tag's checksums file" >&2; exit 1; }
armv7=$(sha256sum "$T/caddy_${v}_linux_armv7.tar.gz" | cut -d' ' -f1)
arm64=$(sha256sum "$T/caddy_${v}_linux_arm64.tar.gz" | cut -d' ' -f1)
lic=$(sum "https://raw.githubusercontent.com/$CADDY_REPO/$tag/LICENSE")
sed -i "s/^CADDY_TAG=.*/CADDY_TAG=$tag/; s/^CADDY_SHA256_ARMV7=.*/CADDY_SHA256_ARMV7=$armv7/; s/^CADDY_SHA256_ARM64=.*/CADDY_SHA256_ARM64=$arm64/; s/^CADDY_SHA256_LICENSE=.*/CADDY_SHA256_LICENSE=$lic/" upstream.env
echo "$tag"
