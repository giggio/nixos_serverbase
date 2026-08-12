# Try the container again, and decide whether an outage has lasted long enough to be worth waking someone for.
#
# Driven by encrypted-state-retry.timer rather than by Restart= on the unlock unit, because the unlock has to be
# allowed to sit in `failed` between attempts - that failed state IS the report. Anything that keeps restarting it
# keeps it `activating`, and then nothing downstream can tell a dead key server from a slow boot.
#
# Two jobs, and they are separate on purpose: healing is unconditional and immediate, alerting waits.

# Opening the container is not the same as healing the machine, and this is the half that is easy to miss.
#
# When the unlock fails at boot, every guarded unit's job is CANCELLED with result 'dependency' - not queued,
# cancelled. So when the container opens twenty minutes later, the mounts come up and nothing else does: there is no
# pending job left for systemd to satisfy, and `RequiresMountsFor` is a condition on starting, not a trigger to
# start. A machine in that state looks fine to `systemctl --failed`, reports OK from encrypted-state-status - the
# paths really are served from the container - and serves nothing.
#
# The old in-unit retry hid this by accident: while the unlock sat there `activating`, the dependent jobs stayed
# QUEUED, so a late success let them all proceed. Losing that is the price of the unit failing fast, and this is
# what pays it back.
start_guarded_units() {
  local unit started=""
  while IFS="$(printf '\t')" read -r _ units; do
    for unit in $units; do
      [ "$(systemctl show -p LoadState --value "$unit")" = "loaded" ] || continue
      case "$(systemctl show -p ActiveState --value "$unit")" in
      active | activating | reloading) continue ;;
      esac
      # --no-block, because this runs from a unit with a timeout and there may be thirty of these with ordering
      # between them. Enqueue the lot and let systemd sequence them exactly as a boot would.
      systemctl start --no-block "$unit" || echo "could not start $unit" >&2
      started="$started $unit"
    done
  done <<EOF
$STATE_SPEC
EOF
  if [ -n "$started" ]; then
    echo "started:${started}"
    restart_dependent_units
  else
    echo "every guarded unit was already running"
  fi
}

# Things that read what is RUNNING rather than what exists, and so are wrong until they look again. On gmktec1 that
# is the Traefik configuration provider: services started outside the ordering it watches get no route, and the
# symptom is one application missing from the proxy while everything else works - which reads as a fault in that
# application rather than in the proxy. Only after something was actually started, so an ordinary tick is silent.
restart_dependent_units() {
  local unit
  for unit in $RESUME_RESTART_UNITS; do
    [ "$(systemctl show -p LoadState --value "$unit")" = "loaded" ] || continue
    echo "restarting $unit so it sees what just came up"
    systemctl restart --no-block "$unit" || echo "could not restart $unit" >&2
  done
}

if [ ! -e "$IMAGE" ]; then
  # Not a fault. This is exactly where a machine sits between the first deploy and encrypted-state-init, and
  # retrying it every few minutes would fill the journal with "you have not run the next step yet".
  echo "$IMAGE does not exist yet; nothing to retry. Run encrypted-state-init."
  exit 0
fi

if grep -qF " $MOUNT_POINT " /proc/self/mounts; then
  # An outage stamp with the container already mounted means it came back some other way - an operator ran
  # `systemctl start encrypted.mount`, or the boot-time unlock finally won - and the guarded units are still down
  # for the same reason they would be after a heal here. Without the stamp this is just a healthy machine on a
  # routine tick, and starting anything would mean starting timer-driven backups every five minutes forever.
  if [ -e "$OUTAGE_STAMP" ]; then
    echo "the container is mounted again"
    start_guarded_units
  fi
  # Clear the stamps so the next outage gets its own grace period and its own notification, rather than inheriting
  # one from an outage that ended weeks ago.
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
  start_guarded_units
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
