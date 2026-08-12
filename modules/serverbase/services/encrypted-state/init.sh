# Create the state container, once, on a machine that does not have one yet.
#
# Two keyslots come out of it: the clevis one the machine uses every boot, and a RECOVERY PASSPHRASE printed
# exactly once, here, and written nowhere. Not recorded when this runs, it cannot be recovered afterwards - and
# neither can the container once the pin stops answering. What to do with it: docs/encrypted-state.md.
#
# Deliberately refuses to touch an existing container. Re-running luksFormat on one that holds data destroys every
# byte in it, and this is a script that will be run again years later by someone who has forgotten what it does.

if [ -e "$IMAGE" ]; then
  echo "FATAL: $IMAGE already exists." >&2
  echo "This script only ever creates a container. Formatting an existing one destroys everything inside it." >&2
  echo "To make it bigger use encrypted-state-grow. To start over, move the old file aside by hand first." >&2
  exit 1
fi

# Non-interactive path, for the tests and for a rehearsal on a throwaway VM. Never use it on a real machine: the
# passphrase would then exist in a file somewhere, which is the one thing this design does not allow.
passphrase=""
interactive=1
if [ -n "${ENCRYPTED_STATE_PASSPHRASE_FILE:-}" ]; then
  passphrase=$(cat "$ENCRYPTED_STATE_PASSPHRASE_FILE")
  interactive=0
  echo "WARNING: taking the recovery passphrase from $ENCRYPTED_STATE_PASSPHRASE_FILE."
  echo "WARNING: this is for tests and rehearsals only. A real container's passphrase must never touch a disk."
else
  # 32 bytes of urandom. Well past anything argon2id has to defend against, which is why pinning the KDF memory
  # lower than cryptsetup's self-calibration costs nothing here.
  passphrase=$(head -c 32 /dev/urandom | base64 -w0)
fi

target_dir=$(dirname "$IMAGE")
avail=$(df --output=avail -k "$target_dir" | tail -n1)
echo "Creating a $SIZE container at $IMAGE ($(( avail / 1024 / 1024 )) GiB free on $target_dir)"

# Fully allocated, NOT sparse. A sparse container on a filesystem that later fills up gives ENOSPC to writes coming
# from INSIDE the container - so the error surfaces on a database, at fsync time, caused by something entirely
# unrelated filling the disk. fallocate takes the space now, when it can still fail harmlessly.
if ! fallocate -l "$SIZE" "$IMAGE"; then
  echo "FATAL: could not allocate $SIZE at $IMAGE." >&2
  rm -f "$IMAGE"
  exit 1
fi
chmod 0600 "$IMAGE"

cleanup_failure() {
  echo "Creation failed; removing the partial container so a retry starts clean." >&2
  cryptsetup close "$MAPPER" 2>/dev/null || true
  loop=$(losetup --associated "$IMAGE" --noheadings --output NAME | head -n1)
  [ -n "$loop" ] && losetup --detach "$loop" 2>/dev/null
  rm -f "$IMAGE"
}
trap cleanup_failure ERR

echo "Formatting LUKS2, argon2id pinned at ${PBKDF_MEMORY} KiB..."
printf '%s' "$passphrase" | cryptsetup luksFormat \
  --type luks2 \
  --batch-mode \
  --pbkdf argon2id \
  --pbkdf-memory "$PBKDF_MEMORY" \
  --label "$MAPPER" \
  --key-file - \
  "$IMAGE"

echo "Binding a second keyslot to the key server..."
# `clevis luks bind` works directly on a file - no loop device needed, and no root beyond reading and writing the
# file. The JWE lands in a LUKS2 token inside the header, which is the reason to bind rather than keep a separate
# .jwe file next to the container: there is one artifact, so there is nothing to drift out of sync, and copying the
# container copies its binding with it.
printf '%s' "$passphrase" >/dev/shm/.encrypted-state-key.$$
chmod 0600 /dev/shm/.encrypted-state-key.$$
clevis luks bind -y -d "$IMAGE" -k /dev/shm/.encrypted-state-key.$$ "$CLEVIS_PIN" "$CLEVIS_CONFIG"
shred -u /dev/shm/.encrypted-state-key.$$

# Prove the binding works BEFORE the operator walks away, rather than discovering at the next reboot that the
# container can only be opened by hand. This is the whole reason the key server is contacted twice here.
echo "Verifying the container opens against the key server..."
loop=$(losetup --find --show --direct-io=on "$IMAGE")
clevis luks unlock -d "$loop" -n "$MAPPER" -o "--perf-no_read_workqueue --perf-no_write_workqueue"

echo "Creating the filesystem..."
# -m 0: the 5% reserved-for-root margin exists to keep a root filesystem recoverable when it fills. This is not a
# root filesystem, and on a large container that margin is many gigabytes of nothing.
mkfs.ext4 -q -m 0 -L "$MAPPER" "/dev/mapper/$MAPPER"

mkdir -p "$MOUNT_POINT"
mount "/dev/mapper/$MAPPER" "$MOUNT_POINT"

# The container mirrors the real tree, so the directories are created at the paths they will be bound from. Ownership
# is left to the migration, which copies it from the originals.
while IFS= read -r path; do
  [ -z "$path" ] && continue
  mkdir -p "${MOUNT_POINT}${path}"
  echo "  prepared ${MOUNT_POINT}${path}"
done <<<"$STATE_PATHS"

umount "$MOUNT_POINT"
cryptsetup close "$MAPPER"
losetup --detach "$loop"
trap - ERR

thumbprint=$(cryptsetup luksDump "$IMAGE" | grep -c 'clevis' || true)
echo
echo "==========================================================================="
echo "  The container at $IMAGE is ready."
echo "  Keyslots: one bound to the key server, one recovery passphrase."
echo "  clevis tokens found in the header: $thumbprint"
echo "==========================================================================="
if [ "$interactive" -eq 1 ]; then
  echo
  echo "  RECOVERY PASSPHRASE - printed once, stored nowhere:"
  echo
  echo "      $passphrase"
  echo
  echo "  Record it NOW, off this machine, in the two places your configuration repository's"
  echo "  docs/encrypted-state.md names - one of them offline. It exists nowhere else."
  echo
  echo "  Without it, losing the key server loses everything in this container."
  echo "==========================================================================="
  echo
  read -r -p "Type the last six characters of the passphrase to confirm you recorded it: " confirm
  if [ "$confirm" != "${passphrase: -6}" ]; then
    echo
    echo "That does not match. The container exists and is bound to the key server, so the machine will boot," >&2
    echo "but you have no recovery passphrase. Destroy it and start over:" >&2
    echo "    rm -f $IMAGE && encrypted-state-init" >&2
    exit 1
  fi
  echo "Recorded."
fi

echo
echo "Next: switch with setup.encryptedState.bindState still false, then run encrypted-state-migrate."
