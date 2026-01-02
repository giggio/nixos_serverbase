#!/usr/bin/env bash
set -eu

copy_if_has_key() {
  # $1 is mounted path
  if [ -f "$1/nixos-secrets/$key_file_name" ]; then
    cp "$1/nixos-secrets/$key_file_name" "$install_dir/$key_file_name"
    chmod 0400 "$install_dir/$key_file_name"
    found=1
    return 0
  fi
  if [ -f "$1/$key_file_name" ]; then
    cp "$1/$key_file_name" "$install_dir/$key_file_name"
    chmod 0400 "$install_dir/$key_file_name"
    found=1
    return 0
  fi
  return 1
}

try_mount_and_check() {
  dev="$1"
  # try common partition names first; mount read-only
  if [ -b "$dev" ]; then
    if mount -o ro "$dev" "$tmpmnt" 2>/dev/null; then
      copy_if_has_key "$tmpmnt" && {
        echo "sops key found on $dev and copied"
        umount "$tmpmnt" || true
        return 0
      }
      umount "$tmpmnt" || true
    fi
  fi
  return 1
}

search_for_key_in_drives() {
  # quick scan: partition device patterns (common on small drives)
  for d in /dev/sd?1 /dev/sd?2 /dev/sd? /dev/nvme?n?p1 /dev/nvme?n?p2; do
    [ -e "$d" ] || continue
    try_mount_and_check "$d" && break
  done

  # scan by-label / by-uuid symlinks
  for link in /dev/disk/by-label/* /dev/disk/by-uuid/*; do
    [ -e "$link" ] || continue
    dev=$(readlink -f "$link")
    try_mount_and_check "$dev" && break
  done
}

key_file_name=server.agekey
install_dir="/mnt-root/etc/sops/age" # target root (stage-1 exposes /mnt-root)
key_file_destination="$install_dir/$key_file_name"
echo "Starting search for sops key at $key_file_name or to install it there"
if [ -f "$key_file_destination" ]; then
  echo "sops key already installed to $key_file_destination"
  exit 0
fi
mkdir -p "$install_dir"
chmod 0755 "$(dirname "$install_dir")" || true
found=0
tmpmnt=/tmp/usbmnt
mkdir -p "$tmpmnt"

search_for_key_in_drives || true

if [ "$found" -eq 1 ]; then
  echo "sops key installed to $key_file_destination"
  exit 0
else
  echo "sops key not found on removable media."
fi

# interactive fallback loop (useful for manual installs)

while true; do
  echo "$key_file_name not found on removable media."
  echo "Insert USB with 'nixos-secrets/$key_file_name' (or '$key_file_name') then press ENTER to retry."
  echo "Type 'shell' and ENTER to get an interactive shell to copy the file manually."
  echo -e "Type 'exit' and ENTER to stop trying to find the keys and continue to boot.\n"
  printf "> "
  if ! read -r line; then
    # EOF: just exit and allow normal failure / installer to continue
    break
  fi
  if [ "$line" = "exit" ]; then
    echo "sops key not found on removable media, exiting..."
    exit 0
  fi
  if [ "$line" = "shell" ]; then
    $BASH
    # after shell returns, re-run the scanning logic
  fi

  # re-run detection
  found=0
  search_for_key_in_drives || true

  if [ "$found" -eq 1 ]; then
    echo "sops key installed."
    break
  fi
  echo -e "Still not found. Insert media then press ENTER, or type shell or exit.\n"

done
