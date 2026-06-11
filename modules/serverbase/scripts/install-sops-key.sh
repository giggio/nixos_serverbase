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
  [ -b "$dev" ] || return 1

  # Check if checking the device is safe/useful:
  # 1. Skip if it is not a filesystem (e.g. partition table only) to avoid kernel errors
  #    "blkid -o value -s TYPE" returns the filesystem type if found.
  fstype=$(blkid -o value -s TYPE "$dev" || true)
  if [ -z "$fstype" ]; then
    return 1
  fi

  # 2. Check if already mounted
  mountpoint=$(findmnt -n -o TARGET --source "$dev" | head -n 1 || true)

  if [ -n "$mountpoint" ]; then
    if copy_if_has_key "$mountpoint"; then
      echo -e "\e[32mSops key found on $dev (already mounted at $mountpoint) and copied\e[0m"
      return 0
    fi
  else
    if mount -o ro "$dev" "$tmpmnt" 2>/dev/null; then
      if copy_if_has_key "$tmpmnt"; then
        echo -e "\e[32mSops key found on $dev and copied\e[0m"
        umount "$tmpmnt" || true
        return 0
      fi
      umount "$tmpmnt" || true
    fi
  fi
  return 1
}

search_for_key_in_drives() {
  # quick scan: partition device patterns (common on small drives)
  for d in /dev/sd?1 /dev/sd?2 /dev/sd? /dev/vd?1 /dev/vd?2 /dev/nvme?n?p1 /dev/nvme?n?p2 /dev/sr?; do
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
install_dir="/sysroot/etc/sops/age" # target root (stage-1 exposes /mnt-root)
key_file_destination="$install_dir/$key_file_name"
echo "Starting search for sops key at $key_file_name or to install it there"
if [ -f "$key_file_destination" ]; then
  echo -e "\e[32mSops key already installed to $key_file_destination\e[0m"
  exit 0
fi
mkdir -p "$install_dir"
chmod 0755 "$(dirname "$install_dir")" || true
found=0
tmpmnt=/tmp/usbmnt
mkdir -p "$tmpmnt"

for i in $(seq 1 6); do
  echo "Searching for sops key, attempt $i"
  search_for_key_in_drives || true
  if [ "$found" -eq 1 ]; then
    break
  fi
  if systemd-detect-virt &>/dev/null; then # todo: check if systemd-detect-virt works in initrd
    sleep 1
  else
    sleep 5
  fi
done

if [ "$found" -eq 1 ]; then
  echo -e "\e[32mSops key installed to $key_file_destination\e[0m"
  exit 0
else
  echo -e "\e[31mSops key not found on removable media.\e[0m"
fi

# interactive fallback loop (useful for manual installs)
while true; do
  echo -e "\e[31m$key_file_name not found on removable media.\e[0m"
  echo "Insert USB with 'nixos-secrets/$key_file_name' (or '$key_file_name') then press ENTER to retry."
  echo "Type:"
  echo -e "* '\e[32mshell\e[0m' to get an interactive shell to copy the file manually."
  echo -e "* '\e[32msh\e[0m' to get a bare shell to copy the file manually."
  echo -e "* '\e[32mq\e[0m' to stop trying to find the keys and continue to boot."
  printf "> "
  if ! read -r line; then
    echo "Select an option:"
    continue
  fi
  if [ "$line" = "q" ]; then
    echo "Sops key not found on removable media, exiting..."
    break
  elif [ "$line" = "shell" ]; then
    $BASH initrd_nice_bash || echo -e '\e[31mError starting nice bash\e[0m'
    # after shell returns, re-run the scanning logic
  elif [ "$line" = "sh" ]; then
    "$BASH" -i || echo -e '\e[31mError starting simple bash\e[0m'
    # after shell returns, re-run the scanning logic
  fi

  # re-run detection
  found=0
  search_for_key_in_drives || true

  if [ "$found" -eq 1 ]; then
    echo "Sops key installed."
    break
  fi
  echo -e "Still not found. Insert media then press ENTER, or type shell or exit.\n"

done
