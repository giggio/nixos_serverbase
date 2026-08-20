# Clear the guards encrypted-state-migrate left, now that the paths are really bound, and start what they held back.
#
# The migration leaves every moved path as an empty directory with no mount over it, because bindState stays false
# until the second deploy. A service that starts in that window finds no data where its data should be, and a
# database answers that by initialising a new one. So migrate drops a `ConditionPathIsMountPoint` into
# /run/systemd/system/<unit>.d for each of them, and this removes it - ordered after the bind mounts, so the guard
# ends exactly where the mount's own guard begins and there is no moment when neither holds.
#
# Runs on every boot once bindState is on and does nothing on almost all of them: there are no drop-ins to remove.
# That is what keeps it from starting timer-driven backup jobs on an ordinary boot.

released=""
while IFS="$(printf '\t')" read -r _ units; do
  for unit in $units; do
    dropin="/run/systemd/system/${unit}.d/$GUARD_DROPIN"
    [ -e "$dropin" ] || continue
    rm -f "$dropin"
    # Only the directory this created; a unit may have other run-time drop-ins that are none of our business.
    rmdir "/run/systemd/system/${unit}.d" 2>/dev/null || true
    released="$released $unit"
  done
done <<EOF
$STATE_SPEC
EOF

[ -n "$released" ] || exit 0

systemctl daemon-reload
echo "released after the migration:${released}"

# Releasing is not starting. The activation that brought the bind mounts up skipped these units because their
# condition was false at the time, and a job that was skipped is not re-enqueued when the condition becomes true -
# the same reason encrypted-state-retry has to start things itself after a heal. --no-block so systemd sequences
# them exactly as a boot would.
for unit in $released; do
  case "$(systemctl show -p ActiveState --value "$unit")" in
  active | activating | reloading) continue ;;
  esac
  # See the same call in retry.sh: `systemctl start` REFUSES a unit that has burned its start limit, so anything
  # that spent the migration window failing would be skipped silently here.
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl start --no-block "$unit" || echo "could not start $unit" >&2
done
echo "started what was not already running"

# Anything that derives its configuration from what is currently running has just been left with a stale answer.
# See resumeRestartUnits, and the Traefik provider on gmktec1 that gave one service no route after exactly this.
for unit in $RESUME_RESTART_UNITS; do
  [ "$(systemctl show -p LoadState --value "$unit")" = "loaded" ] || continue
  echo "restarting $unit so it sees what just came up"
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl restart --no-block "$unit" || echo "could not restart $unit" >&2
done
