# Close the container: the ExecStop half of encrypted-state-unlock.service.
#
# Best-effort on purpose. This runs at shutdown, after systemd has already torn down the mounts that depend on it, and
# a non-zero exit here would mark the unit failed on an otherwise clean shutdown. What must not happen is leaving a
# mapper node or a loop device behind for the next boot to trip over, so every step is attempted regardless of
# whether the previous one worked.

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
