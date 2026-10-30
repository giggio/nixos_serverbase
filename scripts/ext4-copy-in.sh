#!/usr/bin/env nix
#!nix shell --ignore-environment nixpkgs#bash nixpkgs#coreutils nixpkgs#util-linux nixpkgs#e2fsprogs nixpkgs#findutils nixpkgs#diffutils nixpkgs#gnugrep nixpkgs#jq --command bash
# Copy a file or a directory tree into an ext4 partition of a raw disk image, owned by root.
#
# Usage: ext4-copy-in.sh <image.raw> <partition-number> <source> <destination>
#
# <destination> is an absolute path inside the filesystem and must not exist yet; its missing parents are created.
# Directories are created 0755, files keep the source's mode, symlinks are copied as symlinks, and everything is owned
# by root.
#
# debugfs writes the filesystem in place, with no root and without libguestfs, whose appliance boots a VM for what is a
# few file copies. debugfs exits 0 whatever its commands did, so the copy is read back and compared before the script
# says it worked, and e2fsck checks the filesystem afterwards.

set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ $# -ne 4 ]; then
  echo "Usage: $0 <image.raw> <partition-number> <source> <destination>" >&2
  exit 1
fi
image=$1
partition_number=$2
source=$3
destination=${4%/}

[ -f "$image" ] || die "$image is not a file"
[ -e "$source" ] || die "$source does not exist"
[[ $destination == /?* ]] || die "$destination is not an absolute path below /"
# debugfs takes a double-quoted argument as one word, with no way to escape a quote inside it.
unquotable=$(find "$source" "(" -name '*"*' -o -name $'*\n*' ")" -print -quit)
[ -z "$unquotable" ] || die "cannot copy a path with a double quote or a newline: $unquotable"
[[ $destination != *[\"$'\n']* ]] || die "cannot copy to a path with a double quote or a newline: $destination"
unsupported=$(find "$source" ! -type f ! -type d ! -type l -print -quit)
[ -z "$unsupported" ] || die "$unsupported is neither a file, a directory nor a symlink"

partition=$(sfdisk --json "$image" | jq --argjson n "$partition_number" '.partitiontable | {start: .partitions[$n - 1].start, sectorsize}')
[ "$(jq '.start' <<<"$partition")" != null ] || die "$image has no partition $partition_number"
filesystem="$image?offset=$(($(jq '.start * .sectorsize' <<<"$partition")))"

debugfs -R "stats" "$filesystem" >/dev/null 2>&1 || die "partition $partition_number of $image is not an ext filesystem"
debugfs -R "stat \"$destination\"" "$filesystem" 2>&1 | grep -q 'File not found by ext2_lookup' ||
  die "$destination already exists in partition $partition_number of $image"

work_dir=$(mktemp -d "$image.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
commands="$work_dir/commands"
log="$work_dir/debugfs.log"

quote() {
  printf '"%s"' "$1"
}

{
  # mkdir fails on an ancestor that already exists, which is harmless: only the read-back below decides.
  ancestor=""
  IFS=/ read -ra parts <<<"${destination#/}"
  for part in "${parts[@]::${#parts[@]}-1}"; do
    ancestor="$ancestor/$part"
    echo "mkdir $(quote "$ancestor")"
  done
  if [ -d "$source" ]; then
    echo "mkdir $(quote "$destination")"
    # Pre-order, so every directory is created before what goes in it.
    find "$source" -mindepth 1 -printf '%y\0%P\0%l\0' | while IFS= read -r -d '' type && IFS= read -r -d '' path && IFS= read -r -d '' target; do
      case $type in
      d) echo "mkdir $(quote "$destination/$path")" ;;
      f) echo "write $(quote "$source/$path") $(quote "$destination/$path")" ;;
      l) echo "symlink $(quote "$destination/$path") $(quote "$target")" ;;
      esac
    done
  else
    echo "write $(quote "$source") $(quote "$destination")"
  fi
} >"$commands"

debugfs -w -f "$commands" "$filesystem" >"$log" 2>&1

if [ -d "$source" ]; then
  # rdump cannot chown what it dumps without root and says so for every file, which is expected.
  mkdir "$work_dir/readback"
  debugfs -R "rdump $(quote "$destination") $(quote "$work_dir/readback")" "$filesystem" >/dev/null 2>&1
  readback="$work_dir/readback/${destination##*/}"
  diff --recursive --no-dereference "$source" "$readback" >"$work_dir/diff" 2>&1 ||
    {
      cat "$log" "$work_dir/diff" >&2
      die "the copy of $source in $image does not match the source"
    }
else
  # Streamed and not dumped to a file, so a key copied in never touches the disk outside the image.
  cmp --quiet "$source" <(debugfs -R "cat $(quote "$destination")" "$filesystem" 2>/dev/null) ||
    {
      cat "$log" >&2
      die "the copy of $source in $image does not match the source"
    }
fi

e2fsck -f -n "$filesystem" >"$work_dir/e2fsck.log" 2>&1 ||
  {
    cat "$work_dir/e2fsck.log" >&2
    die "e2fsck found errors in partition $partition_number of $image"
  }
