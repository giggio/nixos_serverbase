# Ask once a day whether the header backup still describes the container, and say so where it will be seen.
#
# This exists because the honest answer to "when do I have to re-take it?" is "after any of five commands you run
# once every few years", and that is not a thing anyone remembers. `encrypted-state-status` already reports it, but
# only to whoever runs it. A stale backup is silent, keeps looking like protection, and is discovered at the one
# moment nobody wants a surprise - while restoring it.
#
# Deliberately NOT a failing unit. A failed unit sits in `systemctl --failed` and turns `is-system-running` to
# `degraded`, and that signal already means one thing on these machines: application state is not coming from the
# container, act now. A piece of paperwork that borrows the outage alarm devalues the outage alarm.

if [ ! -e "$IMAGE" ]; then
  # Between the first deploy and encrypted-state-init. Nothing is wrong and nothing can be backed up.
  echo "$IMAGE does not exist yet; nothing to check."
  exit 0
fi

if encrypted-state-header-backup --check; then
  exit 0
fi

echo
echo "The LUKS header backup is not usable as it stands. Until it is re-taken, damage to the first 16 MiB of"
echo "$IMAGE means the loss of everything in it - the keyslots hold the master key, and LUKS2's own spare copy"
echo "does not cover the keyslot area."
echo
echo "Fix it, on this machine, with:"
echo
echo "    sudo encrypted-state-header-backup"
echo
echo "then replace the off-machine copies. The procedure, including which copies exist and where they go, is in"
echo "the configuration repository's docs/encrypted-state.md."

[ -n "$HEADER_NOTIFY_UNITS" ] || exit 0

# Every day for as long as it is wrong. No once-only stamp here, unlike the outage notification: an outage ends by
# itself and a stale backup does not, so the thing to avoid is not a burst of messages but a single one that gets
# scrolled past and never followed up. It stops the day it is fixed, which makes the nag self-limiting.
for unit in $HEADER_NOTIFY_UNITS; do
  systemctl start --no-block "$unit" || echo "could not start $unit" >&2
done
