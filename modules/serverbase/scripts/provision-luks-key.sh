#!/usr/bin/env bash
set -euo pipefail

# Puts the root LUKS passphrase where disko's format step will read it, before the unattended install runs.
#
# WHY THIS EXISTS. The ISO's unattended-install service declares `Conflicts=getty@tty1 serial-getty@ttyS0`, so
# by the time it runs there is no shell anywhere to type into and no getty to type at. disko, meanwhile, reads
# `passwordFile` and calls `cryptsetup luksFormat --key-file` with it. If the file is not there, luksFormat
# falls back to asking - and the install dies with `Nothing to read on input` against a console nobody owns.
# So the passphrase has to be MATERIALISED, not typed, and this is what materialises it.
#
# Sources, in order, first hit wins:
#   1. the file already being there - a shell that got in first, or an operator who broke the install
#      deliberately to place it. Kept as the escape hatch precisely because everything else here is automatic.
#   2. removable media, the same way the age key arrives (install-sops-key.sh). Per-machine name first,
#      shared name second, `nixos-secrets/` subdirectory or the filesystem root, either layout.
#   3. a WELL-KNOWN, PUBLIC passphrase - only on a dev image, see below.
#   4. asking, on the console. The honest last resort for a prod machine being reinstalled: whoever is doing
#      that is standing at it.
#
# ON 3. It is enabled by LUKS_KEY_ALLOW_WELLKNOWN, which lib.nix sets from `isDev` and from nothing else. The
# value is in this file, in a public repository, and that is fine for exactly one thing: a throwaway VM whose
# whole purpose is to prove that a machine boots with an encrypted root. It is a FIXED value rather than a
# random one on purpose - a random passphrase would encrypt a VM nobody can then unlock, and the reboot that
# asks for it is the test. Anything that is not a dev image never reaches this branch and falls through to 4.
#
# The scan duplicates install-sops-key.sh's device walk. Deliberately, for now: that script runs in the initrd
# of every machine on every boot, and factoring the two together is not a change to make in the middle of a
# disk-encryption migration. See PLAN_ENCRYPTION.md's closing tasks.

key_file="${LUKS_KEY_FILE:?LUKS_KEY_FILE must be set}"
host_name="${LUKS_KEY_HOSTNAME:-}"
allow_wellknown="${LUKS_KEY_ALLOW_WELLKNOWN:-0}"
wellknown_passphrase="test"

key_candidates=()
# Not `[ -n ... ] && key_candidates+=(...)`: under `set -e` a false test on the last line of the script would
# be the script's exit status. Same trap install-sops-key.sh documents.
if [ -n "$host_name" ]; then
  key_candidates+=("$host_name.lukskey")
fi
key_candidates+=("luks.key")

tmpmnt="${TMPDIR:-/tmp}/luksmnt"
found=0

copy_if_has_key() {
  # $1 is a mounted path
  local candidate source
  for candidate in "${key_candidates[@]}"; do
    for source in "$1/nixos-secrets/$candidate" "$1/$candidate"; do
      [ -f "$source" ] || continue
      # `tr -d` the trailing newline: a passphrase file written with an editor gains one, and cryptsetup takes
      # --key-file BYTE FOR BYTE. A newline in the file at format time means a newline in the passphrase, which
      # nobody will ever type at the prompt, which is a machine that formats fine and never unlocks again.
      tr -d '\n' < "$source" > "$key_file"
      chmod 0400 "$key_file"
      echo "Using $candidate from $1"
      found=1
      return 0
    done
  done
  return 1
}

try_mount_and_check() {
  local dev="$1" fstype mountpoint
  [ -b "$dev" ] || return 1

  # Skip anything that is not a filesystem (a bare partition table, say) rather than letting mount log a kernel
  # error for each one.
  fstype=$(blkid -o value -s TYPE "$dev" || true)
  [ -n "$fstype" ] || return 1

  mountpoint=$(findmnt -n -o TARGET --source "$dev" | head -n 1 || true)
  if [ -n "$mountpoint" ]; then
    copy_if_has_key "$mountpoint" && return 0
    return 1
  fi

  if mount -o ro "$dev" "$tmpmnt" 2>/dev/null; then
    copy_if_has_key "$tmpmnt" && { umount "$tmpmnt" || true; return 0; }
    umount "$tmpmnt" || true
  fi
  return 1
}

search_for_key_in_drives() {
  local d link dev
  for d in /dev/sd?1 /dev/sd?2 /dev/sd? /dev/vd?1 /dev/vd?2 /dev/nvme?n?p1 /dev/nvme?n?p2 /dev/sr?; do
    [ -e "$d" ] || continue
    try_mount_and_check "$d" && return 0
  done
  for link in /dev/disk/by-label/* /dev/disk/by-uuid/*; do
    [ -e "$link" ] || continue
    dev=$(readlink -f "$link")
    try_mount_and_check "$dev" && return 0
  done
  return 1
}

ask_for_passphrase() {
  local first second
  while true; do
    echo
    echo "No root passphrase found for this install."
    echo "It will encrypt $1 and there is no way to recover it if it is lost - record it FIRST."
    printf 'Passphrase: '
    read -rs first; echo
    printf 'Again: '
    read -rs second; echo
    if [ -z "$first" ]; then
      echo "Empty. Try again."
    elif [ "$first" != "$second" ]; then
      echo "They do not match. Try again."
    else
      printf %s "$first" > "$key_file"
      chmod 0400 "$key_file"
      return 0
    fi
  done
}

echo "====== Providing the root LUKS passphrase at $key_file"

if [ -s "$key_file" ]; then
  echo "Already present, leaving it alone."
  exit 0
fi

mkdir -p "$tmpmnt"
echo "Looking on removable media for: ${key_candidates[*]}"
search_for_key_in_drives || true

if [ "$found" -eq 1 ]; then
  echo "Root passphrase taken from removable media."
  exit 0
fi

if [ "$allow_wellknown" = "1" ]; then
  printf %s "$wellknown_passphrase" > "$key_file"
  chmod 0400 "$key_file"
  echo "No key on media. This is a DEV image, so using the well-known passphrase '$wellknown_passphrase'."
  echo "It is public, it is in the repository, and it is fine here and nowhere else."
  exit 0
fi

ask_for_passphrase "${LUKS_KEY_TARGET_DESCRIPTION:-the root filesystem}"
echo "Root passphrase recorded for the format step."
