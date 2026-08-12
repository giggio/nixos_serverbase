# What the container is doing, and what is down because of it.
#
# This exists because the two commands an operator reaches for both give the wrong answer during an outage, which
# the 2026-08-12 degrade rehearsal found:
#
#   systemctl --failed        usually EMPTY. encrypted-state-retry restarts the unlock, so the unit spends most of
#                             a cycle `activating` and only the few seconds between the timeout and the next retry
#                             `failed`. Looking at the wrong moment - which is most moments - shows nothing wrong.
#   systemctl is-system-running
#                             stays `starting`, never reaches `degraded`, because the retry keeps jobs queued
#                             forever and systemd does not consider the boot finished while a job is pending.
#
# So a machine whose databases have been down for an hour looks, to both of them, like a machine that is still
# booting. This prints the state that is actually true, and its EXIT STATUS is as much the point as its output:
# 0 when the container is carrying what the configuration says it should, 1 otherwise. That is the hook for
# alerting, and the reason it does not just print.

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

echo
echo "unlock:"
note "state" "$(systemctl show -p ActiveState --value encrypted-state-unlock.service) ($(systemctl show -p SubState --value encrypted-state-unlock.service))"
# The last line it logged, because that is where the attempt count is - and during an outage the attempt count is
# the only thing that says whether this is a boot in progress or a key server that has been gone for an hour.
last=$(journalctl -u encrypted-state-unlock.service -n 1 --no-pager -o cat 2>/dev/null || true)
[ -n "$last" ] && note "last" "$last"

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
  for unit in $units; do
    if [ "$(systemctl show -p ActiveState --value "$unit")" = "active" ]; then
      up="$up $unit"
    else
      down="$down $unit"
    fi
  done
  # Inactive is not the same as wrong: half of these are oneshot backup jobs a timer starts, and they are inactive
  # on a perfectly healthy machine. Listed, not judged - the exit status above is what says whether to worry.
  [ -n "$up" ] && printf '    active:  %s\n' "${up# }"
  [ -n "$down" ] && printf '    down:    %s\n' "${down# }"
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
