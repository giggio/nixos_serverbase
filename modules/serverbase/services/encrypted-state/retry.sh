# Try the container again, and decide whether an outage has lasted long enough to be worth waking someone for.
#
# Driven by encrypted-state-retry.timer rather than by Restart= on the unlock unit, because the unlock has to be
# allowed to sit in `failed` between attempts - that failed state IS the report. Anything that keeps restarting it
# keeps it `activating`, and then nothing downstream can tell a dead key server from a slow boot.
#
# Two jobs, and they are separate on purpose: healing is unconditional and immediate, alerting waits.

if [ ! -e "$IMAGE" ]; then
  # Not a fault. This is exactly where a machine sits between the first deploy and encrypted-state-init, and
  # retrying it every few minutes would fill the journal with "you have not run the next step yet".
  echo "$IMAGE does not exist yet; nothing to retry. Run encrypted-state-init."
  exit 0
fi

if grep -qF " $MOUNT_POINT " /proc/self/mounts; then
  # Healthy. Clear the outage stamps so the next outage gets its own grace period and its own notification, rather
  # than inheriting one from an outage that ended weeks ago.
  rm -f "$OUTAGE_STAMP" "$OUTAGE_NOTIFIED"
  exit 0
fi

# First tick of this outage: remember when it started. In /run, so a reboot starts the clock again - a machine that
# has just rebooted into a dead key server deserves its own notification.
if [ ! -e "$OUTAGE_STAMP" ]; then
  date +%s >"$OUTAGE_STAMP"
  echo "the container is not mounted; starting the outage clock"
fi

echo "retrying the unlock"
# Through the target, so the mounts and everything ordered after them come up in the same sequence a boot uses.
# Failure here is expected and is not this unit's failure: the unlock unit records it, in `failed`, where it shows.
systemctl start "$TARGET_UNIT" || true

if grep -qF " $MOUNT_POINT " /proc/self/mounts; then
  echo "the container is open again"
  rm -f "$OUTAGE_STAMP" "$OUTAGE_NOTIFIED"
  exit 0
fi

# Still down. Notify ONCE, and only after the outage has outlived the ordinary causes - a key server on wifi behind
# a router that is still coming up, or a machine that rebooted a minute before the Pi did. Notifying on the first
# failure would page for every power cut; notifying on every retry would page every few minutes for a whole outage.
[ -n "$OUTAGE_NOTIFY_UNITS" ] || exit 0
[ -e "$OUTAGE_NOTIFIED" ] && exit 0

started=$(cat "$OUTAGE_STAMP" 2>/dev/null || echo 0)
down=$(($(date +%s) - started))
[ "$down" -ge "$OUTAGE_NOTIFY_AFTER" ] || exit 0

echo "the container has been unavailable for ${down}s; notifying"
for unit in $OUTAGE_NOTIFY_UNITS; do
  # --no-block: a notifier that cannot reach the network must not hold this unit open until the next tick.
  systemctl start --no-block "$unit" || echo "could not start $unit" >&2
done
touch "$OUTAGE_NOTIFIED"
