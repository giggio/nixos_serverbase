# Open the state container and hand it to systemd as /dev/mapper/$MAPPER.
#
# Runs as ExecStart of a oneshot RemainAfterExit unit, so "success" means the mapper node exists and the mount unit
# that Requires= this service may proceed. Every exit path that is not that must be non-zero: a mount that goes ahead
# without a container is a database starting against an empty directory.

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
if [ -z "$loop" ]; then
  # --direct-io=on matters more here than the cipher does. Without it every block is cached twice - once as part of
  # the container's own filesystem, and again as part of the backing file in the host page cache - which on a server
  # whose RAM is already the scarce resource is a real cost for no benefit.
  #
  # It needs O_DIRECT from the filesystem holding the container, which ext4 gives and some others do not. Losing the
  # optimisation is not worth refusing to boot over, so fall back rather than fail - but say so, because the
  # difference is invisible afterwards and someone will eventually wonder where the memory went.
  if loop=$(losetup --find --show --direct-io=on "$IMAGE" 2>/dev/null); then
    echo "attached $IMAGE to $loop with direct I/O"
  else
    loop=$(losetup --find --show "$IMAGE")
    echo "WARNING: $(dirname "$IMAGE") does not support O_DIRECT; attached $loop WITHOUT direct I/O." >&2
    echo "WARNING: every block in the container will be cached twice, once here and once in the backing file." >&2
  fi
else
  echo "reusing existing loop device $loop for $IMAGE"
fi

detach_loop() {
  # Only detach what this invocation attached; a loop device that was already there belongs to someone else.
  losetup --detach "$loop" 2>/dev/null || true
}

# The retry loop exists because this runs at boot and the key server is a small box on wifi behind a router that may
# still be coming up. It is NOT there to paper over an outage: after the last attempt this exits non-zero, the mount
# fails, the dependent services stay down, and the failure is visible - which is what has to happen, because the same
# server is what unlocks everything else.
opened=0
for attempt in $(seq 1 "$UNLOCK_ATTEMPTS"); do
  # -o passes straight through to `cryptsetup open`. The two workqueue flags take dm-crypt's per-I/O handoff out of
  # the path: with AES-NI the cipher is faster than this disk, so the queueing latency is what a fsync-heavy database
  # would otherwise feel. No --allow-discards, deliberately - see the `nodiscard` note in encrypted-state.nix.
  if clevis luks unlock -d "$loop" -n "$MAPPER" \
    -o "--perf-no_read_workqueue --perf-no_write_workqueue"; then
    opened=1
    break
  fi
  if [ "$attempt" -lt "$UNLOCK_ATTEMPTS" ]; then
    echo "unlock attempt $attempt/$UNLOCK_ATTEMPTS failed; the key server may not be up yet, retrying in ${UNLOCK_DELAY}s"
    sleep "$UNLOCK_DELAY"
  fi
done

if [ "$opened" -ne 1 ]; then
  detach_loop
  echo "FATAL: could not unlock $IMAGE after $UNLOCK_ATTEMPTS attempts." >&2
  echo "The key server is unreachable, or its keys no longer match what this container was bound to." >&2
  echo "Everything that keeps state in the container stays down until this succeeds." >&2
  echo "To open it by hand with the recovery passphrase:" >&2
  echo "    cryptsetup open $loop $MAPPER" >&2
  exit 1
fi

echo "opened $IMAGE as /dev/mapper/$MAPPER"
