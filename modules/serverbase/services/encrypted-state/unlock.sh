# Open the state container and hand it to systemd as /dev/mapper/$MAPPER.
#
# Runs as ExecStart of a oneshot RemainAfterExit unit, so "success" means the mapper node exists and the mount unit
# that Requires= this service may proceed. Every exit path that is not that must be non-zero: a mount that goes ahead
# without a container is a database starting against an empty directory.

# An `encrypted-state-init`, `-grow`, `-migrate` or `-close` in progress owns the container, and this must keep its
# hands off it. Testing the lock rather than taking it: holding it here would make the unlock the thing that blocks
# the next init, and this runs on every boot.
#
# The consequence of not doing this was severe and is worth naming. `encrypted-state-init` creates the image with
# `fallocate` and only then formats it, which for an integrity container means hours of writing. Throughout those
# hours the image EXISTS, so the retry timer's "has it been created yet" guard passes, this script runs, finds no
# readable header, and exits through the failure path below - which used to detach the loop device that the format
# was writing through. A 4 TiB format died that way nineteen minutes in on 2026-08-20.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "another encrypted-state operation is running (it holds $LOCK_FILE); not touching the container." >&2
  echo "If that is encrypted-state-init, this unit will keep failing until it finishes. That is expected." >&2
  exit 1
fi
exec 9>&- # released immediately; see above

if [ ! -e "$IMAGE" ]; then
  echo "FATAL: $IMAGE does not exist." >&2
  echo "The container has never been created on this machine. Run encrypted-state-init." >&2
  exit 1
fi

if [ -e "/dev/mapper/$MAPPER" ]; then
  echo "/dev/mapper/$MAPPER is already open; nothing to do."
  exit 0
fi

# Reuse an existing loop device if one is already attached to this file. Attaching a second one would give two
# independent views of the same bytes, and mounting through both is how a filesystem gets corrupted.
loop=$(losetup --associated "$IMAGE" --noheadings --output NAME | head -n1)
attached_here=0
if [ -z "$loop" ]; then
  # --direct-io=on matters more here than the cipher does. Without it every block is cached twice - once as part of
  # the container's own filesystem, and again as part of the backing file in the host page cache - which on a server
  # whose RAM is already the scarce resource is a real cost for no benefit.
  #
  # It needs O_DIRECT from the filesystem holding the container, which ext4 gives and some others do not. Losing the
  # optimisation is not worth refusing to boot over, so fall back rather than fail - but say so, because the
  # difference is invisible afterwards and someone will eventually wonder where the memory went.
  if loop=$(losetup --find --show --direct-io=on "$IMAGE" 2>/dev/null); then
    attached_here=1
    echo "attached $IMAGE to $loop with direct I/O"
  else
    loop=$(losetup --find --show "$IMAGE")
    attached_here=1
    echo "WARNING: $(dirname "$IMAGE") does not support O_DIRECT; attached $loop WITHOUT direct I/O." >&2
    echo "WARNING: every block in the container will be cached twice, once here and once in the backing file." >&2
  fi
else
  echo "reusing existing loop device $loop for $IMAGE"
fi

detach_loop() {
  # Only detach what this invocation attached; a loop device that was already there belongs to someone else. That
  # sentence was here before the code was - it detached unconditionally, and "someone else" turned out to be
  # `cryptsetup luksFormat` mid-wipe. Now it is a flag, checked.
  [ "$attached_here" = "1" ] || {
    echo "leaving $loop alone: this invocation did not attach it." >&2
    return 0
  }
  losetup --detach "$loop" 2>/dev/null || true
}

# ONE attempt, then fail. Retrying belongs to encrypted-state-retry.timer, and the reason is worth stating because
# the loop that used to be here looked obviously right: a unit that retries internally is `activating` for the whole
# time it is failing. So `systemctl --failed` stays empty, `systemctl is-system-running` never leaves `starting`,
# OnFailure= never fires - no alert - and `nixos-rebuild switch` blocks on the start job until the budget runs out.
# The 2026-08-12 degrade rehearsal hit all four. A machine whose key server is dead has to LOOK dead, immediately,
# and then heal quietly in the background.
#
# -o passes straight through to `cryptsetup open`. The two workqueue flags take dm-crypt's per-I/O handoff out of the
# path: with AES-NI the cipher is faster than this disk, so the queueing latency is what a fsync-heavy database would
# otherwise feel. No --allow-discards, deliberately - see the `nodiscard` note in encrypted-state.nix.
#
# `timeout` because nothing else bounds this: clevis hands the network half to curl, and a key server that is
# switched off drops packets rather than refusing them, so the connect sits there until the kernel gives up.
if ! timeout "$UNLOCK_ATTEMPT_TIMEOUT" clevis luks unlock -d "$loop" -n "$MAPPER" \
  -o "--perf-no_read_workqueue --perf-no_write_workqueue"; then
  detach_loop
  echo "FATAL: could not unlock $IMAGE." >&2
  echo "The key server is unreachable, or its keys no longer match what this container was bound to." >&2
  echo "Everything that keeps state in the container stays down until this succeeds." >&2
  echo "encrypted-state-retry.timer keeps trying; encrypted-state-status says where things stand." >&2
  echo "To open it by hand with the recovery passphrase:" >&2
  echo "    cryptsetup open $loop $MAPPER" >&2
  exit 1
fi

echo "opened $IMAGE as /dev/mapper/$MAPPER"
