#!/usr/bin/env nix
#!nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#curl nixpkgs#jq nixpkgs#gnused nixpkgs#gnugrep --command bash
# Moves the opi4pro kernel's stable pin to the newest release of its line, if there is one.
#
# Usage: update-kernel-stable.sh [-h|--help] [<nix file>]
#
# Reads kernelStableVersion from modules/config-physical-opi4pro-common.nix, asks kernel.org for the newest release of
# the same line, and when it is newer rewrites kernelStableVersion and the hash of that tarball in the file. The hash
# comes from kernel.org's sha256sums.asc, and is checked in the same run by nix-prefetch-url, which fetches the tarball into
# the store under that hash (so the build finds it there) and fails if it does not match, so a mangled line cannot reach
# the file as a pin that fails only at build time.
#
# It moves nothing else: kernelStableBase follows the vendor tree's SUBLEVEL, and the vendor revision is its own
# decision. It also cannot tell whether the new stable diff still applies to the vendor tree, or whether it touches
# drivers/net/phy/motorcomm.c in a way that matters; building the opi4pro systems is the test. A line that is gone
# from kernel.org's list reached its end of life, which this refuses to paper over.
set -euo pipefail

info() { printf '%s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() { sed -n '3,/^set -euo/{/^set -euo/!s/^# \{0,1\}//p}' "$0"; }
case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

nix_file="${1:-$(dirname "$0")/../modules/config-physical-opi4pro-common.nix}"
[ -f "$nix_file" ] || die "no such file: $nix_file"

pinned="$(sed -nE 's/^ *kernelStableVersion = "([^"]+)";$/\1/p' "$nix_file")"
[[ $pinned =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || die "could not read kernelStableVersion from $nix_file (got '$pinned')"
major="${BASH_REMATCH[1]}"
line="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"

latest="$(curl -sSf https://www.kernel.org/releases.json |
  jq -r --arg line "$line." '[.releases[] | select(.version | startswith($line))][0].version')"
[ "$latest" != null ] || die "$line is no longer listed on kernel.org: it reached its end of life, and needs a new kernel line"
[[ $latest =~ ^$major\.${line#*.}\.[0-9]+$ ]] || die "unexpected release '$latest' for line $line"

if [ "$latest" = "$pinned" ]; then
  info "already on $pinned, the newest $line release"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -n1)" != "$latest" ]; then
  die "pinned $pinned is newer than kernel.org's $latest; not moving backwards"
fi

base_url="https://cdn.kernel.org/pub/linux/kernel/v$major.x"
tarball="linux-$latest.tar.xz"
hex="$(curl -sSf "$base_url/sha256sums.asc" | sed -nE "s/^([0-9a-f]{64})  $tarball\$/\1/p")"
[ -n "$hex" ] || die "no checksum for $tarball in $base_url/sha256sums.asc"
hash="$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$hex")"

info "$pinned -> $latest ($hash)"
info "fetching the tarball into the store, checked against it"
nix-prefetch-url --type sha256 "$base_url/$tarball" "$hash" >/dev/null ||
  die "$tarball does not hash to $hash, which sha256sums.asc says it does"

sed -i -E \
  -e "s|^( *kernelStableVersion = )\"[^\"]+\";\$|\1\"$latest\";|" \
  -e "s|^( *target = kernelOrgTarball kernelStableVersion )\"[^\"]+\";\$|\1\"$hash\";|" \
  "$nix_file"

grep -qF "kernelStableVersion = \"$latest\";" "$nix_file" || die "the version was not written to $nix_file"
grep -qF "target = kernelOrgTarball kernelStableVersion \"$hash\";" "$nix_file" ||
  die "the hash was not written to $nix_file"
info "updated $nix_file; build the opi4pro systems to see that the stable diff still applies"
