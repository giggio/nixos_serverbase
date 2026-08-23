# Create the state container, once, on a machine that does not have one yet.
#
# Two keyslots come out of it: the clevis one the machine uses every boot, and a RECOVERY PASSPHRASE printed
# exactly once, here, and written nowhere. Not recorded when this runs, it cannot be recovered afterwards - and
# neither can the container once the pin stops answering. What to do with it: docs/encrypted-state.md.
#
# Deliberately refuses to touch an existing container. Re-running luksFormat on one that holds data destroys every
# byte in it, and this is a script that will be run again years later by someone who has forgotten what it does.

# --resume finishes a container this script already created but did not get to the end of: the header and the
# binding are there, some or all of the wipe is done, and what is missing is the filesystem. It exists because the
# alternative, on a container that took two days to wipe, is to throw those two days away over an interrupted
# `mkfs`.
#
# It is guarded so that it can never reach a container holding data, and the guard is the progress file: written
# when the wipe starts, deleted by the last lines of this script. Its presence therefore means exactly "an init
# began here and has not finished". A container in service has no progress file and --resume refuses it, which is
# checked again against the filesystem itself further down.
resume=0
if [ "${1:-}" = "--resume" ]; then
  resume=1
  shift
fi

if [ -e "$IMAGE" ] && [ "$resume" -eq 0 ]; then
  echo "FATAL: $IMAGE already exists." >&2
  echo "This script only ever creates a container. Formatting an existing one destroys everything inside it." >&2
  echo "To make it bigger use encrypted-state-grow. To start over, move the old file aside by hand first." >&2
  if [ -e "$WIPE_PROGRESS" ]; then
    echo >&2
    echo "There IS a record of an unfinished init against a container here ($WIPE_PROGRESS)." >&2
    echo "If that is this container, finish it rather than starting again:" >&2
    echo "    encrypted-state-init --resume" >&2
  fi
  exit 1
fi

if [ "$resume" -eq 1 ]; then
  [ -e "$IMAGE" ] || {
    echo "FATAL: --resume, but $IMAGE does not exist. There is nothing to finish; run encrypted-state-init." >&2
    exit 1
  }
  [ -e "$WIPE_PROGRESS" ] || {
    echo "FATAL: --resume, but there is no record of an unfinished init at $WIPE_PROGRESS." >&2
    echo "That record is written when the wipe starts and removed when this script finishes, so its absence" >&2
    echo "means the container is either complete or was made by something else. Refusing to touch it: the next" >&2
    echo "thing this script does is mkfs, and on a container holding data that is total loss." >&2
    exit 1
  }
  # shellcheck disable=SC1090
  . "$WIPE_PROGRESS"
  image_uuid=$(cryptsetup luksUUID "$IMAGE")
  [ "${wipe_uuid:-}" = "$image_uuid" ] || {
    echo "FATAL: $WIPE_PROGRESS describes LUKS UUID ${wipe_uuid:-none}, but $IMAGE is $image_uuid." >&2
    echo "A stale record from a different container. Refusing to resume." >&2
    exit 1
  }
  cryptsetup luksDump "$IMAGE" | grep -q clevis || {
    echo "FATAL: $IMAGE has no clevis token, so nothing here can open it unattended." >&2
    echo "The binding is normally made before the wipe; this container was interrupted before that point, or" >&2
    echo "was created by an older version of this script that bound afterwards." >&2
    echo "Bind it by hand with the recovery passphrase, then run this again:" >&2
    echo "    clevis luks bind -d $IMAGE $CLEVIS_PIN '$CLEVIS_CONFIG'" >&2
    echo "    encrypted-state-init --resume" >&2
    exit 1
  }
  echo "Resuming an unfinished init of $IMAGE (LUKS UUID $image_uuid)."
  echo "Skipping allocation and format; picking up at the wipe."
fi

# Non-interactive path, for the tests and for a rehearsal on a throwaway VM. Never use it on a real machine: the
# passphrase would then exist in a file somewhere, which is the one thing this design does not allow.
passphrase=""
interactive=1
if [ "$resume" -eq 1 ]; then
  interactive=0
elif [ -n "${ENCRYPTED_STATE_PASSPHRASE_FILE:-}" ]; then
  passphrase=$(cat "$ENCRYPTED_STATE_PASSPHRASE_FILE")
  interactive=0
  echo "WARNING: taking the recovery passphrase from $ENCRYPTED_STATE_PASSPHRASE_FILE."
  echo "WARNING: this is for tests and rehearsals only. A real container's passphrase must never touch a disk."
else
  # 32 bytes of urandom. Well past anything argon2id has to defend against, which is why pinning the KDF memory
  # lower than cryptsetup's self-calibration costs nothing here.
  passphrase=$(head -c 32 /dev/urandom | base64 -w0)
fi

# The recovery passphrase is settled HERE, before a single byte is allocated, and the ordering is the point.
#
# It used to be printed and confirmed at the END, after luksFormat - which for an integrity container is after
# hours of writing. That put the whole operation at the mercy of a terminal surviving to the finish: `read` gets
# EOF from a session that has gone away, `set -e` kills the script on the spot, and the passphrase leaves with the
# process. What is left is a container that is perfectly good, opens against the key server, and has a recovery
# keyslot whose passphrase exists nowhere and cannot be produced again. On opi4pronas on 2026-08-20 that would
# have been nineteen hours of formatting to do over.
#
# Nothing about the passphrase depends on the format having run. Deciding it first costs nothing when it goes
# wrong - no file allocated, no header written, no time spent - and it lets the long part run with nobody
# watching, which is the only way a nineteen hour operation can sensibly be run at all.
if [ "$interactive" -eq 1 ]; then
  echo
  echo "==========================================================================="
  echo "  RECOVERY PASSPHRASE for the container about to be created at $IMAGE."
  echo "  Printed once, here, and stored nowhere:"
  echo
  echo "      $passphrase"
  echo
  echo "  Record it NOW, off this machine, in the two places your configuration repository's"
  echo "  docs/encrypted-state.md names - one of them offline. It will exist nowhere else."
  echo
  echo "  Without it, losing the key server loses everything in this container."
  echo "==========================================================================="
  echo
  read -r -p "Type the last six characters of the passphrase to confirm you recorded it: " confirm
  if [ "$confirm" != "${passphrase: -6}" ]; then
    echo >&2
    echo "That does not match, so nothing has been created: $IMAGE does not exist and no time has been spent." >&2
    echo "Run encrypted-state-init again when you have somewhere to write it down." >&2
    exit 1
  fi
  echo "Recorded. Nothing after this point needs you at the keyboard."
fi

# Allocation, format and binding happen once. --resume skips straight past them to the wipe, which is the only
# part of this script that can be interrupted for long enough to matter.
if [ "$resume" -eq 0 ]; then
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

  format_args=(
    --type luks2
    --batch-mode
    --pbkdf argon2id
    --pbkdf-memory "$PBKDF_MEMORY"
    # Pinned, not autodetected. cryptsetup reports what the backing device says, and with integrity the per-sector
    # tag is a fixed 32 bytes - so 4096 costs 0.78% of the container and 512 costs 6.25%, for the same data. Baked
    # into the header at this moment and not changeable afterwards.
    --sector-size "$SECTOR_SIZE"
    --label "$MAPPER"
    --key-file -
  )

  if [ -n "$INTEGRITY" ]; then
    # --integrity-no-wipe, and then encrypted-state-wipe does the wiping. Not an optimisation and not a shortcut:
    # the tags still all get written before anything uses the container, and encrypted-state-unlock refuses to open
    # it until they are. What changes is that the wipe becomes RESUMABLE.
    #
    # cryptsetup's own wipe keeps no record of how far it got, so on a container this size it is a multi-day
    # operation that any interruption returns to zero. That is not a theoretical objection: it happened twice on
    # opi4pronas, to the retry timer on 2026-08-20 and to a power cut on 2026-08-22, the second time at roughly 48
    # hours in. See docs/encrypted-state.md and the plan's journal.
    format_args+=(--integrity "$INTEGRITY" --integrity-no-wipe)
    echo
    echo "Integrity is on ($INTEGRITY), so every sector carries a tag and all $SIZE of them have to be written"
    echo "before the container can be used. That runs after the binding below, as encrypted-state-wipe, and it"
    echo "takes hours to days on spinning disks."
    echo "It is interruptible: it records where it got to, and running encrypted-state-wipe again resumes there."
    echo
  fi

  echo "Formatting LUKS2, argon2id pinned at ${PBKDF_MEMORY} KiB, ${SECTOR_SIZE}-byte sectors..."
  printf '%s' "$passphrase" | cryptsetup luksFormat "${format_args[@]}" "$IMAGE"

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
fi

# THE TRAP COMES OFF HERE, and getting this wrong would be worse than anything it protects against. Up to this
# point a failure leaves a half-made container that is worth nothing, so cleanup_failure deletes it and a retry
# starts clean. From this line on the container has a header, two keyslots and a clevis binding - and, in a moment,
# hours of wiping recorded against it. Deleting that because the wipe was interrupted at 90% is precisely the
# accident this whole rewrite exists to prevent.
trap - ERR
trap 'echo "Interrupted. The container at $IMAGE is SOUND - do not delete it. Resume with encrypted-state-wipe." >&2' ERR

if [ -n "$INTEGRITY" ]; then
  echo
  echo "Initialising the integrity tags. This is the long part, and it is the last thing that takes any time."
  echo "If it is interrupted - power, a reboot, a lost terminal - run encrypted-state-wipe to resume it."
  echo
  # Opens the container against the key server to do its work, so reaching the end of it is also proof that the
  # binding made above is good. That check used to be a separate step here; it is better done by the operation
  # that actually depends on it.
  #
  # It also writes $WIPE_PROGRESS, which is what makes an interrupted run resumable: from here until the last
  # lines of this script that file exists, and `encrypted-state-init --resume` keys off it.
  encrypted-state-wipe
else
  # No integrity, no wipe, and therefore no progress file - so --resume would have nothing to key off. Write one,
  # covering a zero-length wipe, purely so that an interruption between here and the mkfs below is recoverable the
  # same way. It costs one small file and removes a special case from the recovery path.
  printf '%s\n' \
    "# Written by encrypted-state-init. No integrity, so there is no wipe; this marks the init as unfinished." \
    "wipe_uuid=$(cryptsetup luksUUID "$IMAGE")" \
    "wipe_size=0" \
    "wipe_offset=0" >"$WIPE_PROGRESS"
fi

echo "Verifying the container opens against the key server..."
loop=$(losetup --find --show --direct-io=on "$IMAGE")
clevis luks unlock -d "$loop" -n "$MAPPER" -o "--perf-no_read_workqueue --perf-no_write_workqueue"

# What the container actually yields, against what it cost on disk. Worth printing at creation because it is the
# one moment the difference is decided and the only moment anyone is looking: the LUKS header is a flat 16 MiB, but
# with integrity there is also 32 bytes of tag per sector and a dm-integrity journal whose size cryptsetup chooses.
# An operator who sized the container against the data it has to hold needs to see the number it really offers.
usable=$(blockdev --getsize64 "/dev/mapper/$MAPPER")
image_bytes=$(stat -c %s "$IMAGE")
echo "  $(numfmt --to=iec "$usable") usable inside a $(numfmt --to=iec "$image_bytes") container" \
  "($(( (image_bytes - usable) * 1000 / image_bytes ))‰ overhead)"

# The second line of defence for --resume, and independent of the first: the progress file says an init is
# unfinished, this asks the container itself. If a filesystem is already there then the marker is lying - left
# behind by hand, restored from a backup, whatever - and the next line would destroy everything in it.
if existing=$(blkid -p -o value -s TYPE "/dev/mapper/$MAPPER" 2>/dev/null) && [ -n "$existing" ]; then
  echo "FATAL: /dev/mapper/$MAPPER already holds a $existing filesystem." >&2
  echo "Refusing to mkfs over it. If this container is genuinely empty and you want it reformatted, say so by" >&2
  echo "removing $WIPE_PROGRESS and wiping the filesystem signature by hand." >&2
  exit 1
fi

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
trap - ERR # clears the "resume with encrypted-state-wipe" message set above; there is nothing left to resume

# The container now has a filesystem and the directories in it, so the init is finished and this marker has to go.
# It is what --resume keys off, and leaving it behind would let a later --resume mkfs over a container in service.
rm -f "$WIPE_PROGRESS"

# Both keyslots exist and the clevis token is in the header, so this is the earliest moment the backup is worth
# anything - and the latest one at which taking it is still free. From here on the container holds data, and a
# header lost before anyone thought to copy it takes that data with it. Deliberately not left to the runbook: the
# step nobody does is the step that happens after the interesting part is over.
echo
echo "Backing up the header..."
encrypted-state-header-backup

thumbprint=$(cryptsetup luksDump "$IMAGE" | grep -c 'clevis' || true)
echo
echo "==========================================================================="
echo "  The container at $IMAGE is ready."
echo "  Keyslots: one bound to the key server, one recovery passphrase."
echo "  clevis tokens found in the header: $thumbprint"
echo "  Header backed up to $HEADER_BACKUP - copy it off this machine."
echo "==========================================================================="
if [ "$interactive" -eq 1 ]; then
  echo "  The recovery passphrase was printed and confirmed before the format began; it is NOT repeated here."
  echo "==========================================================================="
fi

# Hand the container over to systemd before returning, because the next documented step is
# `encrypted-state-migrate` and that needs it MOUNTED - everything above was opened by hand and closed again.
# Leaving the operator to work that out is how this script shipped once already: the runbook went straight from
# here to migrate, which answered "the container is not mounted at $MOUNT_POINT".
#
# Starting the target rather than mounting it by hand is the point. It puts the machine in exactly the state every
# later boot will produce - the unlock unit runs, asks the pin, and the mount unit follows it - so this doubles as
# a test of the path that has to work unattended at 4am. It also clears the `failed` state the unlock unit has
# been sitting in since boot, when there was no container for it to open.
if [ "$BIND_STATE" = "1" ]; then
  # Deliberately NOT started. bindState is true with a container that has never been migrated into, so the target
  # would bring up bind mounts of empty directories over whatever is live underneath them - the exact accident the
  # two-deploy sequence exists to prevent. Something is already out of order; say so rather than act on it.
  echo
  echo "WARNING: setup.encryptedState.bindState is already true, and this container is empty." >&2
  echo "WARNING: NOT starting encrypted-state.target - it would bind empty directories over your live data." >&2
  echo "WARNING: set bindState = false, switch, then run encrypted-state-migrate." >&2
  exit 1
fi

echo
echo "Bringing the container up through systemd..."

# The exclusive window ends HERE, and it has to: the target starts encrypted-state-unlock, which refuses to touch
# the container while this lock is held. Holding it through the hand-off would deadlock this script against its
# own unlock unit.
#
# Releasing is also correct rather than merely necessary. What needed protecting was the format - a container that
# exists but has no readable header yet, over a loop device a retry would happily tear down. From this line on the
# container is sound, and an unlock reaching it is exactly what is wanted.
exec 9>&-

if ! systemctl start encrypted-state.target; then
  echo >&2
  echo "The container was created and is sound - do NOT run encrypted-state-init again, it will refuse." >&2
  echo "Only bringing it up failed, which is the key server or the network. Fix that, then:" >&2
  echo "    systemctl start encrypted-state.target && encrypted-state-migrate" >&2
  exit 1
fi

if ! grep -qF " $MOUNT_POINT " /proc/self/mounts; then
  echo "FATAL: encrypted-state.target started but nothing is mounted at $MOUNT_POINT." >&2
  echo "Check: systemctl status encrypted-state-unlock.service" >&2
  exit 1
fi

echo
echo "==========================================================================="
echo "  Mounted at $MOUNT_POINT. Next: encrypted-state-migrate"
echo "==========================================================================="
