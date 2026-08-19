# What the container is doing, and what is down because of it.
#
# `systemctl --failed` now does show the unlock unit during an outage - that took moving the retry out of the unit
# and into a timer, because a unit that retries internally is `activating` rather than `failed` and therefore
# invisible. But it shows one line, and the question during an outage is which of thirty services are down and
# whether anything has quietly started on the empty directory underneath a bind mount that never happened.
#
# So this prints what is actually true, per path, and its EXIT STATUS is as much the point as its output: 0 when
# the container is carrying what the configuration says it should, 1 otherwise. That is the hook for alerting, and
# the reason this does not just print.
#
# The retry runs every retryIntervalSeconds and clears the unlock's failed state for as long as an attempt takes,
# so `--failed` can be momentarily empty during a real outage. This command cannot be: it reads the mounts.

degraded=0
note() { printf '  %-10s %s\n' "$1" "$2"; }

echo "container:"
if [ -e "$IMAGE" ]; then
  note "image" "$IMAGE ($(du -h --apparent-size "$IMAGE" | cut -f1))"
else
  note "image" "$IMAGE - MISSING, never created. Run encrypted-state-init."
  degraded=1
fi

# Needs root; say so rather than printing "none" and implying the loop is gone.
if loop=$(losetup --associated "$IMAGE" --noheadings --output NAME 2>/dev/null); then
  note "loop" "${loop:-none attached}"
else
  note "loop" "unknown (needs root)"
fi

if [ -e "/dev/mapper/$MAPPER" ]; then
  note "mapper" "/dev/mapper/$MAPPER open"
else
  note "mapper" "/dev/mapper/$MAPPER CLOSED"
  degraded=1
fi

if grep -qF " $MOUNT_POINT " /proc/self/mounts; then
  note "mount" "$MOUNT_POINT $(df -h --output=avail "$MOUNT_POINT" | tail -n1 | tr -d ' ') free"
else
  note "mount" "$MOUNT_POINT NOT MOUNTED"
  degraded=1
fi

# The header backup, which is the one thing here whose absence costs everything rather than an outage - and for that
# exact reason it is reported but does NOT set `degraded`. The exit status answers "is application state coming from
# the container", which alerting acts on immediately; folding a to-do into it would mean a healthy machine paging
# until someone did paperwork, and an operator learning to ignore the signal.
#
# Comparing bytes rather than taking a fresh backup: `luksHeaderBackup` writes exactly the front of the container, so
# the backup is current precisely when it equals it, and every header write bumps the LUKS2 seqid inside that range.
# One 16 MiB read, no writes, correct for added, killed and re-bound keyslots alike.
if [ -e "$IMAGE" ]; then
  if [ ! -e "$HEADER_BACKUP" ]; then
    note "header" "$HEADER_BACKUP MISSING - run encrypted-state-header-backup"
  elif [ ! -r "$HEADER_BACKUP" ] || [ ! -r "$IMAGE" ]; then
    # Both are 0400/0600 root. Without this the comparison below fails on the read and reports STALE, which is the
    # one answer that would send someone to re-take a backup that was fine.
    note "header" "$HEADER_BACKUP present (needs root to verify)"
  elif cmp -s -n "$(stat -c %s "$HEADER_BACKUP")" "$HEADER_BACKUP" "$IMAGE"; then
    note "header" "$HEADER_BACKUP current"
  else
    note "header" "$HEADER_BACKUP STALE - the keyslots have changed since it was taken"
  fi
fi

echo
echo "unlock:"
note "state" "$(systemctl show -p ActiveState --value encrypted-state-unlock.service) ($(systemctl show -p SubState --value encrypted-state-unlock.service))"
# The last line it logged, because that is where the attempt count is - and during an outage the attempt count is
# the only thing that says whether this is a boot in progress or a key server that has been gone for an hour.
last=$(journalctl -u encrypted-state-unlock.service -n 1 --no-pager -o cat 2>/dev/null || true)
[ -n "$last" ] && note "last" "$last"
# When the machine will try again by itself, so nobody sits there wondering whether to intervene. Monotonic, not
# realtime: the timer is OnBootSec/OnUnitInactiveSec, and systemd leaves NextElapseUSecRealtime EMPTY for those -
# reading the wrong one printed a blank line and looked like a timer that was never going to fire again.
next=$(systemctl show -p NextElapseUSecMonotonic --value encrypted-state-retry.timer 2>/dev/null || true)
[ -n "$next" ] && [ "$next" != "0" ] && note "retry" "next $next after boot"
if [ -e "$OUTAGE_STAMP" ]; then
  note "down for" "$(($(date +%s) - $(cat "$OUTAGE_STAMP")))s$([ -e "$OUTAGE_NOTIFIED" ] && echo ", notified" || echo "")"
fi

echo
echo "state paths:"
while IFS="$(printf '\t')" read -r path units; do
  [ -n "$path" ] || continue

  if [ "$BIND_STATE" = "1" ]; then
    source=$(findmnt -no SOURCE --target "$path" 2>/dev/null || true)
    # findmnt reports a bind mount as `device[/subpath]`, so compare on the device half. Comparing the whole string
    # says NOT BOUND for every correctly bound path, which is the most misleading answer this could give.
    if [ "${source%%[*}" = "/dev/mapper/$MAPPER" ]; then
      where="on the container"
    else
      # The dangerous state, and the reason this line names what IS there: the directory exists and is readable,
      # it is simply the empty one on the root filesystem underneath the bind that never happened.
      where="NOT BOUND - reads would hit ${source:-the root filesystem}"
      degraded=1
    fi
  else
    where="not bound (bindState is off - this machine has not finished migrating)"
  fi
  printf '  %s\n    %s\n' "$path" "$where"

  up=""
  down=""
  masked=""
  for unit in $units; do
    # Held back by the migration is its own answer, not a kind of "down": it means the data has moved and the second
    # deploy has not happened yet, which is a state an operator is deliberately in the middle of.
    if [ -e "/run/systemd/system/${unit}.d/$GUARD_DROPIN" ]; then
      masked="$masked $unit"
    elif [ "$(systemctl show -p ActiveState --value "$unit")" = "active" ]; then
      up="$up $unit"
    else
      down="$down $unit"
    fi
  done
  # Inactive is not the same as wrong: half of these are oneshot backup jobs a timer starts, and they are inactive
  # on a perfectly healthy machine. Listed, not judged - the exit status above is what says whether to worry.
  [ -n "$up" ] && printf '    active:  %s\n' "${up# }"
  [ -n "$down" ] && printf '    down:    %s\n' "${down# }"
  if [ -n "$masked" ]; then
    printf '    held:    %s\n' "${masked# }"
    printf '             (migrated but not yet bound - finish the second deploy)\n'
    degraded=1
  fi
done <<EOF
$STATE_SPEC
EOF

echo
if [ "$degraded" -eq 0 ]; then
  echo "OK: the container is open and every declared path is served from it."
else
  # stdout, not stderr: the exit status is the machine-readable half, so the verdict belongs with the rest of the
  # report where a pipe or a mail body will carry it.
  echo "DEGRADED: application state is NOT coming from the container."
fi
exit "$degraded"
