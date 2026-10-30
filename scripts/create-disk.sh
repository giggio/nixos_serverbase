#!/usr/bin/env nix
#!nix shell --ignore-environment nixpkgs#bash nixpkgs#coreutils nixpkgs#util-linux nixpkgs#e2fsprogs nixpkgs#findutils nixpkgs#gnutar nixpkgs#jq nixpkgs#qemu-utils --command bash
# Create a qcow2 disk with a GPT table and one ext4 partition holding the contents of a directory.
#
# Usage: create-disk.sh <output.qcow2> <size> <label> <root-dir>
#
# mke2fs fills the filesystem from a tarball, so the files get root ownership without root and
# without libguestfs, whose appliance boots a VM for what is a few file copies.

set -euo pipefail

if [ $# -ne 4 ]; then
  echo "Usage: $0 <output.qcow2> <size> <label> <root-dir>" >&2
  exit 1
fi
output=$1
size=$2
label=$3
root_dir=$4

mkdir -p "$(dirname "$output")"
# Next to the output and not in TMPDIR, which --ignore-environment drops and is often a tmpfs.
work_dir=$(mktemp -d "$output.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
raw="$work_dir/disk.raw"
tarball="$work_dir/root.tar"

truncate -s "$size" "$raw"
echo 'label: gpt
,,L' | sfdisk --quiet "$raw"
partition=$(sfdisk --json "$raw" | jq '.partitiontable | {start: .partitions[0].start, size: .partitions[0].size, sectorsize}')
sector_size=$(jq '.sectorsize' <<<"$partition")
offset=$(($(jq '.start' <<<"$partition") * sector_size))
partition_kib=$(($(jq '.size' <<<"$partition") * sector_size / 1024))

# Without the `.` entry, so the filesystem root gets mke2fs's 0755 and not the mode of root-dir,
# which is usually a 0700 mktemp directory.
find "$root_dir" -mindepth 1 -maxdepth 1 -printf '%P\0' |
  tar --create --file "$tarball" --directory "$root_dir" --owner=0 --group=0 --numeric-owner \
    --null --files-from -
mke2fs -q -F -t ext4 -L "$label" -E offset="$offset" -d "$tarball" "$raw" "${partition_kib}k"

qemu-img convert -f raw -O qcow2 "$raw" "$output"
