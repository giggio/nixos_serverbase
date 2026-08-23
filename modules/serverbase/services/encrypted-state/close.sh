# Close the container: the ExecStop half of encrypted-state-unlock.service.
#
# Best-effort on purpose. This runs at shutdown, after systemd has already torn down the mounts that depend on it, and
# a non-zero exit here would mark the unit failed on an otherwise clean shutdown. What must not happen is leaving a
# mapper node or a loop device behind for the next boot to trip over, so every step is attempted regardless of
# whether the previous one worked.

# Nothing here may run while an encrypted-state operation owns the container, and the loop detach below is why.
# It tears down the loop device backing the image REGARDLESS of what is stacked on it, which during an integrity
# wipe is the device the wipe is writing through. That is the same shape as the failure that killed a 4 TiB format
# on 2026-08-20: a teardown path firing, correctly by its own logic, into the middle of an operation that had no
# way to say "not now".
#
# Tested rather than taken, and not made an exclusive script, because this is the ExecStop of the unlock unit: it
# runs on every stop and every shutdown, and a stop job that fails because some other command holds a lock is a
# worse failure than the one being prevented. `-E 9` separates "the lock is held" from "the lock could not be
# tested at all" - only the first is a reason to decline, and at shutdown the second must not stop the cleanup.
lock_probe=0
flock -n -E 9 "$LOCK_FILE" true 2>/dev/null || lock_probe=$?
if [ "$lock_probe" -eq 9 ]; then
  echo "an encrypted-state operation owns the container (it holds $LOCK_FILE); leaving it alone."
  echo "Nothing is torn down here. A reboot clears the loop device and the mapper nodes anyway."
  exit 0
fi

if [ -e "/dev/mapper/$MAPPER" ]; then
  if cryptsetup close "$MAPPER"; then
    echo "closed /dev/mapper/$MAPPER"
  else
    # Almost always means something is still holding the filesystem. Say so rather than exiting quietly, because the
    # loop detach below will then fail too and the reason would be invisible.
    echo "could not close /dev/mapper/$MAPPER; something is still using it:" >&2
    lsof "/dev/mapper/$MAPPER" 2>/dev/null || true
    grep -F "/dev/mapper/$MAPPER" /proc/self/mounts >&2 || true
  fi
fi

loop=$(losetup --associated "$IMAGE" --noheadings --output NAME | head -n1)
if [ -n "$loop" ]; then
  losetup --detach "$loop" && echo "detached $loop" || echo "could not detach $loop" >&2
fi

exit 0
