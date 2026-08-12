# Make the container bigger. Online, with the services running.
#
#   encrypted-state-grow 128G
#
# The size is the new TOTAL size, not an increment, and it must be larger than the current one - LUKS can shrink, but
# shrinking means shrinking the filesystem first and that is an offline, error-prone operation this script
# deliberately does not offer.
#
# Nothing here touches a partition table, and disko has no opinion about any of it: the container is a file inside a
# filesystem, so growing it is growing a file. That is the whole reason to accept the loop device's overhead.

new_size="${1:-}"
if [ -z "$new_size" ]; then
  echo "usage: encrypted-state-grow <new total size, e.g. 128G>" >&2
  exit 2
fi

if [ ! -e "$IMAGE" ]; then
  echo "FATAL: $IMAGE does not exist." >&2
  exit 1
fi

current_bytes=$(stat -c %s "$IMAGE")
new_bytes=$(numfmt --from=iec "$new_size")
if [ "$new_bytes" -le "$current_bytes" ]; then
  echo "FATAL: $IMAGE is already $(numfmt --to=iec "$current_bytes"); refusing to 'grow' it to $new_size." >&2
  echo "Shrinking a LUKS container is an offline operation and is not automated here." >&2
  exit 1
fi

target_dir=$(dirname "$IMAGE")
avail_bytes=$(( $(df --output=avail -k "$target_dir" | tail -n1) * 1024 ))
need_bytes=$(( new_bytes - current_bytes ))
if [ "$need_bytes" -ge "$avail_bytes" ]; then
  echo "FATAL: growing to $new_size needs $(numfmt --to=iec "$need_bytes") more, and $target_dir has $(numfmt --to=iec "$avail_bytes")." >&2
  exit 1
fi

loop=$(losetup --associated "$IMAGE" --noheadings --output NAME | head -n1)
if [ -z "$loop" ] || [ ! -e "/dev/mapper/$MAPPER" ]; then
  echo "FATAL: the container is not open. Start encrypted-state.target first." >&2
  exit 1
fi

echo "Growing $IMAGE from $(numfmt --to=iec "$current_bytes") to $new_size"

# 1. The backing file. Extends the allocation; the existing bytes are untouched.
fallocate -l "$new_size" "$IMAGE"

# 2. The loop device still reports the old capacity - it caches it at attach time - so it has to be told.
losetup --set-capacity "$loop"

# 3. The dm-crypt mapping. `cryptsetup resize` needs the volume key: on a device activated through clevis the key is
#    in the kernel keyring and this is silent, but a device opened by hand with the recovery passphrase may not have
#    it there, so fall back to asking the key server rather than prompting a script that may not have a terminal.
#
#    `</dev/null` is what makes that a fallback rather than a hang. Without it, cryptsetup answers a missing keyring
#    entry by prompting for a passphrase - and with stderr redirected away, an operator or a test sees a script that
#    has simply stopped, with no prompt and no error. Feeding it EOF turns that into an immediate failure the next
#    branch can handle.
if ! cryptsetup resize --batch-mode "$MAPPER" </dev/null 2>/dev/null; then
  echo "the volume key is not in the keyring; asking the key server instead"
  slot=$(clevis luks list -d "$loop" | sed -n 's/^\([0-9]\+\):.*/\1/p' | head -n1)
  if [ -z "$slot" ]; then
    echo "FATAL: no clevis binding found on $IMAGE, and no key in the keyring." >&2
    echo "Resize it by hand with the recovery passphrase: cryptsetup resize $MAPPER" >&2
    exit 1
  fi
  clevis luks pass -d "$loop" -s "$slot" | cryptsetup resize --key-file=- "$MAPPER"
fi

# 4. The filesystem. ext4 grows online; this is why the whole operation needs no downtime.
resize2fs "/dev/mapper/$MAPPER"

echo
df -h "$MOUNT_POINT"
echo
echo "Done. Update setup.encryptedState.size to \"$new_size\" so the configuration matches what is on disk."
